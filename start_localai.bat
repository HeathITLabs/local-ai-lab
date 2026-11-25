@echo off
REM Local AI Lab launcher: kept for existing shortcuts. It runs `studio up` (studio.ps1), which backs up
REM Solo's database, builds Solo and Studio from their working checkouts, starts the localai stack and LM Studio,
REM and waits until the studio is READY. Args: start_localai.bat [profile] [environment] (defaults: none public).
setlocal
set "PROFILE=%~1"
if "%PROFILE%"=="" set "PROFILE=none"
set "ENVIRONMENT=%~2"
if "%ENVIRONMENT%"=="" set "ENVIRONMENT=public"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0studio.ps1" up -ComposeProfile %PROFILE% -Environment %ENVIRONMENT%
set "RESULT=%ERRORLEVEL%"
echo.
echo Press any key to close this window...
pause >nul
endlocal & exit /b %RESULT%
