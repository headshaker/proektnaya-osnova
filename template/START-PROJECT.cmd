@echo off
setlocal
cd /d "%~dp0"

if /i "%~1"=="--self-test" goto self_test
if exist "%~dp0setup-ui\runtime\Project Setup.exe" goto bundled_ui

where pwsh.exe >nul 2>nul
if errorlevel 1 goto missing_pwsh

pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-project.ps1"
set "RESULT=%ERRORLEVEL%"
if "%RESULT%"=="0" exit /b 0

echo.
echo Project setup did not finish. See ADMIN-SETUP.md for help.
pause
exit /b %RESULT%

:bundled_ui
start "" /wait "%~dp0setup-ui\runtime\Project Setup.exe"
set "RESULT=%ERRORLEVEL%"
if "%RESULT%"=="0" exit /b 0

echo.
echo The project window closed with an error.
echo No PowerShell commands are required from you.
echo Ask a technical specialist to read ADMIN-SETUP.md.
pause
exit /b %RESULT%

:self_test
where pwsh.exe >nul 2>nul
if errorlevel 1 goto missing_pwsh
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-project.ps1" -SelfTest
exit /b %ERRORLEVEL%

:missing_pwsh
echo This source copy is not prepared for one-click setup.
echo Download the official release package or ask a technical specialist
echo to prepare it using ADMIN-SETUP.md.
pause
exit /b 1
