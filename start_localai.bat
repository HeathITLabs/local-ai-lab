@echo off
setlocal EnableExtensions EnableDelayedExpansion
REM Local AI Lab Launcher
REM Starts the Docker stack from one BAT file.
REM Defaults: no optional GPU profile, public environment for trusted LAN access.
REM Override with args:
REM   start_localai.bat [profile] [environment]
REM Examples:
REM   start_localai.bat
REM   start_localai.bat cpu private
REM   start_localai.bat none public

REM Keep this launcher in local-ai-lab; shortcuts should target it.
set "LAB_DIR=%~dp0"
for %%I in ("%LAB_DIR%..") do set "AI_ROOT=%%~fI"
if not defined SOLO_REPO_ROOT set "SOLO_REPO_ROOT=%AI_ROOT%\solo"
cd /d "%LAB_DIR%"

set "PROFILE=%~1"
if "%PROFILE%"=="" set "PROFILE=none"

set "ENVIRONMENT=%~2"
if "%ENVIRONMENT%"=="" set "ENVIRONMENT=public"

if not exist "start_services.py" (
    echo ERROR: start_services.py not found.
    echo Current directory: %CD%
    echo Expected lab directory: %LAB_DIR%
    pause
    exit /b 1
)

if not exist "docker-compose.yml" (
    echo ERROR: docker-compose.yml not found.
    echo Current directory: %CD%
    pause
    exit /b 1
)

echo Current directory: %CD%
echo.
echo Launching Local AI Lab with profile "%PROFILE%" and environment "%ENVIRONMENT%"...
echo.

docker info >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo Docker Desktop does not appear to be ready.
    if exist "C:\Program Files\Docker\Docker\Docker Desktop.exe" (
        echo Starting Docker Desktop...
        start "" "C:\Program Files\Docker\Docker\Docker Desktop.exe"
        echo Waiting for Docker Desktop to become ready...
        for /l %%I in (1,1,60) do (
            timeout /t 3 /nobreak >nul
            docker info >nul 2>&1
            if not errorlevel 1 goto docker_ready
        )
    )
    echo.
    echo ERROR: Docker is not ready. Start Docker Desktop and run this again.
    pause
    exit /b 1
)

:docker_ready

REM Refuse updates unless the existing Solo database has a verified checkpoint.
set "SOLO_CONTAINER="
for /f "delims=" %%C in ('docker ps -a --filter "name=^/solo-postgres$" --format "{{.Names}}"') do set "SOLO_CONTAINER=%%C"
if errorlevel 1 (
    echo BACKUP_FAILED: could not inspect Docker containers.
    exit /b 1
)
if "!SOLO_CONTAINER!"=="" (
    set "SOLO_VOLUME="
    for /f "delims=" %%V in ('docker volume ls --filter "name=^localai_solo-postgres-data$" --format "{{.Name}}"') do set "SOLO_VOLUME=%%V"
    if errorlevel 1 (
        echo BACKUP_FAILED: could not inspect Docker volumes.
        exit /b 1
    )
    if not "!SOLO_VOLUME!"=="" (
        echo BACKUP_FAILED: Solo volume exists but postgres container is missing.
        exit /b 1
    )
    echo FIRST_RUN_NO_DATABASE: no Solo container or volume found.
) else (
    powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%LAB_DIR%\scripts\backup-local-ai.ps1" -Backup Solo
    if errorlevel 1 (
        echo BACKUP_FAILED: refusing to update the environment.
        exit /b 1
    )
)
REM Production Solo is built from the latest release tag (vX.Y.Z), never from dev.
REM The tag is checked out as a detached worktree of the Solo repo, so the dev
REM checkout in SOLO_REPO_ROOT is never touched and never blocks a launch.
if not defined SOLO_RELEASE_ROOT set "SOLO_RELEASE_ROOT=%AI_ROOT%\solo-release"
if not exist "%SOLO_REPO_ROOT%\.git" (
    echo.
    echo ERROR: %SOLO_REPO_ROOT% is not a Git checkout.
    pause
    exit /b 1
)
where git >nul 2>&1
if errorlevel 1 (
    echo.
    echo ERROR: Git is required to check out the Solo release.
    pause
    exit /b 1
)

echo Fetching Solo release tags...
git -C "%SOLO_REPO_ROOT%" fetch --tags --force origin
if errorlevel 1 (
    echo.
    echo ERROR: Could not fetch Solo release tags from origin.
    pause
    exit /b 1
)

set "SOLO_RELEASE_TAG="
for /f "delims=" %%T in ('git -C "%SOLO_REPO_ROOT%" tag --list "v*" --sort=-v:refname') do (
    if not defined SOLO_RELEASE_TAG set "SOLO_RELEASE_TAG=%%T"
)
if not defined SOLO_RELEASE_TAG (
    echo.
    echo ERROR: Solo has no release tag ^(v*^). Cut a release first ^(docs/RELEASING.md^).
    pause
    exit /b 1
)

if exist "%SOLO_RELEASE_ROOT%\.git" (
    git -C "%SOLO_RELEASE_ROOT%" checkout --quiet --detach "!SOLO_RELEASE_TAG!"
) else (
    git -C "%SOLO_REPO_ROOT%" worktree add --detach "%SOLO_RELEASE_ROOT%" "!SOLO_RELEASE_TAG!"
)
if errorlevel 1 (
    echo.
    echo ERROR: Could not check out Solo !SOLO_RELEASE_TAG! in %SOLO_RELEASE_ROOT%.
    echo That folder is a release checkout: discard any local changes in it and run this again.
    pause
    exit /b 1
)
echo Solo release: !SOLO_RELEASE_TAG!
echo.

REM docker-compose.yml reads SOLO_BUILD_CONTEXT; start_services.py inherits it.
set "SOLO_BUILD_CONTEXT=%SOLO_RELEASE_ROOT%"
echo Building Solo !SOLO_RELEASE_TAG! with the latest base image...
docker compose -p localai --profile "%PROFILE%" -f docker-compose.yml build --pull solo
if errorlevel 1 (
    echo.
    echo ERROR: Failed to build Solo app image.
    pause
    exit /b 1
)
echo.

python start_services.py --profile "%PROFILE%" --environment "%ENVIRONMENT%"

if %ERRORLEVEL% neq 0 (
    echo.
    echo ERROR: Failed to start services! Error code: %ERRORLEVEL%
    echo.
) else (
    echo.
    echo Services started successfully!
    echo.
    echo Access URLs:
    echo   Solo:       http://localhost:3050
    echo   Solo:       http://192.168.1.139:3050
    echo   Open WebUI: http://192.168.1.139:3190
    echo   n8n:        http://192.168.1.139:5678
    echo   Flowise:    http://192.168.1.139:3001
    echo   SearXNG:    http://192.168.1.139:8081
    echo.
    echo These URLs are available to clients on the trusted LAN.
    echo.
)

echo Press any key to close this window...
pause >nul
endlocal
