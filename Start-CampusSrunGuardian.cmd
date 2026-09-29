@echo off
setlocal
powershell.exe -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0ControlPanel.ps1"
endlocal
