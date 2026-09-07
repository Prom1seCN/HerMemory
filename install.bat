@echo off
echo ============================================
echo   HerMemory installer (Windows)
echo   Details: docs\INSTALL.md
echo ============================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
echo.
pause
