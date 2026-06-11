# Burrow feature roadmap — 2026-06-10

- **Source:** the 2026-06-10 UX review plus a brainstorm of features that build on Burrow's
  unique assets.
- **Thesis:** Burrow's strongest lane is **the system's memory + the agent's hands** — the
  30/90-day SQLite history and the MCP/HTTP agent surface are assets typical Mac utilities
  don't have. Most plans below build on one of three things: the history DB, the agent
  surface, or the developer audience.
- **Prereq caveat:** the same-day audit (`plans/code-audit-2026-06-10.md`) found the query
  server defaults on and readable by any website, plus telemetry-claim drift. Fix those before
  expanding the agent surface (#5–#8) — several plans below widen exactly that attack surface.
- **Effort scale:** S = a day or two, M = roughly a week, L = multi-week.

**Recommended build order (first three):** #1 Spike forensics, #12 Notifications + new-login-item
alerts, #5+#6 Agent audit page + event stream. Cheap wins to slot anywhere: #7 Prometheus
endpoint, #10 port inspector, #3 disk forecast.

---

## A. Built on the history DB

Most system monitors keep seconds of history; Burrow keeps 30–90 days of `mo status`
snapshots in SQLite (`DB.swift`, `SnapshotStore.swift`, sampled by `Sampler.swift`, dense 1s
net/disk ring in `IOMonitor.swift`). These four features turn that retention into answers
nobody else can give.

### 1. Spike forensics — "what caused that spike?"

**What:** Drag-select (or click) a range on any History chart and get the top processes for
that exact window — peak/avg CPU, memory, with app icons.

**Why:** iStat-class tools show you the spike; nothing on the market explains it. The data is
already on disk, so this is pure UI leverage. Most demoable feature in the list.

**How:**
- `HistoryView.swift`: add a `chartOverlay` drag gesture using `ChartProxy` to map x-positions
  to timestamps; render a selection scrim while dragging.
- On selection, query snapshots in `[t0, t1]` and aggregate per-process stats — the logic
  already exists in the MCP `burrow_process_usage` tool (`MCP.swift`); extract it into a shared
  helper so the GUI and MCP use one implementation.
- Present a panel (reuse the History top-processes table component) titled with the window,
  ranked by peak CPU, toggleable to RAM — same toggle pattern the table already has.
- Empty-window handling: if the range falls in a sampling gap, say so (the gap markers already
  know where gaps are).

**Effort:** M. **Risks:** none destructive; main work is Swift Charts gesture plumbing.

### 2. Anomaly / regression detection

**What:** Baseline per-process CPU/memory/energy and battery drain rate from history; flag
deviations on Home and via notifications (#12): "WindowServer baseline doubled since the macOS
update," "battery drains 23% faster than two weeks ago."

**Why:** Answers the question users actually have ("why is my Mac suddenly hot/slow/dying"),
and feeds the Explain lens with real findings instead of one snapshot.

**How:**
- Extend `Maintenance.swift`'s hourly tick with an analysis pass: compute trailing 24h vs
  prior 14d stats per process name (median + IQR; flag sustained > p95 baseline), and
  per-discharge-session battery drain slope.
- Store findings as DB rows under a new prefix (e.g. `burrow.findings`) so Home, notifications,
  the Explain context (`Explain.swift` → `ExplainContext.build`), and a future MCP tool all
  read the same record.
- Home: a small "Changes" card listing active findings with sparkline evidence.
- Tuning matters more than code: start with 3 conservative rules (process CPU baseline,
  battery drain rate, memory-pressure frequency) and expand only when false-positive rate is
  acceptable on real machines.

**Effort:** L (the stats are easy; the credibility tuning is the work). **Depends on:** #12 for
delivery, but can ship Home-card-only first.

### 3. Disk-full forecasting + growth attribution

**What:** "At this rate, your disk is full in ~3 weeks" from the free-space history, plus
"Downloads grew 11 GB this month" attribution.

**How:**
- Forecast (S): linear regression over `disk.free` from snapshots (robust variant: fit on the
  last 30d, ignore single-sample cliffs from temp files). Annotate the Home disk tile and the
  History disk chart with the projection; suppress when slope ≈ 0 or history < 7d.
- Attribution (adds M): schedule a weekly `mo analyze --json ~` top-level scan (reuse
  `DiskScanner.swift`), persist the per-folder sizes as a DB row, diff against the prior scan,
  surface the top movers in the weekly report (#4) and on the Analyze landing state.

**Effort:** S forecast / M with attribution. **Risk:** forecast confidence — always show the
basis ("based on 30 days"), never a bare date.

### 4. Weekly system report

**What:** A digest composed from the DB + `mo history`: trend deltas, space reclaimed, top
energy consumers, new login items (#12 watcher), battery health delta, disk forecast (#3).

**How:**
- A pure composer (`ReportBuilder`) over existing queries — no new collection.
- Render as a Home card (new "Report" state on the Home segmented control) with a relative
  date; optional notification when a new report is ready (#12).
- Second iteration: `burrow_report` MCP tool returning the same content as markdown — this is
  the artifact agents will want, and it costs almost nothing once the composer exists.

**Effort:** M. **Depends on:** none hard; #3/#12 enrich it.

---

## B. Built on the agent surface

Per the commercialization direction, agent-native is the moat. These make agents *accountable*
(#5), *reactive* (#6), and make Burrow legible to dev tooling (#7, #8).
**All four are gated on fixing the audit's query-server findings first** (default-on, no auth,
website-readable).

### 5. Agent action audit page

**What:** A GUI pane showing what agents did via MCP and when: tool, arguments, dry-run vs
real, outcome, files touched.

**Why:** "Let agents act" only gets adopted if humans can see what happened. This is the trust
feature that makes people flip `mcpActionsEnabled` on — and it's the visible half of the
open-core story.

**How:**
- The MCP server runs as a separate process (`MCP.runStdioLoop()` in `MCP.swift`) with its own
  SQLite handle; DB is WAL, so have it **write** audit rows (new prefix `burrow.agent_audit`)
  at dispatch time: tool name, args (redact nothing — they're local), dry-run flag, duration,
  result summary.
- GUI: new segment on Home's Activity view (or a sub-tab): rows styled like the existing
  cleanup-session cards (`ActivityView.swift`), badged "agent" with the client name from the
  MCP `initialize` handshake.
- Cross-link: rows that deleted files link to the same detail `burrow_deleted_files` exposes.

**Effort:** S–M (logging S; UI M-ish). **Risk:** writes from two processes — WAL handles it,
but route MCP writes through a small serialized writer like `DB.writeQueue` does in-app.

### 6. Event/alert stream for agents (SSE on the query server)

**What:** `GET /events` on `QueryServer.swift` streaming server-sent events: threshold alerts
("memory pressure critical", "disk under 10 GB"), new-LaunchAgent detections (#12), operation
lifecycle (clean started/finished). Agents react instead of polling.

**How:**
- The query server is a minimal hand-rolled HTTP/1.1 on Network.framework — SSE fits it well
  (one long-lived response, `text/event-stream`, periodic keep-alive comments).
- Source events from a new in-process `AlertEngine` evaluated on each `Sampler` tick (shared
  with notifications, #12) plus `OperationCenter` phase changes.
- **Security first:** per the audit, this must land *after* the server defaults to off and
  gains at least a bearer token + strict `Origin`/`Host` checks; an event stream is far more
  interesting to a malicious webpage than a snapshot.

**Effort:** M (engine + endpoint), assuming #12's engine is shared. **Depends on:** audit
fixes; ideally #12.

### 7. Prometheus text format on `/metrics`

**What:** `GET /metrics?format=prometheus` emitting the latest snapshot as Prometheus
exposition text (`burrow_cpu_usage_percent`, `burrow_mem_pressure`, `burrow_disk_free_bytes`,
per-process top-N as labeled series…).

**Why:** Every dev with a Grafana habit can chart their Mac in ten minutes. Cheap, viral,
and squarely the target audience.

**How:** a single formatter over the already-decoded `MoleStatus` in `QueryServer.swift`;
no state, no new collection. Document the scrape config in README.

**Effort:** S. **Depends on:** same security gating as #6 (read-only, so token + off-by-default
suffices).

### 8. Snapshot diff (`burrow_diff`)

**What:** "What changed since \<time\>": new/removed apps, new login items/LaunchAgents,
disk delta, new listening ports, top-process shifts. MCP tool first, GUI card later.

**Why:** the agent use case is concrete — "did my install succeed and what did it leave
behind" — and humans get a "what changed this week" view for free in the report (#4).

**How:**
- Apps: persist a periodic inventory (weekly `mo uninstall --list` → DB row) so there's a
  baseline to diff; currently the list is only fetched on demand (`SoftwareView.swift`).
- Login items / LaunchAgents: reuse #12's watcher inventory rows.
- Ports: snapshot from #10's lister.
- Disk/process: straight from existing snapshots.
- Ship as `burrow_diff(since:)` in `MCP.swift`; the GUI card is a later consumer.

**Effort:** M. **Depends on:** inventory rows (small additions to `Maintenance.swift`), #10,
#12 for full coverage — but a useful v1 ships with apps + disk + processes only.

---

## C. Developer-focused utilities

### 9. Dev hygiene page

**What:** A dedicated pane that breaks out what generic cleaners lump together: Xcode
(DerivedData, old simulators via `simctl`, device support), container disk (Docker.raw /
Podman machine), package caches (npm/pnpm/yarn, cargo, pip, brew cache), old toolchains —
each with size and a per-item, confirm-gated action.

**How (staged):**
- **Stage 1 (read-only, S–M):** known-path size scan (reuse `DiskScanner`/`mo analyze` per
  root), grouped by ecosystem with icons; "Reveal in Finder" only. Hide ecosystems not
  installed.
- **Stage 2 (M–L):** actions per item using the ecosystem's own tool where one exists
  (`xcrun simctl delete unavailable`, `docker system prune` with explicit flags, `brew
  cleanup`), Trash for plain directories. Same confirm-sheet pattern as uninstall
  (`SoftwareView.swift`); stream output through `TaskReport` like Clean does.
- Respect the purge overlap: link to Purge for per-project build artifacts rather than
  duplicating it.

**Effort:** L total, but stage 1 alone is shippable and useful.

### 10. Port / listening-process inspector

**What:** A table of listening TCP/UDP ports: process (icon + name), PID, port, address, with
a confirm-gated kill (SIGTERM, escalate option to SIGKILL). The GUI version of
`lsof -i :3000` + `kill`.

**How:**
- Enumerate natively via `proc_listpids` + `proc_pidfdinfo` socket info (no shelling out, no
  elevation for user-owned processes), refresh on a 5s timer while visible.
- Live as a third segment on Status or a card on Home; row affordances match the process
  table (icons via the existing NSWorkspace cache).
- Feed the same data to #8 (diff) and an MCP `burrow_ports` read tool.

**Effort:** S–M. **Risk:** killing system daemons — filter root-owned by default, show them
read-only.

### 11. Git repo sweep (purge safety upgrade)

**What:** Before purging project folders, badge candidates whose repos have uncommitted
changes or unpushed branches — turning Purge from "scary" into "safer than doing it by hand."

**How:**
- For each candidate row in the purge checklist (`MoInteractive.swift` checklist UI), walk up
  to the containing `.git` and run `git -C <repo> status --porcelain -b` (fast, local; bound
  with a short timeout and a concurrency cap).
- Render a warning badge on dirty/unpushed rows; never auto-untick (the "leave items for
  review" philosophy Burrow already follows).
- Bonus: a standalone "stale clones" list (repos untouched > 6 months, with size) on the dev
  hygiene page (#9).

**Effort:** M. **Risk:** perf on directories with hundreds of repos — cap and lazy-badge.

---

## D. Monitoring & trust

### 12. Notifications + threshold alerts (incl. new-login-item watcher)

**What:** UserNotifications integration plus a rule engine: CPU pegged > N minutes, memory
pressure critical, disk below threshold, battery health drop — and the differentiator:
**"a new LaunchAgent/login item appeared"** (persistence detection; doubles as a lightweight
security feature most utilities lack).

**Why first-class:** Burrow currently has zero notification capability; one framework unlocks
#2, #4, #6, and this. The launchd watcher is the single most differentiating alert.

**How:**
- `AlertEngine` (new file): rules evaluated on each `Sampler` tick; hysteresis + cooldowns so
  alerts fire once per episode, not per sample. Persist alert history to the DB (feeds #6 SSE
  and the report #4).
- Watcher: periodic scan (piggyback `Maintenance.swift` hourly + on-wake) of
  `~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons` and
  `SMAppService`/login-items enumeration; persist inventory rows; diff → "new item" alert
  with reveal-in-Finder action.
- Settings: a Notifications section (master toggle + per-rule toggles + thresholds), matching
  the existing settings table style; all off-by-default except disk-low and new-login-item.
- Notification actions: "Open Burrow", "Reveal", "Mute this app/item" (mute list in Store).

**Effort:** M (+S for the watcher). **Risk:** alert fatigue — conservative defaults, cooldowns,
and per-rule mute are part of the spec, not polish.

### 13. "Restore last cleanup"

**What:** One-click undo for Trash-based operations (uninstall / purge / installer): show the
manifest of what moved, restore selected items.

**How:**
- Manifest source: `mo history --json` already records trashed paths per session
  (`MoleHistory.swift`; same data as `burrow_deleted_files`).
- Restore: AppleScript `tell application "Finder" to put back` per item where Finder still
  knows the origin; fallback — locate by name in `~/.Trash` and move to the recorded original
  path, skipping on collision with a clear per-item result.
- UI: "Restore…" affordance on Activity session cards for Trash-based sessions; per-item
  checklist (reuse the MoInteractive checklist component) → confirm → `TaskReport`-style
  results.
- **Honest scoping:** Clean removes caches permanently (by design, so freed bytes are real) —
  the UI must say restore applies only to Trash-based sessions, and items emptied from the
  Trash are gone.

**Effort:** M. **Risk:** Trash-name collisions and stale manifests — per-item verification
before promising anything.

### 14. Disk health (SMART) + backup awareness

**What:** A SMART/health row on the disk tile (wear %, temperature, hours) and a backup check:
warn before large deletions if the last Time Machine backup is stale; surface purgeable APFS
local snapshots (a routine answer to "where did my space go").

**How:**
- SMART: IOKit NVMe SMART user client on Apple Silicon internal SSDs (what smartmontools
  uses); if unreadable, hide the row — never guess. External drives: best-effort.
- Backup: `tmutil latestbackup` + `tmutil listlocalsnapshots /` (fast, unprivileged); a
  pre-flight line in the Clean/Purge confirm sheets ("Last backup: 26 days ago") and a
  purgeable-space note on the Analyze sidebar.
- Snapshot purging itself stays manual/linked-to-System-Settings in v1 (deleting local
  snapshots is a sharp tool).

**Effort:** M (SMART is the unpredictable half). **Risk:** SMART entitlement/IOKit quirks
across hardware — feature-flag the tile.

---

## Cross-cutting requirements for everything above

1. **Privacy framing:** every feature here is local-only. Keep it that way and say so in the
   docs as each ships — the audit showed the cost of claims drifting from code.
2. **Accessibility from day one:** Burrow has ~one `accessibilityLabel` today. Every new view
   above ships with labels/values and Reduce Motion respected — retrofitting later is how
   gaps compound.
3. **i18n:** new strings go through `NSLocalizedString` with zh-Hans filled at PR time, not
   batched later.
4. **Shared logic with MCP:** where a feature has both a GUI and an agent face (#1/#5/#8/#10),
   extract the query into one helper consumed by both — `MCP.swift` duplicating view logic is
   how drift starts.

---

## Appendix: Core-experience gaps (from the 2026-06-10 UX review)

Not the focus of this roadmap, but ranked here so one file holds the whole picture. These are
GUI-layer gaps — `mo` CLI engine improvements flow into Burrow automatically.

1. **Accessibility** (VoiceOver / keyboard / Reduce Motion) — covered by cross-cutting req #2.
2. **App updates beyond Homebrew** — Sparkle + Mac App Store + Electron detection, source
   filter, badge. Biggest functional gap in Software (`UpdatesView.swift` is brew-only).
3. **Startup item management** — review/disable/reveal Login Items, Launch Agents, Daemons.
   Note: #12's watcher builds the read layer this needs; the management UI is the increment.
4. **Clean per-item review + persistent exclusions** — Clean is the only destructive tool
   without a checklist; Purge/Installer's `MoInteractive` UI is the pattern to reuse.
5. **Doctor diagnostics** — permissions/pressure/disk/log report from the Help menu.
6. **Menu bar live-metrics text + right-click menu** — small lift, large perceived
   completeness.
7. **Fan control, camera/mic privacy check, Keep Screen On, Clean Screen** — standalone
   mini-features; fan control needs a privileged helper (most expensive of the four).
8. **Self-update + signed/notarized DMG, Launch at Login, native fullscreen** — distribution
   maturity items, prerequisites for any paid tier.
