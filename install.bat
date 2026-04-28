@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\install-deploy-setup.ps1" %*
pause
