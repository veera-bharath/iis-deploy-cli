@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0rollback-deploy.ps1" %*
