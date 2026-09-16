@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
title Codex Dual Usage v0.3.0 - Diagnose
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0diagnose.ps1"
echo.
pause
endlocal
