@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
title Codex Dual Usage v0.3.3 - Debug
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0tray.ps1"
echo.
echo =============================================
echo Tray process ended.
echo Please check logs\tray.log and logs\worker.log.
echo Keep this window open if an error is shown above.
echo =============================================
pause
endlocal
