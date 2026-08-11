# Mole Windows Gap Map

This document explains why BurrowWin sometimes uses native Windows fallback instead of direct Mole CLI output.

## Current Adaptations

- Status: native Windows telemetry, because Mole Windows status is currently TUI-oriented.
- Analyze: native directory sizing and treemap, because `mo analyze` is interactive on Windows.
- Clean: the WinUI route is currently a guarded pending stub; no stable GUI cleanup preview/removal flow is claimed until Mole Windows exposes a safe non-interactive contract.
- Purge: native preview/removal using Mole-compatible project artifact patterns, because Mole Windows purge is an interactive selector.
- Installers: native old-download installer/archive matcher, because no dedicated Windows installer cleanup JSON command exists yet.
- Optimize: Mole `optimize --dry-run` for preview, confirmed `mo optimize` for real runs.
- Apps: native Windows installed-app inventory, because Mole uninstall is interactive.

Purge, Installers, and the Apps leftover-removal subflow are the only destructive native fallbacks. They share the BUR-10 path-safety, exact-confirmation, Recycle Bin-only, receipt, cancellation, and partial-result contracts documented in `windows-architecture.md`. Their MCP tools remain preview-only, and the pending Clean apply flow remains outside this boundary until BUR-9 is implemented.

## Replacement Rule

When Mole Windows exposes safe non-interactive JSON for one of these areas, replace the native fallback behind the existing service interface and keep the GUI/MCP contract stable.
