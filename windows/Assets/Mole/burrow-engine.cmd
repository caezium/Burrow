@echo off
rem burrow-engine.cmd — the entrypoint name the `burrow` conductor resolves on Windows
rem (bash_entrypoint_names = burrow-engine | mole). Forwards every argument UNCHANGED to
rem invoke-mole.ps1 via `powershell -File`, which passes them as an argv array and never
rem interpolates them into a command string (the previous `-Command "& 'mole.ps1' '%~1'…"`
rem did, and a quote inside an argument could break out of that literal and execute). %* is
rem cmd's raw remaining argv. Bundled via the Assets\Mole\** glob; the conductor is pointed
rem here through BURROW_ENGINE_DIR.
powershell.exe -NoProfile -ExecutionPolicy Bypass -NoLogo -File "%~dp0invoke-mole.ps1" %*
exit /b %ERRORLEVEL%
