@echo off
rem Release protection: asks the worker to drop its power request and exit cleanly.
rem Safe to run even when nothing is protecting - it reports that and leaves it at that.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ka.ps1" stop
pause
