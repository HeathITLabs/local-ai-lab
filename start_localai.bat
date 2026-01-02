@echo off
setlocal
REM Local AI Stack Launcher
REM Starts the stack; defaults to GPU (NVIDIA) profile and private environment. Override with args: start_localai.bat [profile] [environment]

set "SCRIPT_DIR=%~dp0"
cd /d "%SCRIPT_DIR%"

set "PROFILE=%~1"
if "%PROFILE%"=="" set "PROFILE=gpu-nvidia"

set "ENVIRONMENT=%~2"
if "%ENVIRONMENT%"=="" set "ENVIRONMENT=private"

if not exist "start_services.py" (
    echo ERROR: start_services.py not found in current directory!
    echo Current directory: %CD%
    pause
    exit /b 1
)

echo Current directory: %CD%
echo.
echo Launching Local AI stack with profile "%PROFILE%" and environment "%ENVIRONMENT%"...
echo.

python start_services.py --profile %PROFILE% --environment %ENVIRONMENT%

if %ERRORLEVEL% neq 0 (
    echo.
    echo ERROR: Failed to start services! Error code: %ERRORLEVEL%
    echo.
) else (
    echo.
    echo Services started successfully!
    echo.
)

echo Press any key to close this window...
pause >nul
endlocal
