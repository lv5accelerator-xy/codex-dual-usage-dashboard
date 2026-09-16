@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
title Codex Dual Usage v0.3.5 - Debug
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0tray.ps1"
echo.
echo =============================================
echo Tray process ended.
echo Check logs\tray.log, logs\worker.log, and logs\startup-error.log.
echo Keep this window open if an error is shown above.
echo =============================================
pause
endlocal
