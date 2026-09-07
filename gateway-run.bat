@echo off
title HerMemory Gateway - keep this window open
echo ============================================
echo  HerMemory gateway (foreground)
echo  Close this window to STOP the gateway.
echo ============================================
"%LOCALAPPDATA%\hermes\bin\hermes.exe" gateway run
echo.
echo Gateway exited. Press any key to close.
pause >nul
