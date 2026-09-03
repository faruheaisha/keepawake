@echo off
rem Set "close lid = do nothing" (backs up the original value, needs one UAC click).
rem To undo later run:  powershell -File "%~dp0fix-lid.ps1" -Action restore
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fix-lid.ps1" -Action apply
pause
