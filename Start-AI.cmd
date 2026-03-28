@echo off
setlocal
set "DIR=%~dp0"

start "AI Local Server" powershell -NoProfile -ExecutionPolicy Bypass -File "%DIR%server.ps1"
timeout /t 2 /nobreak >nul
start "" http://127.0.0.1:8765/
