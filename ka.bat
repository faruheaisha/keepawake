@echo off
rem Keep-Awake command line entry point. Pure pass-through to ka.ps1, so every
rem subcommand and switch documented in README.md works here too:
rem     ka.bat status
rem     ka.bat start -Minutes 120
rem     ka.bat start -ExpireAt 09:00
rem     ka.bat start -Method mouse -IntervalSec 90 -Json
rem     ka.bat stop | report | check | evidence | log | config | guard | unguard
rem     ka.bat serve | stop-server | tray | requests | lid
rem With no argument it just shows the current status.
if "%~1"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ka.ps1" status
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ka.ps1" %*
)
