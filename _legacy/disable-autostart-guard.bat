@echo off
rem Remove auto-start / watchdog scheduled tasks.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-guard.ps1" -Action uninstall
pause
