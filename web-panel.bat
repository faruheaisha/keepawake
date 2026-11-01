@echo off
rem Optional legacy web panel. The main desktop entry is KeepAwake.exe or panel.bat.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ka.ps1" serve
