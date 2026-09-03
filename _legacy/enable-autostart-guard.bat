@echo off
rem Install auto-start + watchdog scheduled tasks (current user, no admin).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-guard.ps1" -Action install
pause
