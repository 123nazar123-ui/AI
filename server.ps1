[CmdletBinding()]
param([int]$Port = 8765)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$htmlPath = Join-Path $root "AI.html"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")

function Set-Headers($response) {
  $response.Headers["Access-Control-Allow-Origin"] = "*"
  $response.Headers["Access-Control-Allow-Headers"] = "Content-Type"
  $response.Headers["Access-Control-Allow-Methods"] = "GET,POST,OPTIONS"
  $response.Headers["Cache-Control"] = "no-store"
  $response.ContentEncoding = [System.Text.Encoding]::UTF8
}

function Send-Json($context, $data, [int]$status = 200) {
  $json = $data | ConvertTo-Json -Depth 10 -Compress
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  $context.Response.StatusCode = $status
  $context.Response.ContentType = "application/json; charset=utf-8"
  Set-Headers $context.Response
  $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Send-Html($context, [string]$path) {
  $bytes = [System.IO.File]::ReadAllBytes($path)
  $context.Response.StatusCode = 200
  $context.Response.ContentType = "text/html; charset=utf-8"
  Set-Headers $context.Response
  $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Read-Body($request) {
  $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
  try { $raw = $reader.ReadToEnd() } finally { $reader.Dispose() }
  if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
  return $raw | ConvertFrom-Json
}

function Get-OllamaModel() {
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
  if ($app.kind -in @("url", "uri")) { Start-Process $app.target | Out-Null; return }
  Start-Process -FilePath $app.target | Out-Null
}

function Get-FallbackReply($message) {
  if ($message.ToLowerInvariant() -match "hello|hi|hey") {
    return "Hi. I am running locally and can open Windows apps or answer simple prompts."
  }
  if ($message.ToLowerInvariant() -match "plan|steps|roadmap") {
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

try {
  $listener.Start()
  Write-Host "AI server started at http://127.0.0.1:$Port/"

  while ($listener.IsListening) {
    $context = $listener.GetContext()
    try {
      $request = $context.Request
      $path = $request.Url.AbsolutePath

      if ($request.HttpMethod -eq "OPTIONS") {
        $context.Response.StatusCode = 204
        Set-Headers $context.Response
        continue
      }

      if ($request.HttpMethod -eq "GET" -and ($path -eq "/" -or $path -eq "/AI.html")) {
        Send-Html $context $htmlPath
        continue
      }

      if ($request.HttpMethod -eq "GET" -and $path -eq "/api/status") {
        $model = Get-OllamaModel
        Send-Json $context @{ ok = $true; apps = $true; voice = $true; ollama = [bool]$model; model = $model }
        continue
      }

      if ($request.HttpMethod -eq "POST" -and $path -eq "/api/chat") {
        $body = Read-Body $request
        $message = [string]$body.message
        $history = @($body.history)
        if ([string]::IsNullOrWhiteSpace($message)) {
          Send-Json $context @{ ok = $false; error = "Empty message." } 400
          continue
        }

        $app = Resolve-App $message
        if ($app) {
          Open-App $app
          Send-Json $context @{ ok = $true; mode = "app"; reply = "Opening $($app.label)." }
          continue
        }

        $ollama = Invoke-OllamaReply $history
        if ($ollama) {
          Send-Json $context @{ ok = $true; mode = "ollama"; model = $ollama.model; reply = $ollama.reply }
          continue
        }

        Send-Json $context @{ ok = $true; mode = "local"; reply = (Get-FallbackReply $message) }
        continue
      }

      Send-Json $context @{ ok = $false; error = "Not found." } 404
    } catch {
      Write-Warning $_
      Send-Json $context @{ ok = $false; error = $_.Exception.Message } 500
    } finally {
      $context.Response.OutputStream.Close()
      $context.Response.Close()
    }
  }
} finally {
  if ($listener.IsListening) { $listener.Stop() }
  $listener.Close()
}
