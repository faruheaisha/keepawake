@echo off
rem Open the local dashboard at http://127.0.0.1:8791/ (port comes from config.json).
rem Reuses a panel that is already serving; nothing leaves this machine.
rem The worker lives in its own process, so the protection continues after the browser
rem and this window are closed.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ka.ps1" serve
pause
