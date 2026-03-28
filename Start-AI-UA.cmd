@echo off
setlocal
set "DIR=%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%DIR%Start-AI-UA.ps1"
