# Burrow UI/UX design plans — 2026-06-10

- **Method:** specs distilled from a screenshot-driven design review with Henry (2026-06-10),
  worked through in batches; each batch became a section with a concrete implementation plan.
  Companion docs: `plans/feature-roadmap-2026-06-10.md` (features),
  `plans/code-audit-2026-06-10.md` (audit).
- **Originality rule:** these specs define **layout, hierarchy, interaction, and behavior**.
  All artwork, mascots, naming, and written copy are original to Burrow — Burrow's existing
  visual tokens (dark glass cards, tool accent colors, `Brand.swift` typography) carry the
  design.
- **Cross-cutting (applies to every item):** all new strings through `NSLocalizedString` with
  zh-Hans at PR time; accessibility labels/values + Reduce Motion respected from day one;
  honest verbs (Clean is permanent — say so).

---

## Batch 1 — Onboarding, access banner, Clean review

### 1.1 First-run onboarding — permissions slide

**Design spec:** Full-window slide. Progress dashes top-center (2 steps, current one
brighter/wider). Centered hero mark. Serif display headline "Grant access to get started."
One permission row card: dot status indicator · bold title "Full Disk Access" · one-line
benefit copy · two buttons right-aligned in the card: secondary "Open Settings", secondary
"Check". White pill "Continue" pinned bottom-right. Window is plain (no nav), traffic lights
only.

**Plan:**
- New `OnboardingView.swift` + window controller, shown from `AppDelegate` on first launch
  when `Store.onboardingCompleted == false` (new key `onboarding_completed`), after the
  `mo`-missing gate (`MoleInstallView` stays first if `mo` absent — it is effectively slide 0).
- Slide 1 anatomy:
  - Progress dashes: 2 capsules top-center; active = wider + full opacity. Animate width on
    slide change (respect Reduce Motion).
  - Hero: Burrow mark in a circular chip on a ring motif (reuse the radial-gradient circle
    glyph style from Analyze's sidebar).
  - Headline set in Burrow's display face; copy: **"Grant access to get started."**
  - Permission row card (reusable `PermissionRow` component — Notifications and others join it
    later per the roadmap): status dot (gray → green when granted), title "Full Disk Access",
    benefit line "Unlocks the caches and leftovers Burrow needs to reach." Buttons:
    "Open Settings" → existing deep link in `Privacy.swift`; "Check" → re-probe
    `Privacy.fullDiskAccess` and flip the dot live. If macOS requires a relaunch to rebind the
    grant, offer the existing `Privacy.relaunch()` path inline ("Granted? Relaunch to apply").
  - "Continue" white pill bottom-right. Skippable — FDA is optional (safe scan works without),
    matching Burrow's existing gates.
- The existing in-flow FDA gates (CleanView/AnalyzeView) stay as fallback for users who skip.
- Files: new `OnboardingView.swift`; `AppDelegate.swift` (launch sequencing); `Store.swift`
  (key); `Privacy.swift` (no changes expected — probes and deep link exist).

**Effort:** M for both slides together (incl. 1.2). **Risk:** none destructive; FDA "Check"
can read stale TCC state — keep the relaunch affordance.

### 1.2 Onboarding slide 2 — free & open source + feature tour

**Design spec:** Same slide skeleton: serif headline + subline, one wide card with a
big-numeral left slot and a checkmark feature list on the right, a card footer row, "Back"
bottom-left, primary pill bottom-right.

**Plan:**
- Headline: **"Burrow is free."** Subline: "Open source, local-first. No license, no trial,
  no upsell."
- Card: left slot shows **"$0 / forever"** in a big-numeral treatment — the visual punchline.
  Right slot, checkmark list (green check chips):
  - "Every tool unlocked — Clean, Purge, Installers, Software, Optimize, Analyze"
  - "Watches your Mac over weeks, not seconds — 30–90 day history"
  - "Agent-ready — MCP tools for Claude, Cursor, Codex (off until you opt in)"
  - "Open source — read every line" → subtle GitHub link
- Card footer row: **telemetry disclosure** — one line "Anonymous usage & crash reports help
  development — toggle anytime in Settings" with the actual toggle inline. Surfacing this at
  first run is the single best fix for the audit's truthfulness cluster (C1) and turns a
  liability into a trust signal.
- "Back" bottom-left; pill bottom-right is **"Start using Burrow"** → sets
  `onboarding_completed`, opens main window.
- Files: `OnboardingView.swift` (same component, second page), `Telemetry.swift` (read/write
  enabled state), copy reviewed against TELEMETRY.md wording so docs and UI can't drift.

**Effort:** included in 1.1's M.

### 1.3 Non-blocking "Full Disk Access is off" banner

**Design spec:** Bottom-anchored full-width banner over the page: shield-lock icon in a
rounded chip · bold "Full Disk Access is off" · muted subline "Without it, Burrow can't reach
most system caches." · right-aligned "Open Settings" button + "×" dismiss. The page behind
stays fully usable — the banner informs, it doesn't gate.

**Plan:**
- New `AccessBanner` component mounted once in `RootView.swift` as a bottom overlay across
  all panes (not per-view), shown when `!Privacy.fullDiskAccess && !Store.fullDiskAccessNoticeDismissed`.
- Anatomy: icon chip, title "Full Disk Access is off", subline "Without it, Burrow can't
  reach most system caches.", "Open Settings" (existing deep link), × sets the existing
  `fda_notice_dismissed` key. Slide-up entrance (Reduce Motion: fade).
- Re-check FDA on app activation (`NSApplication.didBecomeActiveNotification`) so the banner
  auto-dismisses the moment access is granted — nicer than making the user click "Check".
- **Demotion, not addition:** today Burrow front-loads FDA as blocking gate cards inside
  Clean/Analyze/Installer flows. Those gates shrink to only the moments that genuinely need
  them (pre-elevated-scan choice). The ambient state moves to this banner. Net effect: first
  open of Clean shows the hero + Scan button immediately.
- Files: new `Components/AccessBanner.swift`; `RootView.swift` (mount); `CleanView.swift`,
  `AnalyzeView.swift`, `InstallerView.swift` (gate demotion); `Privacy.swift` (re-check on
  activate).

**Effort:** S (banner) + S (gate demotion). **Risk:** don't fully remove the pre-scan gate
where "Scan anyway (elevated)" is offered — that choice still needs a decision point.

### 1.4 Clean review & confirm screen

**Design spec:** After a scan, a full-page review titled **"Ready to clean"** with:
- **Subtitle intelligence line:** `Close BetterDisplay, Helium, … to clean another 3.9 GB · 6 items`
  — names the running apps whose caches are locked and quantifies the upside of closing them.
- **Top-right:** select-all (✓ circle) and deselect-all (× circle) icon buttons.
- **Category cards** (one per group — App Caches, Misc, Developer Tools, AI Tools,
  Communication): tri-state checkbox (✓ all / – mixed / empty none) · category icon · bold
  title · `50/50 selected` in mono · one-line description with honest consequence ("App
  temporary files. Regenerated next launch." / "First build will be slower.") · right side
  `6.6 GB / 6.99 GB` (selected/total) in mono accent blue · chevron to expand.
- **Expanded item rows:** accent checkbox · item name · mono dimmed path (`~/.cache/uv`) ·
  status badge — blue **"Safe"**, amber **"App open"**, gray **"System busy"** · size · a
  reveal-in-Finder icon button per row. Locked rows ("App open"/"System busy") are unchecked
  and disabled.
- **Footer-left:** `61/64 selected`. **Footer-right:** floating white pill
  **"Permanently clean · 7.15 GB"** — verb is honest, total is live.

**Engine findings (verified 2026-06-10 on this machine):**
- `mo clean` has **no** per-item selection flags (only `--dry-run`, `--external`,
  `--whitelist`, `--debug`).
- But `mo clean --dry-run` writes **`~/.config/mole/clean-list.txt`** — a parseable preview:
  `=== Category ===` section headers and one path per line with `# size, N items` comments.
- The **whitelist is a plain glob file** (`~/.config/mole/whitelist`, one pattern per line)
  and `mo clean` skips anything matching it.

So selective cleaning = **whitelist session**:
1. Scan: run `mo clean --dry-run` (existing flow), parse `clean-list.txt` into
   category → items(path, size, count).
2. Review: user unticks items/categories in the new UI.
3. Run: back up `whitelist`, append a fenced block
   (`# BEGIN burrow-session` … unticked paths … `# END burrow-session`), run `mo clean`
   elevated as today, then restore the whitelist in a `defer` + a startup sweep that removes
   any stale fenced block (crash safety).
This keeps the engine's safety rules authoritative — Burrow never deletes cache paths itself.

**Plan:**
- New `CleanReviewView.swift` replacing the current banner-only dry-run result in
  `CleanView.swift`: flow becomes hero → "Scan" → review screen → confirm pill → existing
  elevated run + `TaskReport` results.
- Parser: new `CleanList.swift` reading `~/.config/mole/clean-list.txt` (also exposed to the
  MCP `burrow_clean` dry-run response later — shared helper per roadmap rule #4).
- Locked-item detection (the subtitle + badges): map cache paths → bundle ids → running apps
  via `NSRunningApplication`; rows for running apps get **"App open"**, unchecked + disabled;
  the header line sums their sizes: "Close X, Y, Z to clean another N GB · M items".
  System-locked paths (in use by daemons) get **"System busy"** on failure feedback from the
  previous run's report; everything else defaults to **"Safe"** (the scan already excluded
  unsafe paths — say so in a tooltip).
- Selection model: per-item set + tri-state category derivation; select-all/none top-right;
  footer count `n/m selected`; pill total recomputed live from ticked sizes; pill label
  **"Permanently clean · N GB"** (keep the honest verb — cache removal is permanent, matching
  our existing copy).
- Per-row reveal-in-Finder via `NSWorkspace.activateFileViewerSelecting` (pattern exists in
  Analyze's context menu).
- Persistent exclusions (roadmap appendix #4) ride along almost free: an "Always skip this"
  row context-menu action appends the path to the real whitelist permanently (outside the
  fenced session block).
- Escape/× exits review back to hero (aligns with the ESC-consistency rule).
- Accessibility: category checkbox announces "App Caches, 50 of 50 selected, 6.6 of 6.99
  gigabytes"; rows announce name, badge, size; pill announces live total.
- Files: new `CleanReviewView.swift`, `CleanList.swift`; `CleanView.swift` (flow);
  `MoleCLI.swift` (whitelist session helpers); `Store.swift` (none expected);
  zh-Hans strings.

**Effort:** L overall — UI M, engine wiring (parser + whitelist session + locked detection) M.
**Risks:**
- *TOCTOU gap:* caches appearing between dry-run and real run get cleaned without review
  (whitelist excludes, it doesn't include). Window is seconds; mitigate by re-running the
  dry-run diff check before executing and re-prompting if the total moved materially (> a few
  hundred MB).
- *Whitelist restore:* fenced block + `defer` + startup sweep, never blind-overwrite the
  user's own whitelist entries.
- *clean-list.txt format drift:* it's an informal file from the CLI — pin parsing to the
  section/`#` comment shapes, fail soft to today's aggregate banner if parsing breaks, and
  add a fixture test with the current file format.

---

## Batch 2 — Clean result hero, Software tab (uninstall/updates/startup), Optimize ticker

### 2.1 Clean scan result hero with animated counter

**Design spec:** After (or during) a scan, the Clean tab stays on the minimal hero — the tool
glyph, then a huge bold **"11.83 GB found"** beneath it, an info chip **"🛡 Limited scan
active · App Support and container caches are skipped ›"** (shown when FDA is off, chevron
leads to the explanation/grant), and a white **"Review results"** pill. The number **counts
up / slides as the scan streams in**. This result screen is deliberately distinct from the
review screen (1.4): hero = the headline number; review = the decisions.

**Plan:**
- `CleanView.swift` gets a third hero state: idle → **scanning/result** → review (1.4) → run.
  Scanning and result are the same layout — the number mounts at 0 when the scan starts and
  ticks up live, so the animation is the scan progress itself.
- Live total: the dry-run already streams line-by-line through `CommandRunner`/`TaskReport`
  parsing — accumulate per-item sizes as lines arrive and publish a running total.
- Number rendering: monospaced digits + SwiftUI `.contentTransition(.numericText())` inside
  `withAnimation` per update tick (coalesce to ~4 updates/sec like TaskReport does); format
  flips KB→MB→GB as it grows. Reduce Motion: no rolling digits, value just updates.
- "Limited scan" chip: shown when `!Privacy.fullDiskAccess`; copy: "Limited scan active · App
  Support and container caches are skipped". Chevron opens the FDA explainer with Open
  Settings / "Scan anyway (elevated)" — this is where Batch 1's demoted gate (1.3) now lives.
- "Review results" pill replaces today's aggregate banner → pushes `CleanReviewView` (1.4).
- Files: `CleanView.swift`, small additions to the 1.4 parser for incremental totals.

**Effort:** S–M (assuming 1.4's parser exists). **Risk:** none — display-only state.

### 2.2 Uninstall — expandable leftover review

**Design spec:** Apps tab, Uninstall segment. Top bar: segmented **Uninstall | Updates |
Startup**, right side **sort chips with direction carets — Name ⇅ · Size ⇅ · Last Used ⇅**
(active chip highlighted), refresh and search icons. App rows: icon · bold name · version
under it · right side **"3 files · 13.3 MB"** summary + a circular radio-check. **Expanding a
row reveals the leftover breakdown** inside the card:
- Header: app name + mono bundle path, right "2/3 selected · 13.3 MB" + "Select all".
- **"Auto selected"** group (count · size, group checkbox): rows of kind label
  (**Application / App Support / Preferences**) · mono path · size · accent checkbox.
- **"Needs review"** group: "Not selected by default. Review these before removing." —
  e.g. Temporary Cache rows, unchecked by default.
- Bottom bar: selected-app icon + **"ActivityWatch · 1 app · 13.3 MB"** summary left,
  red **"Deselect all"**, white pill **"Remove 1"** bottom-right.

**Plan:**
- **Engine:** `mo uninstall --dry-run <name>` exists ("Preview app uninstall") — run it on row
  expansion, parse the enumerated paths, classify into kinds by path shape (`.app` bundle →
  Application; `~/Library/Application Support/...` → App Support; `~/Library/Preferences/...`
  → Preferences; `~/Library/Caches`, `/private/var/folders/...` → Temporary Cache; launch
  items, containers as they appear). Cache per app for the session.
- **Auto vs Needs review:** Application/App Support/Preferences/launch items → auto-selected;
  temporary caches, group containers, and anything ambiguous → "Needs review", unchecked.
- **Selective removal:** `mo uninstall` removes its full set (Trash-based, y/N piped — current
  `SoftwareView.swift` flow). Two-path execution:
  - All items ticked (the common case): keep today's `mo uninstall <name>` — history stays in
    the engine's log.
  - Subset ticked: Burrow trashes exactly the reviewed, user-ticked paths via
    `NSWorkspace.recycle` — semantically identical Trash behavior, and every path came from
    the engine's own dry-run enumeration, so its safety scan still decided the candidate
    set. Trade-off (documented in-app): subset removals won't appear in `mo history`, so
    record them in Burrow's own Activity log (`OperationCenter` + a DB row) instead.
- **List chrome:** sort chips Name/Size/Last Used with direction toggle and active
  highlight (replaces the current picker; last-used data is already lazy-loaded); refresh
  icon; search collapses to an icon. Row right side gets the "N files · size" summary once
  the dry-run has run (before that, app size only). Circular radio-check replaces the current
  checkbox look.
- **Bottom bar:** selection summary with the app icon (stack icons when several),
  "N apps · total", "Deselect all" in the warning color, "Remove N" white pill → confirm
  sheet (existing) → run.
- Files: `SoftwareView.swift` (major rework), new `UninstallPreview.swift` (dry-run parser +
  classifier), `MoleCLI.swift` (dry-run helper), Activity logging.

**Effort:** L — the largest item in this batch. **Risks:** dry-run output format drift (pin
parser to current output, fixture test, fail soft to today's flow); native-trash path must
refuse anything outside the dry-run enumeration (assert, don't trust).

### 2.3 Updates — beyond Homebrew, with source badges

**Design spec:** Updates segment. Sections ("Updates available" above, "Up to date" below).
Rows: icon · name · **source badge** (Sparkle / App Store / Electron / Homebrew) · meta line
in mono: `version · size · active 7 months ago` with the recency phrase amber-highlighted
when stale ("active now" / "opened 13 hours ago" otherwise). Same sort chips as Uninstall.

**Plan (phased):**
- **Detection (v1):** for each app from the existing inventory:
  - **Sparkle:** `SUFeedURL` in Info.plist → fetch appcast, compare `CFBundleShortVersionString`.
  - **App Store:** `_MASReceipt` present → iTunes Search/Lookup API by bundle id.
  - **Electron:** Electron framework present → badge; update via its own updater or GitHub
    releases fallback (match by bundle metadata / homepage when unambiguous).
  - **Homebrew:** existing `brew outdated` path (`UpdatesView.swift`), now rendered in the
    same unified list with a Homebrew badge instead of a separate page.
- **v1 actions:** badge + "Update" deep-link — launch the app's own updater for Sparkle apps,
  open the MAS product page, `brew upgrade` inline (existing). **v2:** in-app Sparkle install
  with progress (meaningfully harder and riskier — separate plan when we get there).
- **UI:** unified list, source badges as small rounded chips, mono meta line with
  amber-stale recency (reuse the last-used loader from Uninstall), section split
  "Updates available" / "Up to date", per-source filter, sort chips shared with 2.2.
- **Egress note (must-do):** update checks contact Apple/vendor/appcast servers. Checks are
  manual (refresh button) or opt-in scheduled — never silent-automatic — and the network
  story gets a line in SECURITY.md/TELEMETRY.md, consistent with the audit's truthfulness
  findings.
- Files: `UpdatesView.swift` (rework), new `UpdateSources.swift` (per-source checkers).

**Effort:** M–L for v1 (Sparkle + MAS + badges), Electron/GitHub fallback +S.

### 2.4 Startup — login items, agents, daemons (new segment)

**Design spec:** Startup segment. Top: filter dropdown ("All ∨"), refresh, search. An amber
**one-time authorization banner** explaining that an admin password is needed once to list
every background task, that this is a system permission separate from Full Disk Access, and
that it only happens the first time — with an **"Authorize"** action right-aligned. Section
header **"Login items"** with count. Rows: app icon · bold name · classification subline
"Login item · Bundled inside an app; review only" / "Helper · …" · red "Error" state inline
where broken · two trailing icon buttons: reveal-in-Finder + a lock (non-modifiable
indicator).

**Plan:**
- Third segment in `SoftwareView.swift`'s segmented control: **Uninstall | Updates | Startup**.
- **Enumeration (no admin):** user LaunchAgents (`~/Library/LaunchAgents`), system-visible
  `/Library/LaunchAgents` + `/Library/LaunchDaemons` (world-readable), SMAppService/login
  items via `SMAppService` queries + `launchctl print gui/$UID` parsing. This covers the
  large majority — ship it first.
- **One-time authorize banner:** for the remainder (root-scope details, other users'
  agents), show the amber banner with the honest copy above → single elevated enumeration via
  the existing osascript path; persist the result and don't re-ask.
- **Classification sublines:** "Login item / Launch agent / Launch daemon / Helper" ·
  "Bundled inside an app; review only" vs directly controllable. Controllable items get a
  disable toggle (`launchctl bootout`/`disable`, elevated where required); bundled/sealed
  items are review-only with reveal — a split that matches what macOS actually permits.
- Error states: plist parse failures / dangling executables → red "Error" inline (this is
  also the "broken login item" cleanup hook later).
- Icon resolution via the existing NSWorkspace cache; filter dropdown by kind; count per
  section header.
- **Shared layer:** this enumeration is the same inventory the roadmap's watcher (#12) and
  `burrow_diff` (#8) consume — build it as `StartupInventory.swift`, UI and watcher both read
  it.
- Files: `SoftwareView.swift` (segment), new `StartupInventory.swift` + `StartupView.swift`.

**Effort:** M for read-only list + reveal; +S for disable toggles; elevated full-list +S.

### 2.5 Optimize — live task ticker

**Design spec:** During a run: hero stays, a headline (e.g. "Refreshing…"), a current-task
line with a colored dot — **"● Rebuild Launch Services database · 8/18"** — and beneath it a
rounded panel of completed tasks, each a mono line with a ✓. New completions append at the
bottom and the list **slides up** so the panel stays a fixed height, but it remains
**scrollable** to review earlier lines.

**Plan:**
- Replace Optimize's run-state body (currently the generic streaming `TaskReportView`) with a
  `TaskTicker` component:
  - Parse the `mo optimize` stream into discrete task completions (the per-task markers
    TaskReport already recognizes); maintain `completed: [String]`, `current: String?`, and
    counts. Total (the "/18") comes from the task count when the engine announces it; if
    unknown, show "· 8" without a denominator rather than guessing.
  - Layout: centered column — hero glyph, headline (per tool accent), current-task line
    (pulsing dot, task name, `n/total` in mono), then a fixed-height rounded panel (~7 rows)
    with a `ScrollView` pinned to bottom; insertions animate with a move+opacity transition
    so existing rows slide up. User can scroll back any time — pin-to-bottom re-engages when
    they return to the end. Reduce Motion: rows appear without sliding; dot doesn't pulse.
  - Completion: ticker resolves into the existing done banner + full `TaskReport` (the
    detailed per-category report stays available — the ticker replaces the *live* view, not
    the receipt).
- **Reuse:** the same `TaskTicker` drops into Clean's real run later (same marker grammar) —
  build it as `Components/TaskTicker.swift`, not inside OptimizeView.
- Files: new `Components/TaskTicker.swift`; `OptimizeView.swift` (swap run state);
  `TaskReport.swift` (expose task-completion events).

**Effort:** M. **Risk:** task-boundary detection from stream markers — fixture-test against a
captured `mo optimize` transcript; fall back to the current raw stream view if parsing breaks.

---

## Batch 3 — Analyze progress, Status, Settings, menu-bar tools & popover

### 3.1 Analyze — live scanning progress line (keep our treemap)

**Design spec:** During a scan: a headline ("Mapping your folders") and a single line with a
colored dot — **"● /Applications/Microsoft Excel…sources/cs.lproj/Add-Ins · 2/6"** — the path
currently being processed (middle-truncated, mono) and a step counter. The progress line
replaces the bare spinner; Burrow's treemap remains the result view and overall layout.

**Plan:**
- Keep `AnalyzeView`'s layout; replace the bare spinner in the treemap region with: small
  progress dot + middle-truncated mono path + `n/total` counter, headline above it.
- **Getting real progress** (no fake progress — two options, investigate in order):
  1. Check whether `mo analyze` emits per-directory progress lines on stderr/TTY when run
     without `--json` (it's an interactive TUI; if it streams, run the JSON scan alongside a
     line-parse of stderr, or add a `--progress` flag to the CLI fork).
  2. Fallback that's guaranteed to work: enumerate the target's immediate children first
     (cheap), then loop `mo analyze --json <child>` per child — Burrow controls the loop, so
     "● ~/Downloads · 3/12" is *true* progress. `DiskScanner.swift` already caches per-path,
     and child results pre-warm drill-down. Cost: slightly slower than one aggregate call on
     shallow trees; benchmark before committing.
- Reduce Motion: dot doesn't pulse; path line still updates.
- Files: `AnalyzeView.swift`, `DiskScanner.swift`.

**Effort:** S (UI) + S–M (progress plumbing, depending on which option lands).

### 3.2 Status dashboard — denser tiles, richer process table

**Design spec:** Tile grid, each tile with a **corner status chip**: HEALTH (glyph, score
"90 Excellent", headline issue "Disk space low · 29.86 GB Free", hardware chips
**M4 Pro / 24 GB / macOS 26.5.1**, "up 23h 55m · since Jun 10"), CPU (chip **62°C**, big %,
bar sparkline, "Load 5.6 / 14 cores · idle"), GPU (chip **57°C**), MEMORY (chip **Pressure
47%**, "17.27 GB · 1.65 GB swap"), BATTERY (chip **90% Health**, "48% · 3:28 left", **two ring
gauges — Mac battery + connected Bluetooth device**, "553 cyc · 31°C"), DISK (chip total GB,
free headline, low-space gradient bar, "464.52 GB used · 94%"), NETWORK ("40 KB/s", dual
sparkline, "↑ 14 KB/s · Wi-Fi"), FAN (chip **Load 0%**, "0 RPM Idle", "macOS manages speed").
Below, the process table: **NAME (49) ⇅ · PID ⇅ · CPU ⇅ · PWR ⇅ · MEM ⇅**, per-row CPU
mini-bar, absolute MB, pin bar, a **"…" menu per row**, and the table scrolls independently.

**Plan:**
- **Tiles** (`StatusView.swift` rework; data nearly all exists in `MoleStatus` + `SMC.swift` +
  `IOMonitor.swift`):
  - Corner chips per tile: CPU temp (have), GPU temp (SMC `Tg` cluster — read, currently
    charted in History only), memory pressure %, disk total, battery health, fan load %.
  - HEALTH tile: add macOS version chip and "since <date>" uptime phrasing; headline issue
    line from the existing health message.
  - BATTERY tile: ring gauges — Mac battery ring + a ring per connected Bluetooth device
    (data already in the Bluetooth strip; the strip folds into the battery tile, as directed).
  - DISK: low-space gradient bar (color shifts as free% drops).
  - FAN tile: **v1 read-only** — RPM, load chip, "macOS manages speed". Fan-mode controls
    ship only with the privileged-helper fan-control work (roadmap appendix #7) — render no
    disabled placebo controls before that.
- **Process table:**
  - New **PWR column**: best-effort per-process energy via `proc_pid_rusage`
    (`ri_energy_billed`); show "—" where unavailable.
  - MEM in absolute MB (resident bytes already parsed); header shows count "NAME (49)"; all
    five columns sortable both directions (PWR joins the existing four).
  - Per-row "…" menu: Pin/Unpin (existing pin), Reveal in Finder, Copy name / PID, Quit
    (SIGTERM, confirm) and Force Kill (SIGKILL, stronger confirm) — own-user processes only;
    root-owned rows get reveal/copy only.
  - Table becomes its own scroll region with a sticky header row, independent of page scroll.
- Files: `StatusView.swift` (major), `LocalMetrics.swift`/`SMC.swift` (GPU temp into the live
  snapshot), new `ProcessActions.swift`.

**Effort:** M–L. **Risk:** per-process energy availability varies by process type — degrade to
"—" silently, never estimate.

### 3.3 Settings — tabbed overlay

**Design spec:** Settings as a centered overlay panel (not a page) with segmented tabs and ×
top-right. Rows are title + muted subline + trailing control — e.g. a Full Disk Access row
whose subline states live status ("Off. Safe scan in use."), Language with an honest subline,
Launch at Login, Hide Dock Icon, Skip Intro Screens; a Maintenance tab with Protected Items
(Manage), a Permanent | Trash cache-removal choice; a Menu Bar tab with a monitor toggle,
a keyboard-shortcut recorder chip (e.g. ^⌥⌘M, with reset + clear), display-mode segmented
control, and shortcut rows for the menu-bar tools.

**Plan:**
- Convert `SettingsView.swift` from a full pane into a centered overlay sheet with tabs:
  **General | Maintenance | Menu Bar | Advanced**.
- **General:** FDA row with live-status subline ("Off. Burrow uses safe scan for now." /
  "On.") + Open Settings + Check (reuses 1.1's `PermissionRow`); Language (existing picker);
  **Launch at Login** (new — `SMAppService.mainApp`); **Hide Dock Icon** (expose the existing
  menu-bar-only behavior as this toggle, keeping the safety inversion: hiding both Dock icon
  and menu-bar icon is prevented as today); **Skip Intro Screens** (bypass hero states, open
  Home directly — also skips onboarding re-entry); About row (version + GitHub link).
- **Maintenance:** **Protected Items → whitelist manager** — a real UI over
  `~/.config/mole/whitelist` (list patterns, add/remove, with the defaults annotated); this is
  the same mechanism 1.4's "Always skip this" writes to, now user-browsable. **Cache Removal:
  Permanent | Trash** — Permanent stays default (the engine's behavior, freed bytes are
  real); Trash mode routes the real run through the 2.2-style native-recycle path for the
  *reviewed, ticked* paths, with the trade-off stated inline ("space frees when Trash
  empties; not in `mo history`"). Existing storage/retention/vacuum/sampling rows move into
  this tab.
- **Menu Bar:** Menu Bar Monitor toggle ("Show system metrics in menu bar" — the text-metrics
  mode from 3.5/appendix #6); **global Keyboard Shortcut recorder** to open/toggle Burrow
  (new; implement a minimal `RegisterEventHotKey` recorder — no third-party deps); **Display:
  Icon | Metrics** (two modes; no mascot/character display mode — if Burrow ever adds one it
  will be original artwork, later); Awake Shortcut + Clean Screen Shortcut + Input Protection
  rows once 3.4's tools exist.
- **Advanced (Burrow-only):** MCP, HTTP query server, Explain/AI, telemetry, Touch ID, engine
  version/update — everything agentic/experimental stays out of the first three tabs so the
  common path stays simple.
- Files: `SettingsView.swift` (restructure), `AppDelegate.swift` (overlay presentation,
  login item), `Store.swift` (new keys: `launch_at_login`, `skip_intro`, shortcut storage).

**Effort:** M. **Risk:** none destructive; keep every existing setting reachable (Advanced),
don't orphan keys.

### 3.4 Menu-bar tools: Keep Screen On, Clean Screen, About, Check for Updates

**Design spec:** Right-click menu on the status item: **Settings · Run Doctor · Keep Screen
On · Clean Screen · About · Check for Updates**.

**Plan:**
- **Right-click quick menu** (new — `StatusBarController.swift` currently has none): Open
  Burrow · Settings… · Keep Screen On ▸ (15m / 30m / 1h / 2h / Until off) · Clean Screen ·
  About Burrow · Check for Updates… · Quit. ("Run Doctor" joins when Doctor ships — roadmap
  appendix #5.)
- **Keep Screen On** (`Awake.swift`): `IOPMAssertionCreateWithName` (NoDisplaySleep +
  PreventUserIdleSystemSleep) with a duration timer; checkmark state in the menu, indicator
  in the popover utility strip (3.5); global shortcut via 3.3's recorder. Auto-releases on
  expiry; never asks for admin.
- **Clean Screen** (`CleanScreen.swift`): a borderless solid-color window per display at
  `.screenSaver` level, subtle "Press Esc to exit" hint after a beat. **Input lock** is
  opt-in: a CGEventTap swallowing keys (except Esc) requires the Accessibility permission —
  gate behind an explainer with its own `PermissionRow`; without it, Clean Screen still works
  (keys just aren't blocked). Input-protection options (F-row, brightness, volume, Dictation)
  in Settings ▸ Menu Bar. Plain color + one line of our own copy.
- **About Burrow:** standard panel — app version/build, engine version, links: GitHub,
  releases, TELEMETRY.md, licenses. Reachable from the app menu and the right-click menu.
- **Check for Updates:** manual-only v1 — GitHub Releases API compare against current
  version; if installed via Homebrew (cask receipt detectable) suggest
  `brew upgrade --cask burrow`, else open the release page. Network egress documented like
  2.3. Self-update waits for signed/notarized distribution (appendix #8).
- Files: `StatusBarController.swift`, new `Awake.swift`, `CleanScreen.swift`,
  `UpdateCheck.swift`, About panel in `AppDelegate.swift`.

**Effort:** M total — Clean Screen's event tap is the fiddly part; everything else is S each.

### 3.5 Menu bar popover HUD — dense single-glance layout

**Design spec:** Dense popover: **header** — health glyph + score + headline issue + free
space + chevron (opens app); **chips row** — chip model · RAM · macOS version · uptime;
**2-col metric tiles** with corner chips — CPU (temp), GPU (temp), MEM (pressure), DISK
(total, used bar, free line), NET (interface chip, throughput, dual sparkline, ↑/↓ split),
FAN (load chip, RPM, "macOS manages speed"); **battery card** — health chip, charge % + time
left, cycles + temp, **ring gauges (Mac + Bluetooth devices)**, **"⚡ Top drain — <app>"**;
**top processes** table (name, CPU, Memory, "…" per row); **utility strip** — Stay Awake ·
Wipe · Eject; **lifetime stats footer** — "Clean Watch": total cleaned · uninstalled ·
optimized.

**Plan (rework `PopupView.swift`; most data already flows through `Sampler` + `IOMonitor`):**
- **Header:** fold the current health hero into a one-line header — glyph, score, top issue,
  free space — chevron opens the main window on Home. Chips row beneath (chip model, RAM,
  macOS version, uptime — all in `MoleStatus`).
- **Tiles:** add corner chips (temps, pressure, totals) to the existing 2-col grid; add DISK
  bar + free line and the FAN tile (read-only v1, same rule as 3.2 — mode buttons only when
  fan control ships). NET tile gains the ↑/↓ split line and interface chip (data exists).
- **Battery card:** rings for Mac + each connected BT device (existing Bluetooth data), cycle
  count + temp line, and **Top drain** — the heaviest process by CPU-time over the last hour
  from history (`burrow_process_usage` logic; upgrades to true energy ranking when 3.2's PWR
  column lands).
- **Top processes:** add Memory column and the per-row "…" menu (same `ProcessActions` as
  3.2, minus kill for root rows).
- **Utility strip:** Stay Awake (3.4 toggle), Wipe (3.4 Clean Screen), **Eject** — eject all
  external volumes via DiskArbitration, shown only when externals are mounted. Camera/mic
  privacy indicators are **deferred** until a privacy-check feature exists (appendix #7) —
  the strip ships without them; don't fake the affordance.
- **Clean Watch footer:** lifetime aggregates from `mo history --json` (total bytes cleaned ·
  apps uninstalled · optimize runs), cached daily. This also delivers the "lifetime cleanup
  total" item — surface the same numbers on Clean's done screen.
- **Burrow-specific:** keep the footer tool pills + MCP status line — it's our agent story —
  placed below Clean Watch.
- Files: `PopupView.swift` (major), `HUDController.swift` (sizing), `MoleHistory.swift`
  (aggregates), shared `ProcessActions.swift`, `Awake/CleanScreen` hooks.

**Effort:** L — the densest single view; almost all data exists, the work is layout +
the three small new capabilities (eject, top-drain query, clean-watch aggregates).

---

## Build order across all batches

Dependencies and effort considered, roughly five waves:

1. **Foundations (S–M):** 1.3 access banner + gate demotion → 1.1/1.2 onboarding → 3.3
   settings restructure (Launch at Login, Skip Intro live here) → 3.4 right-click menu +
   About + Check for Updates. Small, visible, no engine work.
2. **Clean pipeline (M–L):** 1.4 parser + review screen → 2.1 result hero with count-up →
   2.5 task ticker (shared component, Optimize first). One coherent arc — ship together.
3. **Software tab (L):** 2.2 uninstall expansion (largest single item) → 2.4 startup segment
   (read-only first) → 2.3 update sources v1.
4. **Status & popover (M–L each):** 3.2 status tiles + process table → 3.5 popover rework
   (reuses 3.2's chips/ProcessActions) → 3.1 analyze progress.
5. **New tools (M):** 3.4 Keep Screen On + Clean Screen (+ shortcuts in Settings ▸ Menu Bar).
   Fan-control UI stays parked until the privileged helper (roadmap) exists.

Standing rules from the header apply to every wave: original assets and copy only, zh-Hans +
accessibility per PR, honest verbs, and no fake affordances (no disabled fan buttons, no
faked scan progress).
