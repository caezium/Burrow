# Telemetry

BurrowWin does not send telemetry to a remote service.

The app records local operational state so the GUI, tray HUD, HTTP endpoints, and MCP tools can share the same view of the machine:

- settings: `%LOCALAPPDATA%\BurrowWin\settings.json`
- startup diagnostics: `%LOCALAPPDATA%\BurrowWin\startup.log`
- operation history: `%LOCALAPPDATA%\BurrowWin\history.jsonl`
- system telemetry history: `%LOCALAPPDATA%\BurrowWin\telemetry-history.jsonl`

HTTP endpoints are loopback-only. MCP tools expose local state to clients the user connects locally.

Users can delete `%LOCALAPPDATA%\BurrowWin` to clear local history and settings.
