@echo off
rem Open the native desktop application.
if exist "%~dp0KeepAwake.exe" (
    start "" "%~dp0KeepAwake.exe"
    exit /b 0
)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0ka-desktop.ps1" launch
