# BurrowWin Architecture

BurrowWin is a native WinUI 3 desktop app with MVVM ViewModels, service-layer Windows/Mole integration, and local-only agent surfaces.

## Layers

- WinUI pages and windows render the Burrow-style interface and own platform-specific UI events.
- ViewModels expose page state, commands, and confirmation-gated workflows through CommunityToolkit.Mvvm.
- Services integrate Mole, Windows telemetry, disk scanning, app inventory, operation history, settings, tray behavior, and MCP/HTTP.
- `Tools\MoShim` produces the bundled `mo.exe` entry point.
- `Tools\McpStdioBridge` exposes the local MCP stdio bridge.

## Shared State

Dashboard, History, tray status, HTTP, and MCP should read from the same telemetry sampler/history where possible. Maintenance flows should record operation history through `IOperationHistoryService`.

## Safety Rules

- Prefer Mole for safe non-interactive commands.
- Keep Windows fallbacks explicit and task-scoped.
- Do not add a destructive path that bypasses preview or confirmation.
- Keep HTTP loopback-only.

### Native destructive fallback boundary

Only three native compatibility flows can recycle user-selected content: project artifact purge, old top-level Downloads installer/archive cleanup, and approved uninstall-leftover cleanup. Purge and installer MCP tools remain preview-only. The pending Clean GUI apply path is outside this contract and remains blocked on BUR-9.

Every native fallback candidate passes through `IWindowsPathSafetyPolicy`. The policy rejects non-absolute and raw traversal paths, drive/UNC roots, device and NT prefixes, `GLOBALROOT`, alternate data streams, protected Windows/application locations, missing or non-directory scopes, the configured scope root itself, canonical scope escapes, and reparse points in the scope-to-target chain. Flow services require membership in the latest completed preview, then re-check their own business rule and preview metadata immediately before calling `ISafeDeletionService`.

`ISafeDeletionService.DeleteAsync` requires `ConfirmedDeletionAuthorization`; there is no default confirmation Boolean. The authorization fingerprints the exact selected candidate set, source flow, expected scope, type, size, and relevant preview timestamp under one operation ID. A mismatched or omitted candidate is rejected at the final service boundary even if a UI caller is faulty.

The Recycle Bin adapter uses `IFileOperation` with `FOFX_RECYCLEONDELETE`, `FOF_NOERRORUI`, `FOF_NOCONFIRMATION`, `FOF_SILENT`, and `FOFX_EARLYFAILURE`. It never falls back to permanent deletion. Once a Shell call begins, cancellation waits for its result; the batch then stops before scheduling another candidate.

Batch results preserve every completed item and separately count recycled, already-absent, rejected, failed, and cancelled work. Only observed recycled bytes count as freed. Progress is monotonic and is capped below 100% when the final outcome is partial or cancelled. Preview progress is indeterminate because the scan total is not known in advance.

Receipts are JSONL records at `%LOCALAPPDATA%\BurrowWin\deletion-receipts.jsonl`. They correlate operation and receipt IDs with original/canonical paths, expected/observed size, disposition, source flow, timestamp, and failure/rejection reason. `IFileOperation` does not provide a reliable locator for the newly recycled item in this use, so `ExactRecoveryLocatorAvailable` remains false and `RecoveryLocator` remains null unless a future backend can supply both honestly.
