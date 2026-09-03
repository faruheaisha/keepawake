@echo off
rem Show whether the anti-sleep keeper is running.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0manage.ps1" -Action status %*
pause
