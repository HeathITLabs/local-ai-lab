@echo off
REM One command for the whole studio: studio up ^| down ^| status ^| logs  (see studio.ps1)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0studio.ps1" %*
exit /b %ERRORLEVEL%
