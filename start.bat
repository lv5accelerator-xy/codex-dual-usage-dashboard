@echo off
setlocal
cd /d "%~dp0"
where wscript.exe >nul 2>nul
if errorlevel 1 (
  echo [ERROR] Windows Script Host not found.
  echo Please run start-debug.bat and send the error screenshot.
  pause
  exit /b 1
)
wscript.exe //nologo "%~dp0start-hidden.vbs"
endlocal
exit /b 0
