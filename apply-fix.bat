@echo off
title Starmancer Atmosphere & Thermal Fix Installer
echo ========================================================
echo   Starmancer Atmosphere, Thermal ^& Phantom Leak Fix
echo ========================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0patch.ps1"
echo.
pause