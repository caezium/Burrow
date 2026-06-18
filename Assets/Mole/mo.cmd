@echo off
setlocal EnableDelayedExpansion
set "MOLE_DIR=%~dp0"

set "ARGS="
:parse
if "%~1"=="" goto run
set "ARGS=!ARGS! '%~1'"
shift
goto parse

:run
powershell.exe -ExecutionPolicy Bypass -NoLogo -NoProfile -Command "& '%MOLE_DIR%mole.ps1' !ARGS!"
