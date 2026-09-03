@echo off
rem Open the keep-awake control panel (GUI).
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0control-panel.ps1"
