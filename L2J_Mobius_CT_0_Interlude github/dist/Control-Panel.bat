@echo off
REM One-click GUI control panel for the L2 Offline Server.
REM Opens a window with Start / Stop / brain toggle and live status lights.
REM Nothing to install - Windows already has PowerShell and WPF.
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0launcher\Control-Panel.ps1"
