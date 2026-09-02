@echo off
rem mo.cmd — the `mo` entrypoint. Forwards every argument UNCHANGED to invoke-mole.ps1 via
rem `powershell -File`, which passes them as an argv array and never interpolates them into a
rem command string (the previous `-Command "& 'mole.ps1' '%~1'…"` did, and a quote inside an
rem argument could break out of that literal and execute). %* is cmd's raw remaining argv.
powershell.exe -NoProfile -ExecutionPolicy Bypass -NoLogo -File "%~dp0invoke-mole.ps1" %*
exit /b %ERRORLEVEL%
