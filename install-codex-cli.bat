@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
title Codex CLI Installer
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-codex-cli.ps1"
set "EC=%ERRORLEVEL%"
echo.
pause
exit /b %EC%
