[CmdletBinding()]
param([int]$Port = 8765)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$htmlPath = Join-Path $root "AI.html"
$indexPath = Join-Path $root "index.html"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Get-LocalIPv4Addresses {
  $addresses = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
    Where-Object {
      $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
      -not [System.Net.IPAddress]::IsLoopback($_) -and
      -not $_.ToString().StartsWith("169.254.")
    } |
    ForEach-Object { $_.ToString() } |
    Sort-Object -Unique

  return @($addresses)
}

function Get-ServerInfo([int]$BoundPort) {
  $localUrl = "http://127.0.0.1:$BoundPort/"
  $lanUrls = @(Get-LocalIPv4Addresses | ForEach-Object { "http://$_`:$BoundPort/" })

  return @{
    localUrl = $localUrl
    lanUrls = $lanUrls
    primaryUrl = if ($lanUrls.Count) { $lanUrls[0] } else { $localUrl }
  }
}

function Read-HttpRequest($client) {
  $stream = $client.GetStream()
  $buffer = New-Object byte[] 4096
  $requestBytes = [System.Collections.Generic.List[byte]]::new()
  $headerEnd = -1

  while ($headerEnd -lt 0) {
    $read = $stream.Read($buffer, 0, $buffer.Length)
    if ($read -le 0) {
      return $null
    }

    for ($i = 0; $i -lt $read; $i++) {
      [void]$requestBytes.Add($buffer[$i])
    }

    $count = $requestBytes.Count
    for ($i = [Math]::Max(0, $count - $read - 3); $i -le $count - 4; $i++) {
      if (
        $requestBytes[$i] -eq 13 -and
        $requestBytes[$i + 1] -eq 10 -and
        $requestBytes[$i + 2] -eq 13 -and
        $requestBytes[$i + 3] -eq 10
      ) {
        $headerEnd = $i + 4
        break
      }
    }
  }

  $allBytes = $requestBytes.ToArray()
  $headerText = [System.Text.Encoding]::ASCII.GetString($allBytes, 0, $headerEnd)
  $headerLines = $headerText -split "`r?`n"
  if (-not $headerLines -or -not $headerLines[0]) {
    return $null
  }

  $requestLine = $headerLines[0].Split(" ")
  if ($requestLine.Count -lt 2) {
    return $null
  }

  $headers = @{}
  foreach ($line in $headerLines | Select-Object -Skip 1) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $separator = $line.IndexOf(":")
    if ($separator -lt 1) { continue }
    $name = $line.Substring(0, $separator).Trim().ToLowerInvariant()
    $value = $line.Substring($separator + 1).Trim()
    $headers[$name] = $value
  }

  $contentLength = 0
  if ($headers.ContainsKey("content-length")) {
    [void][int]::TryParse($headers["content-length"], [ref]$contentLength)
  }

  $bodyBytes = [System.Collections.Generic.List[byte]]::new()
  for ($i = $headerEnd; $i -lt $allBytes.Length; $i++) {
    [void]$bodyBytes.Add($allBytes[$i])
  }

  while ($bodyBytes.Count -lt $contentLength) {
    $read = $stream.Read($buffer, 0, [Math]::Min($buffer.Length, $contentLength - $bodyBytes.Count))
    if ($read -le 0) { break }
    for ($i = 0; $i -lt $read; $i++) {
      [void]$bodyBytes.Add($buffer[$i])
    }
  }

  $rawPath = $requestLine[1]
  $path = $rawPath.Split("?")[0]

  return @{
    Method = $requestLine[0].ToUpperInvariant()
    Path = $path
    RawPath = $rawPath
    Headers = $headers
    BodyBytes = $bodyBytes.ToArray()
    BodyText = if ($bodyBytes.Count) { $utf8NoBom.GetString($bodyBytes.ToArray()) } else { "" }
  }
}

function Write-Response($client, [int]$statusCode, [string]$contentType, [byte[]]$bodyBytes, [hashtable]$extraHeaders = @{}) {
  $stream = $client.GetStream()
  $reason = switch ($statusCode) {
    200 { "OK" }
    204 { "No Content" }
    400 { "Bad Request" }
    404 { "Not Found" }
    405 { "Method Not Allowed" }
    500 { "Internal Server Error" }
    default { "OK" }
  }

  if (-not $bodyBytes) {
    $bodyBytes = [byte[]]@()
  }

  $headers = [System.Collections.Generic.List[string]]::new()
  [void]$headers.Add("HTTP/1.1 $statusCode $reason")
  [void]$headers.Add("Content-Type: $contentType")
  [void]$headers.Add("Content-Length: $($bodyBytes.Length)")
  [void]$headers.Add("Connection: close")
  [void]$headers.Add("Access-Control-Allow-Origin: *")
  [void]$headers.Add("Access-Control-Allow-Headers: Content-Type")
  [void]$headers.Add("Access-Control-Allow-Methods: GET,POST,OPTIONS")
  [void]$headers.Add("Cache-Control: no-store")

  foreach ($entry in $extraHeaders.GetEnumerator()) {
    [void]$headers.Add("$($entry.Key): $($entry.Value)")
  }

  $headerBytes = $utf8NoBom.GetBytes(($headers -join "`r`n") + "`r`n`r`n")
  $stream.Write($headerBytes, 0, $headerBytes.Length)
  if ($bodyBytes.Length) {
    $stream.Write($bodyBytes, 0, $bodyBytes.Length)
  }
  $stream.Flush()
}

function Send-Json($client, $data, [int]$statusCode = 200) {
  $json = $data | ConvertTo-Json -Depth 10 -Compress
  $bytes = $utf8NoBom.GetBytes($json)
  Write-Response $client $statusCode "application/json; charset=utf-8" $bytes
}

function Send-Text($client, [string]$text, [int]$statusCode = 200) {
  $bytes = $utf8NoBom.GetBytes($text)
  Write-Response $client $statusCode "text/plain; charset=utf-8" $bytes
}

function Send-File($client, [string]$path, [string]$contentType) {
  $bytes = [System.IO.File]::ReadAllBytes($path)
  Write-Response $client 200 $contentType $bytes
}

function Read-JsonBody($request) {
  if ([string]::IsNullOrWhiteSpace($request.BodyText)) {
    return @{}
  }
  return $request.BodyText | ConvertFrom-Json
}

function Get-OllamaModel {
  if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) { return $null }
  try {
    $lines = & ollama list 2>$null
    $first = $lines | Select-Object -Skip 1 -First 1
    if (-not $first) { return $null }
    return ($first -split "\s+")[0]
  } catch {
    return $null
  }
}

function Resolve-App($message) {
  $text = $message.ToLowerInvariant()

  if ($text -match '(https?://[^\s]+)') { return @{ kind = "url"; target = $Matches[1]; label = $Matches[1] } }
  if ($text -match '\byoutube\b') { return @{ kind = "url"; target = "https://www.youtube.com"; label = "YouTube" } }
  if ($text -match '\bgoogle\b') { return @{ kind = "url"; target = "https://www.google.com"; label = "Google" } }
  if ($message -match '([A-Za-z]:\\[^"]+\.exe)') { return @{ kind = "file"; target = $Matches[1]; label = $Matches[1] } }

  switch -Regex ($text) {
    'calculator|calc' { return @{ kind = "app"; target = "calc.exe"; label = "Calculator" } }
    'notepad' { return @{ kind = "app"; target = "notepad.exe"; label = "Notepad" } }
    'explorer|file manager' { return @{ kind = "app"; target = "explorer.exe"; label = "Explorer" } }
    'browser|edge|internet' { return @{ kind = "app"; target = "msedge.exe"; label = "Browser" } }
    'chrome' { return @{ kind = "app"; target = "chrome.exe"; label = "Chrome" } }
    'paint' { return @{ kind = "app"; target = "mspaint.exe"; label = "Paint" } }
    'powershell' { return @{ kind = "app"; target = "powershell.exe"; label = "PowerShell" } }
    'cmd|command prompt' { return @{ kind = "app"; target = "cmd.exe"; label = "Command Prompt" } }
    'task manager|taskmgr' { return @{ kind = "app"; target = "taskmgr.exe"; label = "Task Manager" } }
    'downloads' { return @{ kind = "file"; target = [Environment]::GetFolderPath("UserProfile") + "\Downloads"; label = "Downloads" } }
    'documents' { return @{ kind = "file"; target = [Environment]::GetFolderPath("MyDocuments"); label = "Documents" } }
    'settings' { return @{ kind = "uri"; target = "ms-settings:"; label = "Settings" } }
  }

  return $null
}

function Open-App($app) {
  if ($app.kind -in @("url", "uri")) {
    Start-Process $app.target | Out-Null
    return
  }

  Start-Process -FilePath $app.target | Out-Null
}

function Get-FallbackReply($message) {
  $text = $message.ToLowerInvariant()

  if ($text -match "hello|hi|hey") {
    return "Hi. I am running locally and can open Windows apps or answer simple prompts."
  }
  if ($text -match "plan|steps|roadmap") {
    return "Start with the goal, break it into small steps, build the simplest version, then test it."
  }

  return "I am running locally. I can answer briefly, help with an idea, or open an app command."
}

function Invoke-OllamaReply($history) {
  $model = Get-OllamaModel
  if (-not $model) { return $null }

  $messages = @(@{ role = "system"; content = "You are a helpful AI assistant. Reply briefly, clearly, and practically." })
  foreach ($item in $history) {
    if ($null -ne $item.role -and $null -ne $item.text -and $item.role -in @("user", "assistant")) {
      $messages += @{ role = [string]$item.role; content = [string]$item.text }
    }
  }

  $body = @{ model = $model; messages = $messages; stream = $false } | ConvertTo-Json -Depth 10
  try {
    $response = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/chat" -Method Post -ContentType "application/json" -Body $body
    return @{ reply = [string]$response.message.content; model = $model }
  } catch {
    return $null
  }
}

if (-not (Test-Path -LiteralPath $htmlPath)) {
  throw "Missing AI.html"
}

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
$listener.Server.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
$listener.Start()

$serverInfo = Get-ServerInfo -BoundPort $Port
Write-Host "AI server started."
Write-Host "PC:    $($serverInfo.localUrl)"
foreach ($url in $serverInfo.lanUrls) {
  Write-Host "Phone: $url"
}

try {
  while ($true) {
    $client = $listener.AcceptTcpClient()

    try {
      $request = Read-HttpRequest $client
      if (-not $request) {
        Send-Json $client @{ ok = $false; error = "Invalid request." } 400
        continue
      }

      if ($request.Method -eq "OPTIONS") {
        Write-Response $client 204 "text/plain; charset=utf-8" ([byte[]]@())
        continue
      }

      if ($request.Method -eq "GET" -and ($request.Path -eq "/" -or $request.Path -eq "/AI.html")) {
        Send-File $client $htmlPath "text/html; charset=utf-8"
        continue
      }

      if ($request.Method -eq "GET" -and $request.Path -eq "/index.html") {
        if (Test-Path -LiteralPath $indexPath) {
          Send-File $client $indexPath "text/html; charset=utf-8"
        } else {
          Send-File $client $htmlPath "text/html; charset=utf-8"
        }
        continue
      }

      if ($request.Method -eq "GET" -and $request.Path -eq "/api/status") {
        $model = Get-OllamaModel
        $serverInfo = Get-ServerInfo -BoundPort $Port
        Send-Json $client @{
          ok = $true
          apps = $true
          voice = $true
          ollama = [bool]$model
          model = $model
          localUrl = $serverInfo.localUrl
          lanUrls = $serverInfo.lanUrls
          primaryUrl = $serverInfo.primaryUrl
        }
        continue
      }

      if ($request.Method -eq "POST" -and $request.Path -eq "/api/chat") {
        $body = Read-JsonBody $request
        $message = [string]$body.message
        $history = @($body.history)
        if ([string]::IsNullOrWhiteSpace($message)) {
          Send-Json $client @{ ok = $false; error = "Empty message." } 400
          continue
        }

        $app = Resolve-App $message
        if ($app) {
          Open-App $app
          Send-Json $client @{ ok = $true; mode = "app"; reply = "Opening $($app.label)." }
          continue
        }

        $ollama = Invoke-OllamaReply $history
        if ($ollama) {
          Send-Json $client @{ ok = $true; mode = "ollama"; model = $ollama.model; reply = $ollama.reply }
          continue
        }

        Send-Json $client @{ ok = $true; mode = "local"; reply = (Get-FallbackReply $message) }
        continue
      }

      Send-Json $client @{ ok = $false; error = "Not found." } 404
    } catch {
      Write-Warning $_
      try {
        Send-Json $client @{ ok = $false; error = $_.Exception.Message } 500
      } catch {
      }
    } finally {
      $client.Close()
    }
  }
} finally {
  $listener.Stop()
}
