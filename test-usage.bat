@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
title Codex Dual Usage v0.3.0 - Usage Test
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0test-usage.ps1"
echo.
pause
endlocal
