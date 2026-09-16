@echo off
title HerMemory Gateway - keep this window open
echo ============================================
echo  HerMemory gateway (foreground)
echo  Close this window to STOP the gateway.
echo ============================================
rem HERMES_HOME 可由安装时自定义（数据位置页）；缺省才是 %LOCALAPPDATA%\hermes。
rem 写死默认值会让自定义目录的实例找不到 hermes.exe。
if "%HERMES_HOME%"=="" set "HERMES_HOME=%LOCALAPPDATA%\hermes"
"%HERMES_HOME%\bin\hermes.exe" gateway run
echo.
echo Gateway exited. Press any key to close.
pause >nul
