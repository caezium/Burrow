# Mole Windows Gap Map

This document explains why BurrowWin sometimes uses native Windows fallback instead of direct Mole CLI output.

## Current Adaptations

- Status: native Windows telemetry, because Mole Windows status is currently TUI-oriented.
- Analyze: native directory sizing and treemap, because `mo analyze` is interactive on Windows.
- Clean: Mole `clean --dry-run` preview is used and parsed; per-row deletion is not exposed by Mole Windows.
- Purge: native preview/removal using Mole-compatible project artifact patterns, because Mole Windows purge is an interactive selector.
- Installers: native old-download installer/archive matcher, because no dedicated Windows installer cleanup JSON command exists yet.
- Optimize: Mole `optimize --dry-run` for preview, confirmed `mo optimize` for real runs.
- Apps: native Windows installed-app inventory, because Mole uninstall is interactive.

## Replacement Rule

When Mole Windows exposes safe non-interactive JSON for one of these areas, replace the native fallback behind the existing service interface and keep the GUI/MCP contract stable.
