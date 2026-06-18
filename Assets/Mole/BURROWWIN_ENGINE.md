# BurrowWin Mole Engine Asset

This folder vendors the `tw93/Mole` Windows branch runtime scripts so BurrowWin can resolve a local OS engine before falling back to a user PATH installation.

- Upstream repository: https://github.com/tw93/Mole/tree/windows
- Upstream commit: `627342b3b59b21e39d0aac3bda1c06024047c79c`
- License: MIT, see `LICENSE` in this folder.

BurrowWin builds and copies a local `mo.exe` shim from `Tools/MoShim` into this folder. The shim forwards arguments, stdout, stderr, and exit codes to `mole.ps1`. The upstream Windows branch currently exposes the engine as PowerShell scripts plus optional TUI binaries rather than a stable standalone `mo.exe`, so this shim provides the PRD-compatible executable entrypoint while preserving Mole as the OS engine.
