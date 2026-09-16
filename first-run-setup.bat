@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
title Codex Dual Usage v0.3.0 - First Run Setup

echo =============================================
echo  Codex Dual Usage v0.3.0 - First Run Setup
echo =============================================
echo.
echo Step 1/2 - Personal account ^(Codex CLI will be auto-detected/installed if needed^)
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-personal.ps1" -NoPause
if errorlevel 1 goto :failed

echo.
echo ---------------------------------------------
echo Step 2/2 - Work account
echo ---------------------------------------------
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-work.ps1" -NoPause
if errorlevel 1 goto :failed

echo.
echo =============================================
echo  Both login steps finished.
echo  Next: double-click start.bat
echo =============================================
echo.
pause
exit /b 0

:failed
echo.
echo =============================================
echo  Setup stopped because one login failed.
echo  The error above will remain visible here.
echo =============================================
echo.
pause
exit /b 1
