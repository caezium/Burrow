# Burrow 0.10.0

The conductor release. Burrow now ships its own command layer — the bundled
`burrow` CLI conducts the bundled engine with one stable JSON contract — plus a
brand-new Duplicates pane, and fixes for the sudo dialog, uninstall UX, and
Tune-Up display bugs you reported.

## New: Duplicates
- **Find what you've stashed twice.** A new sidebar pane scans any folder for
  byte-identical copies. Review them checklist-style — every group preselects
  all but one copy, and always keeps at least one — then **Move to Trash**
  (recoverable) or **Reclaim via APFS clones**, which frees the space without
  deleting a single file. ([#260](https://github.com/caezium/Burrow/pull/260),
  [#264](https://github.com/caezium/Burrow/pull/264),
  [#266](https://github.com/caezium/Burrow/pull/266))

## The conductor
- **Burrow bundles `burrow`.** A universal (Apple Silicon + Intel) conductor
  CLI ships inside the app and drives the bundled engine — disk analysis,
  status, history, clean, and optimize all route through it. Burrow now works
  fully out of the box with no Homebrew engine install, agents and the GUI
  share one command surface, and every path falls back to the direct engine so
  nothing regresses. ([#251](https://github.com/caezium/Burrow/pull/251),
  [#261](https://github.com/caezium/Burrow/pull/261),
  [#265](https://github.com/caezium/Burrow/pull/265))
- **Windows groundwork** rides along: the Windows app bundles `burrow.exe` and
  parses the same envelope contract.
  ([#252](https://github.com/caezium/Burrow/pull/252))

## Fixes
- **The admin password dialog appears again.** Uninstalling a root-owned app
  (Zoom et al.) from the GUI failed with "Admin access denied" because the
  engine permission-tested `/dev/tty` instead of opening it — GUI runs now get
  the proper macOS password prompt.
  ([#253](https://github.com/caezium/Burrow/issues/253))
- **Failed uninstalls are actionable.** The Software pane keeps your list and
  selection and shows the engine's actual error, instead of silently rescanning
  and pinging only the HUD.
  ([#254](https://github.com/caezium/Burrow/issues/254))
- **Tune-Up sizes render clean** — no more raw `[0;31m` color codes around the
  reclaimable amount. ([#257](https://github.com/caezium/Burrow/issues/257))
- **Analyze can't freeze on cache-heavy folders** — per-child scans are
  timeout-bounded and show partial results instead of stalling; the menu-bar
  popover no longer rubber-bands into empty space.
  ([#256](https://github.com/caezium/Burrow/pull/256))

## For agents
- **7 new read-only MCP tools** through the bundled conductor — duplicates,
  orphaned files, per-app network usage, cleaning-rule previews, trash
  sentinel, app-slim check, similar photos — 21 read-only tools total.
  ([#258](https://github.com/caezium/Burrow/pull/258))

## Windows preview
- **Downloadable at last**: this release ships `BurrowWin-0.10.0-win-x64.zip` —
  the unpackaged Windows app with the `burrow.exe` conductor and the engine
  bundled (unzip and run `BurrowWin.exe`; Windows 10/11, .NET 8 runtime).
- **The conductor, on Windows too**: agent-triggered clean/optimize route
  through `burrow.exe` with the same envelope contract the macOS app speaks.
  ([#252](https://github.com/caezium/Burrow/pull/252))
- **`burrow.exe` grew real Windows powers** this cycle: Recycle-Bin safe
  delete (never hard-deletes), guarded Bulk Crap Uninstaller uninstalls,
  czkawka-backed duplicate + similar-photo discovery, provider-aware
  OneDrive/Cloud Files eviction, and per-app network attribution via the
  native IP Helper API.

## Also
- Per-metric menu-bar text sizing with stable widths, and flipped net in/out
  ordering. ([#245](https://github.com/caezium/Burrow/pull/245))
- The HUD popover re-pins itself when the menu bar auto-hides after opening.
  ([#223](https://github.com/caezium/Burrow/issues/223))
- Self-update runs `brew update` before upgrading, so it actually sees new
  versions. ([#243](https://github.com/caezium/Burrow/issues/243))

# Burrow 0.9.2

A stability and battery release — several fixes to Cleanup, Analyze, and the
menu bar, plus a round of performance work that makes Burrow noticeably lighter
when it's sitting idle in the background.

## Fixes
- **Purge works again.** Cleanup → Project build artifacts was refusing every
  removal ("Couldn't confirm the selection safely") because the engine renders
  its list with items pre-selected — Burrow now toggles the difference so your
  selection actually applies. ([#231](https://github.com/caezium/Burrow/issues/231))
- **Analyze no longer floods the machine with engine processes.** Superseded
  scans are cancelled and concurrency is capped, so opening or refreshing the
  Analyze tab won't peg your CPU with a pile of `analyze-go` processes.
  ([#232](https://github.com/caezium/Burrow/issues/232))
- **Camera/mic in-use indicator is honest.** It no longer false-lights from
  virtual audio/video devices (loopback, Camo, Teams, …) — e.g. playing audio
  through a virtual device — and clears reliably when capture ends.
  ([#234](https://github.com/caezium/Burrow/issues/234))
- **Menu-bar popover** stays put instead of flying to a screen edge, and sizes
  to its own display on multi-monitor setups.
  ([#223](https://github.com/caezium/Burrow/issues/223))
- Fewer spurious "App Hang" reports.

## Performance & battery
- **The metrics engine stops hammering the sensors when nothing is on screen.**
  It used to read the SMC temperature/fan and GPU counters ~once a second for the
  whole time the app was running; those reads are now cached, and idle stream
  frames are skipped when no window is open — a real battery win.
  ([#235](https://github.com/caezium/Burrow/issues/235), [#237](https://github.com/caezium/Burrow/issues/237))
- Bounded Analyze memory (walk/icon caches now evict).
  ([#236](https://github.com/caezium/Burrow/issues/236))
- System probes (Doctor, disk SMART, Time Machine) are timeout-guarded so a
  stuck system tool can't hang the pane; Doctor results are cached across reopens.
  ([#239](https://github.com/caezium/Burrow/issues/239))
- Network-usage views share one sample instead of each running a 1-second scan.
  ([#238](https://github.com/caezium/Burrow/issues/238))
- Smaller idle-timer and date-formatter cleanups.
  ([#240](https://github.com/caezium/Burrow/issues/240))

## Under the hood
- Dead-code prune; the Homebrew cask no longer depends on a system `mole`
  (the engine has been bundled since 0.9.0).

---

# Burrow 0.9.1

A quick fix for **Intel Macs**. In 0.9.0 the newly-bundled engine binaries were
built Apple-Silicon-only, so on Intel (x86_64) Macs Burrow could hang at
initialization ([#221](https://github.com/caezium/Burrow/issues/221)). The engine
(`status-go` / `analyze-go`) is now a **universal binary** (arm64 + x86_64) and
runs natively on both architectures. No other changes from 0.9.0.

---

# Burrow 0.9.0

Burrow's biggest release. It now **bundles its own engine** — no separate `mo`
install — and adds an Activity-Monitor-class **process inspector** with a CPU
watchdog, a **Get Online** connectivity companion, a security-aware **Doctor**,
and smarter Clean, Software, Analyze, and Optimize across the board. Still
local-first, still free.

## Engine
- **Burrow bundles its own engine now.** The app ships an MIT-licensed
  `burrow-engine` (a fork of Mole `mo` at its last MIT release) inside
  `Burrow.app` and runs it directly — so a fresh install needs **no separate
  `brew install mole`**. Burrow prefers the bundled engine, then an installed
  `burrow-engine`, then a legacy system `mo` for existing setups. (#218)

## Process inspector (Status)
- **Per-process inspector** — click any process for a structured panel: identity
  (path, code signature, Mach-O architecture), live CPU/memory, runtime, and the
  process's open network connections.
- **Process tree** — the parent/child hierarchy around any process.
- **CPU watchdog** — set per-process CPU thresholds and get notified when
  something runs hot, with an editor in Settings.
- **Filter, suspend/resume, export** — a typed predicate filter over the process
  table, suspend or resume a process, and export the table.

## Get Online (connectivity companion)
- **On-demand speed test** — measure real down/up throughput.
- **Nearby Wi-Fi scan** — surrounding networks and channel congestion (Home
  mode), so you can pick a clearer channel.
- **Venue captive-portal tips** — venue-specific help for hotel/airport/café
  portals that won't load.
- **Connection history** — a log of connectivity events (SSID changes, drops).

## Doctor (diagnostics)
- **Security posture** — SIP, Gatekeeper, FileVault, and firewall at a glance,
  plus a high-CPU check and one-click **Copy diagnostics**.
- **Battery health** — capacity % and condition (omitted on desktops).
- **More context** — display, external-volume, and network context.

## Clean, Software, Analyze & Optimize
- **Clean** now sorts the review **by reclaimable impact** and **flags sensitive
  paths** (keychain/credential locations) before you delete; the done screen
  shows your **all-time cleaned total**.
- **Software** — App Store updates that need a newer macOS are hidden; ⌘R
  refreshes with a cache bypass; app search is alias-aware.
- **Uninstall** — a Clear-Data-only subset, plus an input-method leftover
  warning.
- **Analyze** — one-tap whole-disk scan, and a treemap "Other" fold for tiny
  entries.
- **Optimize** — a pre-run safety banner when a VPN or external display is
  active.
- **Login items** — modern Login (BTM) items appear in the startup inventory; a
  LaunchAgent on an unplugged drive is no longer flagged broken.
- **Keep Screen On** keeps working with the lid closed.

## Fixed
- **Three main-thread hangs** on the new process/parity surfaces (suspend/resume,
  inspector, tree). (#216)
- A missing `paths:` label on a data-only uninstall plan.

## Windows
- **Windows preview** — version-aligned to 0.9.0; no Windows-specific changes
  this release.

# Burrow 0.8.3

A metrics & menu-bar release: real memory-pressure reporting, a power-draw
widget, pressure-aware coloring everywhere, a live menu-bar preview, two new
runner animations, and a snappier popover. Still local-first.

## Added
- **Power-draw widget.** Live system wattage (W) as a menu-bar metric.
- **Real memory pressure.** "By pressure" now reads actual macOS memory pressure
  — `(wired + compressed) / total` via `host_statistics64`, the same figure
  Activity Monitor reports — instead of reusing the CPU-style utilization ramp.
  Shown as a percentage on the memory tiles, colored green ≤59% / orange 60–79% /
  red ≥80%. (#202)
- **Memory detail card.** The Status dashboard breaks memory down into used /
  free / cached / swap.
- **Live menu-bar preview + layout presets.** Settings previews your *real*
  metrics as you configure them, with one-tap layout presets.
- **Two new runner animations** — Wave and Bars.

## Changed
- **Consistent pressure coloring** across the dashboard tile, popover,
  memory-detail card, and menu bar.
- **Live popover sparklines.** CPU / memory / GPU tick every second (about a
  minute of history).
- **Honest color picker.** "By pressure" is offered only where it applies
  (memory); the temperature color ramp was corrected.

## Fixed
- **Brewfile import/export pickers no longer trip the hang detector** (ANR
  false-positives).
- **App-Hang reports from memory-starved machines are dropped** before sending —
  they were environmental, not Burrow bugs. (#197)

## Performance
- **Snappier popover** — the metric grid no longer re-renders on unrelated state
  changes.

## Windows
- **Windows preview** — a version-aligned 0.8.3 build is attached
  (`BurrowWin-0.8.3-win-x64.zip`). No Windows-specific changes this release.

# Burrow 0.8.2

A fix release: a Full Disk Access grant now actually takes effect, and Burrow
asks for notification permission up front instead of mid-alert. Still
local-first.

## Fixed
- **Full Disk Access is honored again.** The shipped app's embedded framework
  signatures were malformed (`codesign --verify --strict` failed on
  `Sentry.framework`), so macOS couldn't validate Burrow's identity and silently
  ignored a Full Disk Access grant — turning it on in System Settings appeared to
  do nothing. The release now re-signs the app and every nested framework
  inside-out so the signature is valid and the grant takes effect. After
  updating, toggle Full Disk Access off and back on once. (Burrow is still
  ad-hoc-signed, so a re-grant is needed after each update until it ships with a
  Developer ID signature.) (#177)

## Changed
- **Notification permission is requested up front.** Burrow now asks once — when
  you finish onboarding or first enable a notifying feature — instead of
  springing the system prompt the moment a notification tries to fire.

# Burrow 0.8.1

A stability release: the live dashboard no longer freezes, live status now
streams, and there's a one-click Homebrew update button — plus the Windows
preview catches up on its code review. Still local-first.

## Fixed
- **No more "App Hanging" freezes.** The Overview dashboard used to re-render
  its whole grid — every chart tile and the full process table — once a second;
  now only the small Disk / Network tiles update that often, the rest on the
  snapshot. Opening **Settings** and the **About** panel no longer blocks the
  main thread either (login-item status, metrics-folder sizing, and the
  engine-version lookup all moved off it), and **PostHog telemetry now flushes
  off the main thread**.

## Changed
- **Live status streams by default.** With Mole 1.44+, Burrow streams
  `mo status --watch` (newline-delimited JSON) instead of polling `mo status
  --json` — lower latency and less subprocess churn. It falls back to polling
  on older `mo` or if the stream drops, so the dashboard never stalls.

## Added
- **Update with Homebrew** — for cask installs, the update prompt now has a
  one-click button that runs `brew upgrade --cask burrow` and relaunches,
  instead of just printing the command.

## Windows preview
- Closed out the port review: **MCP tool parity with macOS**
  (`burrow_list_apps`, `burrow_purge`, `burrow_installer` — all preview-only
  over MCP), stdio MCP that survives the HTTP toggle, **brand assets / palette /
  fonts / app icon aligned to the Mac**, honest docs, and real MCP +
  deletion-guard test coverage. (Earlier review rounds added Recycle-Bin
  routing, a drive-root guard, and SHA-256 verification of the bundled engine
  binary.) Still an unsigned, build-from-source preview.
