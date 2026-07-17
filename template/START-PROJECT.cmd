@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"

where pwsh >nul 2>nul
if errorlevel 1 (
  echo Не найден PowerShell 7 ^(pwsh^).
  echo Установите PowerShell 7 или передайте ADMIN-SETUP.md техническому специалисту.
  pause
  exit /b 1
)

pwsh -NoProfile -File "%~dp0scripts\setup-project.ps1"
set "RESULT=%ERRORLEVEL%"
echo.
if not "%RESULT%"=="0" (
  echo Настройка не завершена. Файлы проекта следует проверить перед повторным запуском.
)
pause
exit /b %RESULT%
