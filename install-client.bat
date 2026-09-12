@echo off
setlocal

title sang Valheim Serverpack Installer
cd /d "%~dp0"

where powershell.exe >nul 2>nul
if errorlevel 1 (
    echo ERROR: powershell.exe was not found.
    echo This installer needs Windows PowerShell, which is included with Windows.
    echo.
    set /p "_=Press Enter to exit..."
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-client.ps1" %*
set "exitcode=%errorlevel%"

echo.
if "%exitcode%"=="0" (
    echo Done.
) else (
    echo Failed. Exit code: %exitcode%
)
echo.
set /p "_=Press Enter to exit..."
exit /b %exitcode%
