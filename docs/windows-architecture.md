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
