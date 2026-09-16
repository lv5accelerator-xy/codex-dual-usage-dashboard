@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
title Codex - Login Work Account

echo =============================================
echo  Codex Usage - Work account login
echo =============================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-work.ps1" -NoPause
set "EC=%ERRORLEVEL%"
echo.
if not "%EC%"=="0" (
  echo [FAILED] Login did not finish. The error is shown above.
) else (
  echo [OK] Work account login step finished.
)
echo.
pause
exit /b %EC%
