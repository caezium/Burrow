# Unreleased

The review of the bundled engine and the app around it, in one wave: the
engine deletes through one set of rails and accounts for what it did, the
app streams every long-running path live, and a reviewed clean runs exactly
what was reviewed.

## Engine safety rails
- **One deletion path, re-checked per item.** Every removal — clean, purge,
  installer, uninstall, and the reviewed clean — goes through the engine's
  own rails: the protection tables, the whitelist re-check, the Trash rail,
  and a refusal for anything outside the clean roots. A refused path comes
  back as `protected` with its reason rather than vanishing from the report.
- **Accounting that says what happened.** `freed_bytes` is what left the
  disk; `moved_to_trash_bytes` is what went to the Trash (the default, so a
  mistake is recoverable). The app reports the two separately — "moved to
  Trash" is never folded into "Cleaned" — and an optimize task skipped for
  want of an administrator is shown as skipped, not failed.
- **CPU sampled over a real window.** `status` measures CPU across the
  interval instead of a quantised instant (`per_core_estimated: false`).

## The administrator prompt
- **Elevated runs stream live, on both routes.** The privileged helper
  recognises the engine's own argv now (a bare `clean` is the preview it
  always was to the engine, never a live run), relays the engine's output
  line by line over XPC, and keeps Touch ID; the osascript route tails the
  root shell's log. Uninstall prompts for an administrator when the bundle
  needs one instead of failing.

## Streams
- **Status is one long-lived `status --watch` process** instead of a spawn
  per tick, with polling only as the fallback if the stream ever drops.
- **The treemap fills as the scan runs**: `analyze --progress` is on by
  default (`BurrowStreamAnalyze -bool NO` turns it off), with the per-child
  walk as the fallback.
- **Purge previews and runs stream.** Purge and Installers move off the
  terminal checklist (which the bundled engine, never interactive, could not
  drive) onto the same preview → confirm → live-run flow Clean uses. The
  engine has no per-project selection, so the preview is the list and the
  run sends all of it to the Trash.

## Plan, then execute
- **Confirm does not re-scan.** The review's ticked paths are written to a
  plan file and the engine runs `clean --apply --permanent --plan <file>`,
  removing only what is listed — each path re-checked through its rails —
  and reporting every one back. The stale-review timer stays; the osascript
  route still runs its boundary checks first; the helper validates the paths
  itself and writes its own root-only plan file, and `find` leaves its
  executable set. The plan file is deleted when the run ends.

## MCP hardening
- `burrow_evict` for iCloud local copies, one engine spawn path for every
  tool, honest engine attribution in every reply, `burrow_dupes` pinned to
  the read-only group subcommand, and the Windows engine build no longer
  interpolates argv into a PowerShell command string.

# Burrow 0.14.0

The Touch ID helper now offers itself, and the reviewed clean says what it
removed instead of finishing silently.

## Added
- **Burrow offers the privileged helper.** The helper that lets admin
  operations authenticate with Touch ID shipped in 0.13.0 behind a single
  button in **Settings ▸ Advanced**, and nothing pointed anyone at it —
  upgraders learned about it from the release notes, fresh installs not at all.
  It is now offered the way Full Disk Access is: one banner over the window,
  informing rather than blocking. At most one notice shows at a time, and
  dismissing the helper notice is permanent, because the helper is a
  convenience rather than something Burrow needs to work.

## Fixed
- **The reviewed clean reports what it removed.** It deleted exactly what was
  ticked and then looked like it had done nothing. That path doesn't run the
  engine's cleaner — it deletes each reviewed path with `find`, which succeeds
  *silently*, so the result screen had no output to show: no items, no freed
  total, no done banner. It now reports the paths it was authorized to remove,
  grouped by category with their sizes summed, which is a statement of fact
  rather than optimism — the run only succeeds after confirming every planned
  path is gone.

Nothing changed about what the reviewed clean deletes, or about the checks it
passes before deleting: this release makes it visible, not different.
