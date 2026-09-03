@echo off
rem Stop the anti-sleep keeper and restore the normal power plan.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0manage.ps1" -Action stop %*
pause
