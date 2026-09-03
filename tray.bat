@echo off
rem Start the tray icon. It mirrors the worker's real state and can start/stop
rem protection without opening the dashboard. One instance only: a second run is
rem ignored while the first icon is alive.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ka.ps1" tray
pause
