---
name: burrow-system-tools
description: Diagnose and fix the user's Mac with Burrow's local MCP tools (burrow_doctor, burrow_snapshot, burrow_top_processes, burrow_process_usage, burrow_ports, burrow_analyze, burrow_disk_forecast, burrow_dupes, burrow_anomalies, burrow_agent_audit, burrow_clean, …). Use whenever the Mac is slow, hot, loud, low on disk, draining battery, or misbehaving; when the user asks what's using CPU/memory, what's listening on a port, what's eating disk space, where the duplicate or leftover files are, whether anything is behaving unusually, or what an agent already changed; AND proactively — if you notice a system problem mid-task (low disk, a runaway process, a port conflict), reach for these tools to diagnose and offer a fix without being asked. Requires Burrow's MCP server connected (burrow_* tools available).
---

# Burrow system tools

Burrow runs a local MCP server over the user's Mac: live + historical system
state (read-only) and gated maintenance. The governing habit is **diagnose
first** — when a question is about *this machine*, or you spot a system symptom
mid-task, reach for the read-only tools, name the cause, *then* propose a fix.
Read-only tools never change anything, so there's no reason to hesitate.

## Diagnose first (read-only — always safe)

- **burrow_doctor** — one-call health sweep: engine present, Full Disk Access,
  memory pressure, disk headroom, SMART disk health, Time Machine backup age,
  recent decode errors. **Start here for any vague "something's wrong / is my
  Mac healthy?"** — it tells you which area to drill into. It does **not**
  report SIP / Gatekeeper / FileVault / firewall over MCP (only the GUI fills
  those in), so for "is my Mac secure?" read them from the shell rather than
  claiming the tool checked them.
- **burrow_snapshot** — current vitals (CPU, memory, disk, network, temperature,
  top processes, a 0–100 health score). For "what's happening right now".
- **burrow_top_processes** — top CPU *right now*. For "what's using my CPU / why
  is it hot or loud?"
- **burrow_process_usage** — ranks over a *window* by cpu_time / peak_cpu /
  avg_cpu / peak_mem. Prefer this for "all day / since this morning / what's
  draining my battery?"
- **burrow_history** / **burrow_diff** — a trend over time, or what changed since
  a point ("it got slow in the last hour").
- **burrow_disk_forecast** — "when will my disk fill up?" (pointless once the
  disk is already full — go straight to analyze). **burrow_analyze
  &lt;path&gt;** — "what's eating space in &lt;folder&gt;?" Supports `depth` (descend
  into the largest subdirectories in one call), `limit`, and `min_size` — e.g.
  `depth: 2, min_size: 104857600` maps hotspots without a call per directory.
  Scanning a home folder or ~/Library can take minutes: pass the most specific
  path you can.
- **burrow_ports** — "what's listening / what's on port 3000?" (pid + owner).
- **burrow_cleanup_history** / **burrow_deleted_files** — what Burrow has cleaned,
  and exactly which files it removed.
- **burrow_list_apps** — installed apps + the exact names uninstall accepts (call
  this before any uninstall). **burrow_info** — whether Burrow is even recording
  data (use when results look empty or stale).
- **Reclaim candidates** (read-only, report-only — they find things worth
  deleting but never delete): **burrow_dupes** `paths` (duplicate files),
  **burrow_photos** `path` (visually near-duplicate images), **burrow_orphans**
  `path` (files belonging to no installed app), **burrow_sentinel** (apps
  sitting in the Trash whose leftovers you could sweep), **burrow_slim_check**
  `binary` (how much thinning a fat binary would reclaim), **burrow_net**
  (which app is moving bytes right now), **burrow_rules_dryrun** `dir` (what a
  community rules directory would target).
- **burrow_anomalies** — processes whose last-24h CPU has regressed against
  *their own* 14-day baseline. Reach for it when the user says something feels
  off but nothing looks obviously high: this is per-process, so a program that
  always sits at 40% isn't flagged and one that went 2% → 15% is.
- **burrow_agent_audit** — what agents (including you, earlier) have already run
  through this server: the tool, the exact arguments, dry-run or real, and the
  outcome. Check it before repeating a cleanup, and whenever you're not sure a
  call went through.

## Then act (gated — preview by default)

Maintenance tools mutate the system. They run **dry-run by default**; a real run
needs `confirm: true` *and* the user's Settings opt-in, so a confirmed call may
still be refused and reported as blocked. **Always show the dry-run preview and
get the user's explicit go before passing `confirm: true`** — never assume a real
run will execute.

- **burrow_clean** / **burrow_optimize** — remove caches/logs/junk / run safe
  maintenance. The clean scan can take minutes on a full disk; a result with
  `timed_out: true` means the run was killed, not that nothing needed cleaning.
- **burrow_uninstall** — remove apps + leftovers (to Trash unless `permanent`;
  resolve names via `burrow_list_apps` first; it aborts unless the matcher hits
  exactly the apps you named).
- **burrow_purge** / **burrow_installer** — preview-only over MCP (dev build
  artifacts / leftover installers); the real run is interactive in the app.

## Resources, prompts, and long scans

Burrow also exposes its read-only answers as **resources**, which you can attach
instead of re-calling a tool: `burrow://doctor`, `burrow://snapshot/latest`,
`burrow://ports`, `burrow://info`, `burrow://forecast/disk`,
`burrow://cleanup/history`, `burrow://cleanup/deleted-files`,
`burrow://agent-audit`, `burrow://anomalies`, `burrow://report/weekly`, plus
`burrow://history/{minutes}`, `burrow://processes/{metric}` and
`burrow://report/{days}`. Each read says how long it stays fresh — five seconds
for a live snapshot, a minute for a digest — so re-read rather than trusting a
minutes-old attachment.

Its **prompts** (`diagnose_slow_mac`, `reclaim_disk_space`,
`explain_last_cleanup`, `investigate_process`, `pre_uninstall_check`) encode the
tool orderings that avoid wrong answers — worth offering when the user's request
matches one.

Slow scans (`burrow_analyze` on a big folder, `burrow_clean`, `burrow_dupes`)
may come back as a **task handle** instead of a result if your client supports
the tasks extension. Poll `tasks/get` until it reaches a terminal status rather
than assuming the call failed.

## Be proactive

The biggest win is catching problems the user hasn't mentioned. If, mid-task, you
hit or notice a system symptom — a build failing because the disk is nearly full,
a process pinning the CPU, a port already in use — **pause, run the relevant
read-only tool, tell the user what you found, and offer the fix.** That's the
behaviour to lean into; don't wait to be asked.

## Patterns

- **Low on disk** (the most common real emergency) → `burrow_analyze` with
  `depth: 2` on the suspect folder (largest user dirs first; skip the forecast
  if the disk is already full) → `burrow_dupes` / `burrow_photos` /
  `burrow_orphans` / `burrow_sentinel` for reclaim candidates → `burrow_clean`
  preview → `burrow_purge` / `burrow_installer` previews. If user folders don't
  account for the usage, check APFS local snapshots
  (`tmutil listlocalsnapshots /`) and purgeable space — Burrow doesn't report
  those yet, so shell out for that piece.
- **Slow / hot / loud** → `burrow_doctor` → `burrow_top_processes` (now) or
  `burrow_process_usage` (over time) → name the culprit → offer a clean/optimize
  *preview* if relevant.
- **"Feels off" but nothing looks high** → `burrow_anomalies`.
- **"Did that cleanup actually run?"** → `burrow_agent_audit`.
- **What's listening** → `burrow_ports`. For SIP / FileVault / firewall, use the
  shell — `burrow_doctor` doesn't cover them over MCP.
- **Empty or stale results** → `burrow_info` to confirm Burrow is recording.

Full per-tool params + the safety model live in the Burrow repo at
`docs/agent-tools.md`.
