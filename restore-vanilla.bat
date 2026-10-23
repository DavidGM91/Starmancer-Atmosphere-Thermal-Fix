@echo off
title Starmancer Restore Vanilla
echo ========================================================
echo   Restoring Original Vanilla StarmancerMod.dll
echo ========================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0restore.ps1"
echo.
pause