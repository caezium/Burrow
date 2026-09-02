# Burrow for AI agents

Burrow runs a local [MCP](https://modelcontextprotocol.io) server over stdio, so any
MCP-capable agent (Claude Code, Cursor, Codex, Cline, Zed, …) can read your Mac's recent
state and — with your explicit opt-in — run safe maintenance. This page is the **tool
reference + when to reach for each one**. Setup is in the
[README](../README.md#use-it-with-your-ai-agent).

Everything is **local** (`127.0.0.1` / stdio only), reads a shared on-disk history Burrow
samples continuously, and every actuating call is **dry-run by default**.

The server speaks MCP **2026-07-28** — the stateless revision, with `server/discover`, tasks,
and cache hints — and still answers the older `initialize` handshake, so it works with clients
of either era. See [Protocol surface](#protocol-surface) at the bottom.

## The two kinds of tools

- **Read-only (23)** — observe and diagnose. Always safe; call these proactively whenever a
  question is about *this machine's* state, history, or health.
- **Actuating, gated (6)** — clean / optimize / uninstall / purge / installer / evict. **Preview
  by default** (`--dry-run`); a real run needs `confirm: true` **and** the user's Settings
  opt-in ("Let agents run cleanups", plus a second switch for uninstall). Without the opt-in
  the call is refused and reported as blocked — so it's safe to attempt, but never assume it
  will execute.

> Rule of thumb: **lead with the read-only tools.** Diagnose first, propose second, and only
> call an actuating tool after you've shown the user the dry-run preview and they've asked you
> to proceed.

---

## Observe & diagnose (read-only)

| Tool | Use it proactively when… | Key params |
|---|---|---|
| **burrow_snapshot** | The user asks "what's my CPU/memory/disk/network/temperature right now", or you need current vitals before reasoning. Returns the latest full status snapshot incl. top processes + a 0–100 health score. | — |
| **burrow_doctor** | "Is my Mac healthy / is anything wrong?", or as a first pass on any vague performance complaint. Returns ok/warn/fail checks for engine presence, Full Disk Access, memory pressure, disk headroom, SMART disk health, Time Machine backup age, and decode errors. **Not security posture:** SIP/Gatekeeper/FileVault/firewall, battery health, CPU load and display/volume/network context exist in the Doctor engine but are only filled in by the GUI — over MCP those checks are omitted, so answer security questions from the shell, not from this tool. | — |
| **burrow_top_processes** | "What's using my CPU?" / "why is my Mac hot or loud?" Ranks processes by **peak** CPU% over a window. | `minutes`, `limit` |
| **burrow_process_usage** | "What's been draining my battery / running hottest *over time*?" Ranks by `cpu_time` (cumulative), `peak_cpu`, `avg_cpu`, or `peak_mem`, and echoes the window it used. Prefer this over `top_processes` for "all day / since this morning" questions. | `minutes`, `metric`, `limit` |
| **burrow_history** | The user asks about a trend ("has memory crept up since noon?") or you want a time-series slice rather than a single point. | `minutes`, `samples` |
| **burrow_diff** | "What changed?" Compares the snapshot nearest `since` (or `minutes` ago) to now: which processes entered/left the top list, free-space delta. Good after the user says "it got slow in the last hour". | `since`, `minutes` |
| **burrow_disk_forecast** | "When will my disk fill up?" Projects days-until-full from free-space history (cliff-robust; returns null if the trend is flat/growing). | `days`, `mount` |
| **burrow_ports** | "What's listening on my machine / what's using port 3000?" Lists listening TCP/UDP ports with the owning process (pid, name, uid). Read-only — to free a port, tell the user which pid to kill. | — |
| **burrow_report** | "Give me a weekly digest." Returns a Markdown system report over `days`: disk forecast, top energy users, cleanup summary. | `days` |
| **burrow_info** | Meta/diagnostic: "is Burrow actually recording data?" Shows data prefixes + row counts + staleness, retention, sample interval, decode-skip count. Use when other tools return empty/stale data to explain why. | — |
| **burrow_anomalies** | "Is anything behaving *unusually*?" Processes whose last-24h CPU has regressed against their own 14-day baseline. This is per-process, not a leaderboard: a process that always sits at 40% isn't flagged, one that went 2% → 15% is. Empty when there isn't enough history. | — |
| **burrow_agent_audit** | "What has an agent already done to this machine?" One row per mutating call with the exact arguments, dry-run flag, outcome, and duration. Check it before assuming a cleanup didn't run — and to re-read your own earlier calls in a long session. | `minutes`, `limit` |

## Cleanup history (read-only)

| Tool | Use it proactively when… | Key params |
|---|---|---|
| **burrow_cleanup_history** | "What has Burrow cleaned / how much space have I reclaimed?" Itemised past clean/optimize/purge/uninstall sessions with bytes freed and removed/trashed/skipped/failed breakdowns. | `limit` |
| **burrow_deleted_files** | "What exactly did it delete?" / "did it remove <file>?" Exact paths Burrow trashed or removed, newest first, with action + status. Report-only. | `limit` |

## Disk & apps (read-only)

| Tool | Use it proactively when… | Key params |
|---|---|---|
| **burrow_analyze** | "What's taking up space in <folder>?" Size-ranked children of a directory, largest first (the data behind the treemap); `depth` > 1 descends into the largest subdirectories so one call replaces a drill-down loop. Scanning a home folder or `~/Library` can take minutes — pass the most specific path you can, and use `min_size` to skip noise. Truncation is reported via `entries_omitted`/`omitted_bytes`, and `partial: true` means the descent hit its time budget. Read-only. | `path`, `depth`, `limit`, `min_size` |
| **burrow_list_apps** | Before any uninstall, **always call this first** to get the exact app name `burrow_uninstall` accepts. Also answers "what apps are installed?" | — |

## Discovery (read-only, via the bundled conductor)

These route through the bundled `burrow` conductor and pass its JSON through verbatim. They
find *reclaim candidates* but never delete anything — reporting only. On a build without the
bundled conductor they return a JSON error object saying so (never a crash).

| Tool | Use it proactively when… | Key params |
|---|---|---|
| **burrow_dupes** | "Do I have duplicate files in <folder>?" Duplicate-file groups (fclones group report) across one or more directories. Report-only — deletes nothing. | `paths` (required) |
| **burrow_orphans** | "What leftovers did uninstalled apps leave behind?" Files under a directory that belong to no installed app. `installed` (csv of bundle ids) overrides auto-detection. | `path` (required), `installed` |
| **burrow_net** | "Which app is using my network right now?" Per-app network attribution. | — |
| **burrow_photos** | "Do I have near-duplicate photos in <folder>?" Visually-similar PNG/JPEG groups (dHash). Report-only. | `path` (required) |
| **burrow_rules_dryrun** | Previewing what a community cleanup-rules directory would target: per-rule paths with risk + existence, nothing deleted. `dir` is required — no rules ship with the app. | `dir` (required), `app` |
| **burrow_sentinel** | "Did I trash any apps whose leftovers I should sweep?" `.app` bundles currently in the Trash. | `trashdir` |
| **burrow_slim_check** | "How much space would thinning <binary> reclaim?" Mach-O fat-slice analysis — estimate only, never rewrites the binary. | `binary` (required) |

---

## Act & maintain (actuating — gated, dry-run by default)

These mutate the system. **Default to the preview**, show the user what would happen, and only
pass `confirm: true` when they've explicitly approved *and* you understand the opt-in may block
it. Real cleans run at user level (not elevated).

| Tool | What a real run does | Safety | Key params |
|---|---|---|---|
| **burrow_clean** | Removes caches, logs, temp files, leftovers (`mo clean`). The scan can take minutes on a full disk; a `timed_out: true` result means the run was killed, not that nothing needed cleaning. | Dry-run unless `confirm:true` **and** "Let agents run cleanups" is on, else blocked. | `confirm` |
| **burrow_optimize** | Refreshes caches/services, safe maintenance (`mo optimize`). | Same gate as clean. | `confirm` |
| **burrow_uninstall** | Uninstalls apps + leftovers (`mo uninstall`). Files go to Trash unless `permanent:true`. | Needs `confirm:true` **and both** opt-ins; aborts unless the matcher resolves exactly the apps you named. Call `burrow_list_apps` first. | `apps` (required), `confirm`, `permanent` |
| **burrow_evict** | Evicts the *local copies* of cloud-synced files (iCloud Drive) via `burrow evict` — they stay in the cloud and re-download on access, so disk is reclaimed and nothing is deleted. Paths must be absolute and exist. macOS only. | Dry-run (existence report) unless `confirm:true` **and** "Let agents run cleanups" is on, else blocked. | `paths` (required), `confirm` |
| **burrow_purge** | Finds dev build artifacts (`node_modules`, `target/`, …). | **Preview-only over MCP** — returns the dry-run list; the real purge is an interactive flow in the app. | `confirm` (reserved) |
| **burrow_installer** | Finds leftover installers (`.dmg`/`.pkg`/…). | **Preview-only over MCP**, like purge. | `confirm` (reserved) |

Every actuating call is recorded to Burrow's audit log, so the user can see what an agent did —
and `burrow_agent_audit` reads that log back, so you can see it too.

---

## Beyond tools

**Resources** — the read-only answers agents re-poll most, attachable instead of re-called.
`burrow://snapshot/latest`, `burrow://doctor`, `burrow://ports`, `burrow://info`,
`burrow://forecast/disk`, `burrow://cleanup/history`, `burrow://cleanup/deleted-files`,
`burrow://agent-audit`, `burrow://anomalies`, `burrow://report/weekly`, plus templates
`burrow://history/{minutes}`, `burrow://processes/{metric}`, and `burrow://report/{days}`.
Each read carries a `ttlMs` telling you how long it stays honest — five seconds for a live
snapshot, a minute for a digest.

**Prompts** — `diagnose_slow_mac`, `reclaim_disk_space`, `explain_last_cleanup`,
`investigate_process`, `pre_uninstall_check`. Each encodes the tool ordering that avoids wrong
answers, so a host can offer the right investigation as one click.

**Tasks** — a client that declares `io.modelcontextprotocol/tasks` gets a task handle instead
of a blocking call for the slow tools (`burrow_analyze`, `burrow_dupes`, `burrow_photos`,
`burrow_orphans`, and the actuating clean/optimize/uninstall/purge/installer). Poll `tasks/get` until terminal; pass a
`progressToken` if you want `notifications/progress` while it runs. Without the extension the
same call behaves exactly as before. This is what stops a multi-minute clean coming back as
`timed_out: true`, which reads like "nothing to clean" when it means "we gave up".

**Missing arguments** — a client that supports elicitation gets an `input_required` result
asking for the argument (which apps to uninstall, which directory to scan) rather than an
error. Answer it by re-issuing the call with `inputResponses` and the `requestState` you were
given. Note what this is *not*: answering an elicitation cannot authorise a destructive run.
The Settings opt-in is the only thing that can, and an agent cannot set it.

---

## Protocol surface

| Method | Notes |
|---|---|
| `server/discover` | Supported versions, capabilities, and the usage instructions. No handshake needed. |
| `initialize` | Still answered for pre-2026 clients; negotiates down to their revision. |
| `tools/list` / `tools/call` | Deterministically ordered, annotated, `outputSchema` + `structuredContent` on all but `burrow_report` (Markdown). |
| `resources/list`, `resources/templates/list`, `resources/read` | Cache hints on every result. |
| `prompts/list`, `prompts/get`, `completion/complete` | Completion covers metric names and recently-seen process names. |
| `tasks/get`, `tasks/update`, `tasks/cancel` | The tasks extension. Cancellation is cooperative — it stops us reporting, not the engine subprocess. |

Deliberately not implemented: Roots, Sampling, and Logging (all deprecated in this revision),
the legacy HTTP+SSE transport, and Streamable HTTP. The last one is a security design question
rather than a transport swap — Burrow shells out to a privileged helper and deletes files, so
opening a listener needs its own auth model first.

---

## Patterns

- **"I'm low on disk"** (the most common real emergency) → `burrow_analyze <folder>` with
  `depth: 2` on the largest user dirs (skip `burrow_disk_forecast` when the disk is already
  full — forecasting is for "when will it fill", not "it's full now") →
  `burrow_dupes`/`burrow_photos`/`burrow_orphans`/`burrow_sentinel` for reclaim candidates →
  `burrow_purge`/`burrow_installer` previews → `burrow_clean` preview. If user folders don't
  account for the usage, check APFS local snapshots (`tmutil listlocalsnapshots /`) and
  purgeable space via the shell — Burrow doesn't report those yet.
- **"My Mac is slow/hot/loud"** → `burrow_doctor` → `burrow_top_processes` (now) or
  `burrow_process_usage` (over time) → name the culprit; offer `burrow_clean`/`optimize`
  preview only if relevant.
- **"What's listening?"** → `burrow_ports`. For "is anything insecure", `burrow_doctor` over MCP
  does **not** cover SIP/Gatekeeper/FileVault/firewall — read those from the shell (`csrutil
  status`, `spctl --status`, `fdesetup status`, `/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate`) until the
  tool fills them in.
- **"What did Burrow change?"** → `burrow_cleanup_history` + `burrow_deleted_files`.
- **"Did an agent already do this?"** → `burrow_agent_audit` before repeating a cleanup, and
  after a call you're unsure completed.
- **"Something's off but nothing looks high"** → `burrow_anomalies`, which compares each
  process against its own history rather than against the others.
- **Empty/stale results?** → `burrow_info` to confirm data is flowing.

## Not yet exposed over MCP

The app still has features without agent tools (tracked for a follow-up): the per-process
**inspector** (code signature, Mach-O arch, deep metrics, open connections), the **process
tree**, table **filter/suspend/resume/export**, the **CPU watchdog**, and **Get Online** (speed
test, nearby Wi-Fi scan, captive-portal tips, connection history). Until then, use
`burrow_snapshot` / `burrow_top_processes` / `burrow_process_usage` for process questions.
