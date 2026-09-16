@echo off
setlocal
cd /d "%~dp0"

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

if not exist "%~dp0launcher.ps1" (
  echo [ERROR] launcher.ps1 was not found.
  echo Please download the repository again.
  pause
  exit /b 1
)

"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0launcher.ps1"
if errorlevel 1 (
  echo.
  echo [ERROR] Codex Dual Usage failed to start.
  echo Check logs\startup-error.log and logs\tray.log.
  pause
  exit /b 1
)

endlocal
exit /b 0
