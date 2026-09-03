@echo off
rem One-click protection. The protection runs in its own worker process, so closing
rem this window (or the browser) does not stop it.
rem     on.bat            protect until you run off.bat
rem     on.bat 120        protect for 120 minutes, then release automatically
if "%~1"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ka.ps1" start
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ka.ps1" start -Minutes %~1
)
pause
