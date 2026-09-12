@echo off
setlocal

title sang Valheim Serverpack Installer
cd /d "%~dp0"

echo.
echo ============================================
echo   sang Valheim Serverpack Installer
echo ============================================
echo.
echo This will install the required Valheim client mods.
echo Keep this window open to watch the install log.
echo.

where powershell.exe >nul 2>nul
if errorlevel 1 (
    echo ERROR: powershell.exe was not found.
    echo This installer needs Windows PowerShell, which is included with Windows.
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-client.ps1" %*
set "exitcode=%errorlevel%"

echo.
if "%exitcode%"=="0" (
    echo Install finished.
) else (
    echo Install failed with exit code %exitcode%.
)
echo.
pause
exit /b %exitcode%
