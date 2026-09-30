@echo off
setlocal
if not exist "%~dp0CampusSrunGuardianControlPanel.exe" (
    echo The control-panel launcher is missing. Please re-download and extract the complete release ZIP.
    pause
    exit /b 1
)
start "" "%~dp0CampusSrunGuardianControlPanel.exe"
endlocal
