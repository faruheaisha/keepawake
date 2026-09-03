@echo off
rem Launch the anti-sleep keeper in the background.
rem Extra args pass through, e.g.: start-keep-awake.bat -Minutes 120
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0manage.ps1" -Action start %*
pause
