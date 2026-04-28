@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0deploy-config.ps1" %*
