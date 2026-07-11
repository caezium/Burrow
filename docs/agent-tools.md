# Burrow for AI agents

Burrow runs a local [MCP](https://modelcontextprotocol.io) server over stdio, so any
MCP-capable agent (Claude Code, Cursor, Codex, Cline, Zed, …) can read your Mac's recent
state and — with your explicit opt-in — run safe maintenance. This page is the **tool
reference + when to reach for each one**. Setup is in the
[README](../README.md#use-it-with-your-ai-agent).

Everything is **local** (`127.0.0.1` / stdio only), reads a shared on-disk history Burrow
samples continuously, and every actuating call is **dry-run by default**.

## The two kinds of tools

- **Read-only (21)** — observe and diagnose. Always safe; call these proactively whenever a
  question is about *this machine's* state, history, or health.
- **Actuating, gated (5)** — clean / optimize / uninstall / purge / installer. **Preview by
  default** (`--dry-run`); a real run needs `confirm: true` **and** the user's Settings
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
| **burrow_doctor** | "Is my Mac healthy / is anything wrong?", or as a first pass on any vague performance/security complaint. One call returns ok/warn/fail checks for engine presence, Full Disk Access, memory pressure, disk headroom, decode errors, **security posture (SIP/Gatekeeper/FileVault/firewall)**, **battery health**, sustained high-CPU, and display/external-volume/network context. | — |
| **burrow_top_processes** | "What's using my CPU?" / "why is my Mac hot or loud?" Ranks processes by **peak** CPU% over a window. | `minutes`, `limit` |
| **burrow_process_usage** | "What's been draining my battery / running hottest *over time*?" Ranks by `cpu_time` (cumulative), `peak_cpu`, `avg_cpu`, or `peak_mem`, and echoes the window it used. Prefer this over `top_processes` for "all day / since this morning" questions. | `minutes`, `metric`, `limit` |
| **burrow_history** | The user asks about a trend ("has memory crept up since noon?") or you want a time-series slice rather than a single point. | `minutes`, `samples` |
| **burrow_diff** | "What changed?" Compares the snapshot nearest `since` (or `minutes` ago) to now: which processes entered/left the top list, free-space delta. Good after the user says "it got slow in the last hour". | `since`, `minutes` |
| **burrow_disk_forecast** | "When will my disk fill up?" Projects days-until-full from free-space history (cliff-robust; returns null if the trend is flat/growing). | `days`, `mount` |
| **burrow_ports** | "What's listening on my machine / what's using port 3000?" Lists listening TCP/UDP ports with the owning process (pid, name, uid). Read-only — to free a port, tell the user which pid to kill. | — |
| **burrow_report** | "Give me a weekly digest." Returns a Markdown system report over `days`: disk forecast, top energy users, cleanup summary. | `days` |
| **burrow_info** | Meta/diagnostic: "is Burrow actually recording data?" Shows data prefixes + row counts + staleness, retention, sample interval, decode-skip count. Use when other tools return empty/stale data to explain why. | — |

## Cleanup history (read-only)

| Tool | Use it proactively when… | Key params |
|---|---|---|
| **burrow_cleanup_history** | "What has Burrow cleaned / how much space have I reclaimed?" Itemised past clean/optimize/purge/uninstall sessions with bytes freed and removed/trashed/skipped/failed breakdowns. | `limit` |
| **burrow_deleted_files** | "What exactly did it delete?" / "did it remove <file>?" Exact paths Burrow trashed or removed, newest first, with action + status. Report-only. | `limit` |

## Disk & apps (read-only)

| Tool | Use it proactively when… | Key params |
|---|---|---|
| **burrow_analyze** | "What's taking up space in <folder>?" Size-ranked directory tree (the data behind the treemap). Read-only. | `path` |
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
| **burrow_clean** | Removes caches, logs, temp files, leftovers (`mo clean`). | Dry-run unless `confirm:true` **and** "Let agents run cleanups" is on, else blocked. | `confirm` |
| **burrow_optimize** | Refreshes caches/services, safe maintenance (`mo optimize`). | Same gate as clean. | `confirm` |
| **burrow_uninstall** | Uninstalls apps + leftovers (`mo uninstall`). Files go to Trash unless `permanent:true`. | Needs `confirm:true` **and both** opt-ins; aborts unless the matcher resolves exactly the apps you named. Call `burrow_list_apps` first. | `apps` (required), `confirm`, `permanent` |
| **burrow_purge** | Finds dev build artifacts (`node_modules`, `target/`, …). | **Preview-only over MCP** — returns the dry-run list; the real purge is an interactive flow in the app. | `confirm` (reserved) |
| **burrow_installer** | Finds leftover installers (`.dmg`/`.pkg`/…). | **Preview-only over MCP**, like purge. | `confirm` (reserved) |

Every actuating call is recorded to Burrow's audit log, so the user can see what an agent did.

---

## Patterns

- **"My Mac is slow/hot/loud"** → `burrow_doctor` → `burrow_top_processes` (now) or
  `burrow_process_usage` (over time) → name the culprit; offer `burrow_clean`/`optimize`
  preview only if relevant.
- **"I'm low on disk"** → `burrow_disk_forecast` → `burrow_analyze <folder>` →
  `burrow_dupes`/`burrow_photos`/`burrow_orphans`/`burrow_sentinel` for reclaim candidates →
  `burrow_purge`/`burrow_installer` previews → `burrow_clean` preview.
- **"Is anything insecure / what's listening?"** → `burrow_doctor` (SIP/Gatekeeper/FileVault/
  firewall) + `burrow_ports`.
- **"What did Burrow change?"** → `burrow_cleanup_history` + `burrow_deleted_files`.
- **Empty/stale results?** → `burrow_info` to confirm data is flowing.

## Not yet exposed over MCP

The 0.9 app has features that don't yet have agent tools (tracked for a follow-up): the
per-process **inspector** (code signature, Mach-O arch, deep metrics, open connections), the
**process tree**, table **filter/suspend/resume/export**, the **CPU watchdog**, and **Get
Online** (speed test, nearby Wi-Fi scan, captive-portal tips, connection history). Until then,
use `burrow_snapshot` / `burrow_top_processes` / `burrow_process_usage` for process questions.
