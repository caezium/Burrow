# Burrow Windows Alignment

## Product understanding

Burrow is a native GUI around the Mole CLI (`mo`). It is not a background service first and it is not a raw command launcher. The upstream macOS app presents the system maintenance tools as one cohesive desktop utility: live status, cleanup, purge, installers, optimize, software uninstall, disk analyze, history, activity, and agent access.

The upstream Burrow architecture is centered on shared data and command paths:

- `mo status --json` feeds a sampler and local history store, then powers Status, History, HTTP, and MCP.
- `mo analyze --json` feeds the disk analyzer and treemap.
- `mo clean`, `mo purge`, installer cleanup, and `mo optimize` run through a streamed command runner used by the GUI and agent surfaces.
- `mo uninstall --list` feeds the Software view.
- The GUI, local HTTP server, and stdio MCP server expose the same recent system state instead of separate interpretations.

Research references:

- `caezium/Burrow` main at `813334df0f274216d7012ff6e66cb6e566d881c0`
- `tw93/Mole` windows at `627342b3b59b21e39d0aac3bda1c06024047c79c`

## Windows adaptation rule

BurrowWin should keep the GUI-first product shape while using the Windows Mole branch as the OS engine. When Mole Windows does not yet expose a non-interactive JSON contract, BurrowWin may use a native Windows fallback, but the fallback should be presented as a compatibility layer and keep the same GUI/MCP surface as much as possible.

Current Windows-specific adaptations:

- Status uses native Windows telemetry because `mo status` is currently a TUI wrapper on Windows.
- A background telemetry sampler records snapshots every 60 seconds and is now the shared source for Dashboard, History, HTTP, MCP, tray status menu, and tray HUD.
- Analyze uses a native size-ranked tree plus Burrow-style treemap because `mo analyze` is currently interactive on Windows.
- Cleanup uses Mole `clean --dry-run`, parses Mole's exported clean list, and presents preview results as a read-only Mole plan because the Windows command does not support per-row GUI selection.
- Purge now uses a Burrow-style non-interactive preview/removal flow built from the same Windows Mole project markers and artifact patterns because Mole Windows `mo purge` is an interactive selector and does not expose `--dry-run`.
- Installers uses a Burrow-style preview/removal flow for old top-level Downloads installers and archives, mirroring Mole Windows `Clear-OldDownloads` rules because Mole Windows documents that there is no dedicated installer-file cleanup command yet.
- Optimize uses Mole `optimize --dry-run` for preview and requires explicit confirmation before real `mo optimize` changes.
- Uninstall lists installed apps natively, auto-loads the inventory on first view, supports search plus size/name/source sorting, and launches vendor uninstallers only after confirmation because the current Mole uninstall command is interactive.
- History and Activity are persisted locally and surfaced in the GUI and MCP/HTTP paths. Mole command executions, Windows uninstall actions, and BurrowWin native fallback preview/removal flows now write into the same operation history.
- Mole command history summaries are normalized before storage so GUI Activity, History, tray HUD, HTTP, and MCP surfaces do not show ANSI terminal escapes or CLI icon placeholders.
- History now renders Burrow-style trend cards for CPU, memory, disk, and network, has selectable 5m/1h/6h/24h/7d/30d/90d ranges, and shows a Top CPU Processes table backed by the same filtered telemetry history.
- MCP is local-only: HTTP binds to loopback and stdio uses the published bridge executable. The HTTP surface exposes `/health`, `/info`, `/snapshot`, and `/metrics`.
- MCP now includes the upstream read-only tool shape: `burrow_snapshot`, `burrow_history`, `burrow_top_processes`, `burrow_process_usage`, and `burrow_info`. Windows process usage can rank by `peak_cpu`, `avg_cpu`, `cpu_time`, `peak_mem`, or `avg_mem` using locally recorded telemetry.
- GUI startup now activates the main WinUI window before hosted background services finish, records startup phases to `%LOCALAPPDATA%\BurrowWin\startup.log`, and treats tray/background failures as diagnostics instead of blocking the first visible window.
- The Windows tray now provides a Burrow icon with live tooltip text, a left-click Burrow-style HUD window, a right-click status menu, quick navigation to Status, History, Activity, Clean, Optimize, and Settings, and a safe Exit Burrow command.
- Native tray registration uses the Windows `Shell_NotifyIconW` entry point and a window subclass callback for left-click HUD and right-click menu behavior.
- Tray HUD diagnostics can be triggered with `BURROWWIN_SHOW_TRAY_HUD=1` or `--show-tray-hud` so visible HUD smoke can be repeated when Windows allows the unsigned debug build to run.
- Settings are persisted in `%LOCALAPPDATA%\BurrowWin\settings.json` and now control sampling interval, history retention, HTTP enable/port, tray visibility, and MCP destructive-action opt-in. Sampling, tray visibility, HTTP enable/port changes, and destructive-action gates apply immediately.
- Settings now uses the same Burrow dark card surface as the other utility panes while keeping the existing engine, agent access, behavior, local history, and recent activity bindings.
- Repository release readiness now includes MIT license, README, contribution/security/telemetry docs, Windows architecture and Mole gap docs, GitHub Actions CI/release workflows, and an unsigned Inno Setup installer plus portable ZIP fallback release script with SHA256 output.
- Windows installation now follows upstream Burrow's package-manager-first rhythm: WinGet package `Caezium.Burrow` is the recommended user path, while direct setup exe and ZIP downloads remain fallback paths.

## Latest verification

- `dotnet build BurrowWin.csproj -p:Platform=x64 -nr:false -v:minimal` succeeds with 0 warnings and 0 errors.
- `dotnet build Tests\BurrowWin.Tests\BurrowWin.Tests.csproj -nr:false -v:minimal` succeeds with 0 warnings and 0 errors.
- `dotnet test Tests\BurrowWin.Tests\BurrowWin.Tests.csproj --no-build -v:minimal` passes 66 tests with 0 failures and 0 skipped tests.
- Mole command history normalization is covered by `ExecuteCommandAsync_RecordsAnsiFreeHistorySummary`, including ANSI color removal, control character removal, and CLI icon placeholder removal.
- HTTP runtime settings changes are covered by `HttpServerSettingsPlannerTests`, including no-op, start, stop, restart, and disabled-stays-disabled decisions.
- `.\run-local.ps1 -NoBuild -SmokeTest -Restart -RequireHealth -TimeoutSeconds 45` starts the x64 Debug GUI, confirms the `BurrowWin` main window is visible, confirms `/health` returns `ok: true`, and writes startup diagnostics to `%LOCALAPPDATA%\BurrowWin\startup.log`.
- `.\run-local.ps1 -NoBuild -SmokeTest -Restart -RequireHealth -Route purge -TimeoutSeconds 45` starts the x64 Debug GUI, confirms `/health` returns `ok: true`, and startup diagnostics record `Opening startup route: purge`.
- `.\run-local.ps1 -NoBuild -SmokeTest -Restart -RequireHealth -Route clean -CleanAutoScan -TimeoutSeconds 90` starts the x64 Debug GUI, confirms `/health` returns `ok: true`, waits for startup diagnostics to record `Opening startup route: clean`, and waits for `Clean autoscan finished`.
- The Clean autoscan smoke records Mole `clean --dry-run` in `%LOCALAPPDATA%\BurrowWin\history.jsonl`, confirming the read-only preview still flows through the shared Mole command/activity path.
- `.\run-local.ps1 -NoBuild -SmokeTest -Restart -RequireHealth -Route optimize -OptimizeAutoScan -TimeoutSeconds 120` starts the x64 Debug GUI, confirms `/health` returns `ok: true`, waits for startup diagnostics to record `Opening startup route: optimize`, and waits for `Optimize auto-preview finished`.
- The Optimize autoscan smoke records Mole `optimize --dry-run` in `%LOCALAPPDATA%\BurrowWin\history.jsonl` with a normalized summary, confirming the preview path stays tied to the shared Mole command/activity path without terminal escape output.
- `.\run-local.ps1 -NoBuild -SmokeTest -Restart -RequireHealth -Route settings -TimeoutSeconds 45` starts the x64 Debug GUI, confirms `/health` returns `ok: true`, and waits for startup diagnostics to record `Opening startup route: settings`.
- `run-local.ps1` now supports `-ScreenshotPath` for repeatable local GUI evidence. The capture path restores the BurrowWin window, brings it to the foreground, writes a PNG, and then releases the topmost state.
- Screenshot smoke captured `artifacts\ui-smoke\burrowwin-settings.png`, `artifacts\ui-smoke\burrowwin-history.png`, `artifacts\ui-smoke\burrowwin-clean.png`, `artifacts\ui-smoke\burrowwin-installer.png`, and `artifacts\ui-smoke\burrowwin-analyze.png` from the same `run-local.ps1` health-gated GUI startup flow.
- The History screenshot smoke confirms the Burrow-style range selector and CPU, memory, disk, and network trend cards render on the default `1h` range.
- The Clean screenshot smoke uses `-CleanAutoScan`, waits for `Clean autoscan finished`, and confirms the Burrow-style Clean landing surface plus preview item panel renders after Mole `clean --dry-run`.
- `.\run-local.ps1 -NoBuild -SmokeTest -Restart -RequireHealth -Route installer -InstallerRoot artifacts\installer-smoke -InstallerAutoScan -TimeoutSeconds 45` starts the x64 Debug GUI, confirms `/health` returns `ok: true`, waits for startup diagnostics to record `Opening startup route: installer`, and fails if the current launch records a XAML unhandled exception.
- Installer autoscan diagnostics from the sample directory record `Installer autoscan finished: 3 files - 14 KB`, proving the page applied the old Downloads installer/archive matcher and ignored the fresh sample file.
- The Installer screenshot smoke uses an absolute sample root and visually confirms the 3 old installer/archive rows, sizes, dates, and preview/remove action area.
- The same installer autoscan smoke appends `%LOCALAPPDATA%\BurrowWin\history.jsonl` with `Source=burrowwin`, `Operation=installer-preview`, and `Summary=3 files - 14 KB`, confirming native fallback activity reaches the shared operation history.
- `.\run-local.ps1 -NoBuild -SmokeTest -Restart -RequireHealth -Route analyze -TimeoutSeconds 45` starts the x64 Debug GUI and confirms the Analyze route opens cleanly.
- `artifacts\burrowwin-analyze-treemap-smoke.png` was captured from a temporary sample directory with `BURROWWIN_ANALYZE_AUTOSCAN=1` and confirms the Analyze treemap renders real size-proportional tiles.
- The latest Analyze screenshot smoke uses an absolute controlled sample root, waits for `Analyze autoscan finished: Scanned ...\artifacts\ui-smoke-sample`, and visually confirms a size-proportional treemap for `AppCache`, `Logs`, and `Downloads`.
- `.\run-local.ps1 -NoBuild -SmokeTest -Restart -RequireHealth -Route apps -TimeoutSeconds 45` starts the x64 Debug GUI, confirms `/health` returns `ok: true`, and opens the Apps route cleanly.
- `artifacts\burrowwin-apps-smoke.png` visually confirms the Apps route auto-loads installed applications, renders readable app rows, and shows the active sort state.
- `dotnet .\Tools\McpStdioBridge\bin\Debug\net8.0\burrow-mcp-stdio.dll` responds to `tools/list` and exposes the `metric` input on `burrow_top_processes`.
- History chart, time-range, and Top CPU Process UI changes compile through WinUI XAML generation in the x64 Debug build. Range resolution, read-limit estimation, and sample filtering are covered by unit tests.
- Tray HUD/menu changes compile through the x64 Debug build; tray menu and tray HUD status formatter coverage are included in the test suite.
- Runtime smoke verified the x64 Debug app starts, `http://127.0.0.1:9277/health` responds, `/snapshot` returns live Windows telemetry, `/metrics?limit=2` returns recorded samples, and `Assets\Mcp\burrow-mcp-stdio.exe` can call `burrow_snapshot`, `burrow_info`, `burrow_top_processes`, and `burrow_process_usage`.
- Runtime smoke after the tray HUD/menu work launched `bin\x64\Debug\...\BurrowWin.exe` and confirmed `/health` returned `ok: true`, engine availability, and a fresh `latest_sample_at`.
- Latest tray HUD screenshot smoke launched `bin\x64\Debug\...\BurrowWin.exe` with `BURROWWIN_SHOW_TRAY_HUD=1`, captured `artifacts\burrowwin-tray-hud-smoke.png`, and visually confirmed the HUD window, status cards, activity card, top CPU process rows, and quick navigation buttons render without clipping.
- `.\scripts\build-release.ps1` restores, builds Release x64, runs the 66-test suite, publishes the portable WinUI payload, creates `Burrow-v0.1.0-preview.1-win-x64-setup.exe`, creates `Burrow-v0.1.0-preview.1-win-x64.zip`, writes `SHA256SUMS.txt`, writes WinGet manifests, and copies release docs into the payload.
- The generated installer and ZIP contain `BurrowWin.exe`, `Assets\Mole\mo.exe`, `Assets\Mcp\burrow-mcp-stdio.exe`, README, LICENSE, release notes, Windows alignment notes, and Mole gap notes.
- The generated installer and ZIP hashes verify against `artifacts\release\SHA256SUMS.txt`.
- The generated WinGet manifest targets `Caezium.Burrow`, package name `Burrow`, `InstallerType: inno`, `Scope: user`, x64 architecture, and the GitHub Release setup exe URL.
- `winget validate artifacts\release\winget\Caezium\Burrow\0.1.0-preview.1` succeeds. WinGet reports dependency validation is deferred for `Microsoft.DotNet.DesktopRuntime.8`, which must exist in the community repository before submission.
- A clean extraction of `Burrow-v0.1.0-preview.1-win-x64.zip` launches `BurrowWin.exe`, shows the main window, and returns `/health` with `ok: true` on port 9277.
- Silent installer smoke could not run on this workstation because local Application Control policy blocks unsigned setup executables. This is consistent with the preview's unsigned release model and is now documented for direct-download users.

## Known gaps before calling the Windows port complete

- Broaden screenshot/UI automation coverage for tray-menu actions and navigation, beyond the diagnostic tray HUD visual smoke.
- Move history storage closer to upstream Burrow's SQLite/WAL model or prove the JSONL store meets the same retention, pruning, and query requirements.
- Broaden History screenshot/UI automation from the default rendered range to explicit range-switching interactions.
- Replace Windows fallbacks with Mole JSON paths when the Mole windows branch exposes safe non-interactive contracts for status, analyze, uninstall, purge, and installer scans.
- Harden all destructive operations with a single shared preview-first operation flow, cancellation, progress streaming, operation-center activity state, and explicit confirmation gates.
- Add pixel/interaction comparison for the Windows Burrow visual shell against the upstream reference screens, beyond the current route-level screenshot smoke.

## Completion criteria for this port

- The first visible experience must be a desktop GUI, not documentation, logs, or a CLI-only launcher.
- The user must be able to navigate the main Burrow tool areas from the shell.
- Mole must be the bundled/primary engine path where it is safe and non-interactive.
- Windows fallbacks must be explicit and task-scoped where Mole Windows lacks JSON or safe background behavior.
- GUI history/activity and MCP/HTTP state must come from the same recorded local state where possible.
- Destructive actions must remain preview-first and confirmation-gated.
