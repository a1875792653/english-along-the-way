@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0src\EnglishAlongTheWay.ps1"
if errorlevel 1 pause
