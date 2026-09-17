@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
title Codex Dual Usage v0.5.0 - Debug Launcher

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher.ps1" -DebugMode
if errorlevel 1 (
  echo.
  echo =============================================
  echo Debug startup failed.
  echo Check logs\startup-error.log and logs\tray.log.
  echo =============================================
  pause
  exit /b 1
)

echo Debug tray process launched. This window can be closed.
pause
endlocal
