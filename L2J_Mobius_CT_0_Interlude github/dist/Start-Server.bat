@echo off
title L2 Offline Server - Launcher
REM One-click boot for the whole stack. Edit launcher\launcher.ini for your machine.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher\launcher.ps1"
REM Each server runs in its own window, so once startup succeeds this launcher
REM window has nothing left to do - let it close on its own. Only hold it open
REM when startup failed, so the error stays readable.
if not "%ERRORLEVEL%"=="0" (
  echo.
  echo Startup failed - see the messages above.
  pause
)
