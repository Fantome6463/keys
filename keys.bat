@echo off
chcp 65001 >nul
rem   keys.bat            - окно управления (Keys.exe; соберётся при первом запуске)
rem   keys.bat status^|install^|admin^|update^|restart^|backup^|uninstall  - то же из консоли
if "%~1"=="" goto gui
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy\site.ps1" %*
goto :eof

:gui
if not exist "%~dp0Keys.exe" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy\build-exe.ps1"
if not exist "%~dp0Keys.exe" pause
if not exist "%~dp0Keys.exe" goto :eof
start "" "%~dp0Keys.exe"
