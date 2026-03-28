[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

function T([string]$base64) {
  return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($base64))
}

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$serverScript = Join-Path $dir "server.ps1"
$chatUrl = "http://127.0.0.1:8765/"
$statusUrl = "http://127.0.0.1:8765/api/status"

$host.UI.RawUI.WindowTitle = T "0JvQvtC60LDQu9GM0L3QuNC5INC30LDQv9GD0YHQuiBBSQ=="
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Test-LocalServer {
  try {
    $response = Invoke-RestMethod -Uri $statusUrl -Method Get -TimeoutSec 2
    return [bool]$response.ok
  } catch {
    return $false
  }
}

function Get-ServerStatus {
  try {
    return Invoke-RestMethod -Uri $statusUrl -Method Get -TimeoutSec 2
  } catch {
    return $null
  }
}

if (-not (Test-Path -LiteralPath $serverScript)) {
  throw "Missing server.ps1"
}

if (-not (Test-LocalServer)) {
  Write-Host (T "0JfQsNC/0YPRgdC60LDRjiDQu9C+0LrQsNC70YzQvdC40Lkg0YHQtdGA0LLQtdGAIEFJLi4u")
  Start-Process powershell -ArgumentList @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $serverScript
  ) | Out-Null

  Start-Sleep -Seconds 2
} else {
  Write-Host (T "0KHQtdGA0LLQtdGAINGD0LbQtSDQt9Cw0L/Rg9GJ0LXQvdC40Lkg0LDQsdC+INCy0ZbQtNC60YDQuNCy0YHRjyDQsiDQvdC+0LLQvtC80YMg0LLRltC60L3Rli4=")
}

$status = $null
for ($attempt = 0; $attempt -lt 10 -and -not $status; $attempt++) {
  $status = Get-ServerStatus
  if (-not $status) {
    Start-Sleep -Seconds 1
  }
}

if ($status -and $status.primaryUrl) {
  Write-Host ("Phone URL: " + $status.primaryUrl)
  try {
    Set-Clipboard -Value $status.primaryUrl
    Write-Host "Phone URL copied to clipboard."
  } catch {
  }
}

if ($status -and $status.localUrl) {
  $chatUrl = [string]$status.localUrl
}

Write-Host (T "0JLRltC00LrRgNC40LLQsNGOINGH0LDRgiDRgyDQsdGA0LDRg9C30LXRgNGWLi4u")
Start-Process $chatUrl | Out-Null
