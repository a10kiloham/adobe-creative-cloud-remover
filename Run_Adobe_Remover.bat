@echo off
setlocal
cd /d "%~dp0"

REM Relaunch elevated if not already running as Administrator.
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo Starting Adobe Creative Cloud Removal Tool...
echo.
echo This will completely remove Adobe Creative Cloud from your system.
echo Please ensure you have backed up any important work.
echo.
echo Tip: run "Remove-Adobe.ps1 -DryRun" from PowerShell first to preview changes.
echo.
pause

REM Run the PowerShell script with execution policy bypassed. Extra arguments are passed through,
REM e.g.  Run_Adobe_Remover.bat -Force -SilentCleaner
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Remove-Adobe.ps1" %*

echo.
echo Script finished (exit code %errorlevel%). Press any key to exit.
pause >nul
