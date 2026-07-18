@echo off
setlocal
cd /d "%~dp0"

where pwsh.exe >nul 2>nul
if errorlevel 1 goto missing_pwsh
if /i "%~1"=="--self-test" goto self_test

pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-project.ps1"
set "RESULT=%ERRORLEVEL%"
if "%RESULT%"=="0" exit /b 0

echo.
echo Project setup did not finish. See ADMIN-SETUP.md for help.
pause
exit /b %RESULT%

:self_test
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-project.ps1" -SelfTest
exit /b %ERRORLEVEL%

:missing_pwsh
echo PowerShell 7 is required to configure this project.
echo Install PowerShell 7 and run START-PROJECT.cmd again.
echo Details: ADMIN-SETUP.md
pause
exit /b 1
