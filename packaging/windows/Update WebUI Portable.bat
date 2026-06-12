@echo off
setlocal

set "SCRIPT=%~dp0Update WebUI Portable.ps1"

if not exist "%SCRIPT%" (
  echo Update helper was not found at %SCRIPT%.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "EXIT_CODE=%ERRORLEVEL%"

if "%EXIT_CODE%"=="0" (
  echo.
  echo Update finished.
) else (
  echo.
  echo Update failed with exit code %EXIT_CODE%.
)

pause
exit /b %EXIT_CODE%
