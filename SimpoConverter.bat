@echo off
title SimpoConverter
rem Runs simpoconv.ps1 with Windows PowerShell without installing it.
rem Double-click for guided mode, or drop PDF files or folders on this file.
if "%~1"=="" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0simpoconv.ps1"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0simpoconv.ps1" %* -Open
)
echo.
pause
