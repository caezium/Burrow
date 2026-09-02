# invoke-mole.ps1 — the one PowerShell entry the .cmd shims forward to.
#
# Reached only through `powershell -File`, which hands this script its arguments as an ARRAY
# ($args) that PowerShell never re-parses as code. The shims used to build a `-Command` string
# with every argument single-quoted into it ('%~1'), and a string is the wrong carrier for
# argv: an argument containing a quote closed the literal early and whatever followed ran as
# PowerShell. Splatting `@args` passes each element positionally to mole.ps1's own param block —
# `$Command` first, the rest into `$CommandArgs` — so a `--json`-shaped or space-containing
# argument arrives as the single value it was, and the engine's exit status is what this exits.
#
# No param block on purpose: with one, an argument shaped like `-x` could bind to a parameter
# instead of riding through in $args.
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'mole.ps1') @args
exit $LASTEXITCODE
