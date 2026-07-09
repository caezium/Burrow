@echo off
rem burrow-engine.cmd — the entrypoint name the `burrow` conductor resolves on Windows
rem (bash_entrypoint_names = burrow-engine | mole). Forwards to mole.ps1 exactly like mo.cmd,
rem so `burrow <cmd>` (Target::Bash) runs the bundled PowerShell engine. Bundled via the
rem Assets\Mole\** glob; the conductor is pointed here through BURROW_ENGINE_DIR.
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
