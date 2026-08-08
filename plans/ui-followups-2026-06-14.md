# UI follow-ups implementation plan — 2026-06-14

> Historical plan. Its ad-hoc-signing blocker describes the 0.7.1 release
> pipeline; the fail-closed Developer ID and notarization path landed in #312.
> Its GitHub/Homebrew banner was superseded in 0.11 by Sparkle's signed native
> updater; the implementation notes below remain as historical context.
> A resident privileged helper remains a separate product and security decision.

Branch: `feat/ui-followups-2026-06-14` (worktree `/Users/henry/Desktop/Burrow-work`, off `main` 0.7.1).
Grounded in a per-area survey of the real 0.7.1 tree (the prior survey read a stale checkout 55
commits behind — that checkout, `/Users/henry/Desktop/Burrow` on `fix/ci-streaming-apphang`,
must NOT be used for this work).

## Decisions (locked 2026-06-14)

1. **App updates auto-surface** — keep the "no silent network" contract. On Apps→Updates open:
   auto-run `brew outdated` (the user's own tool, no app-controlled egress) + show **cached**
   prior results; the first **live** third-party check (Sparkle appcast / iTunes lookup) still
   needs a click. No SECURITY.md change.
2. **Burrow self-update** — auto-check **ON by default**, at launch + ~daily; surface a found
   update as a **dismissible in-window banner + a menu-bar dot**; add About + Check-for-Updates
   to Settings with a disable toggle; **document the periodic GitHub GET in SECURITY.md**.
3. **Merge Purge + Installer into Clean** — one Clean pane with **three category cards**
   (Caches / Project artifacts / Leftover installers); drop the two top-nav pills; engines and
   views reused byte-for-byte; single teal theme.
4. **Heavy items — "do it all"** — build a signed privileged helper enabling fan Auto/Cool/Max,
   elevated system-daemon startup disable, and root purgeable-space reclaim. **See the blocker
   below.**

Defaults I chose without asking (say so, easy to revisit): camera/mic indicators **opt-in,
off by default**; **do not embed Sparkle** (third-party app updates hand off to each vendor's
own updater; only Burrow self-updates).

## ⚠️ Blocker on decision 4 (privileged helper)

A root helper installed via `SMAppService.daemon` (or `SMJobBless`) only loads if it is signed
with a stable **Developer ID Application** identity, with matching `SMAuthorizedClients` (helper)
and `SMPrivilegedExecutables` (app) bundle-id+designated-requirement pairs, and notarized. The
current release pipeline is ad-hoc / notarize-only-when-secrets-present. So I can write and wire
**all** the helper code, XPC protocol, SMC-write logic, and UI — but it will be **inert until
signed with the project's Developer ID**, which needs the Apple Developer account. Additionally:
fan manual-override via SMC (`FS! `, `F{n}Tg`) is **unreliable-to-unsupported on Apple Silicon**
firmware, so Auto/Cool/Max may be a no-op on exactly the hardware most users run. Helper writes
get a mandatory **auto-revert-to-Auto timer** + rpm clamped to the SMC-reported `F{n}Mn..F{n}Mx`
range, and a per-action root confirm for daemon disable. This track ships LAST, behind the safe
wins, and stays feature-flagged off until signing is sorted.

## PR sequence (each independently shippable + verified `xcodebuild`)

### PR-A · Clean & results  ✅ DONE (`d3c2beb`, `0dd3368`)
- [x] **Analyze first-open progress** — cap 40→200 + bounded-concurrent per-child walk.
- [x] **Unified View Log** — `rawLog` threaded through `OperationFlow`; shared
      `ViewLogDisclosure` demotes the transcript below the structured report (Clean/Optimize).
- [x] **Purge/Installer result screens** — status bar + DoneBanner + demoted View Log,
      replacing the raw `resultText` dump.
- [ ] **System busy badge (honest)** — DEFERRED: needs prior-run per-path failure feedback
      (mo doesn't reliably emit per-path busy); not faking it with a static deny-list. Revisit.

### PR-B · Merge Clean (decision 3)  ✅ DONE (`c9fb712`)
- [x] `Tool.navOrder` drops `.purge`/`.installer` (cases kept); new `CleanHub` with three
      category cards switching among CleanView / MoInteractiveView(.purge/.installer), all
      kept mounted. RootView coerces stray purge/installer panes → clean; Explain deep-links
      retargeted to Clean.

### PR-C · Updates & self-update (decisions 1 & 2)  ✅ DONE (`ad4b9e9`)
- [x] **Auto-surface** — `UpdatesModel.autoSurface()` auto-runs brew on Updates open; list
      shows brew/available without the manual check; live third-party stays click-gated.
- [ ] **Brew streaming** — DEFERRED (polish, not a user ask): brew upgrade still uses the
      blocking capture, not OperationFlow streaming.
- [x] **Self-update** — `AppUpdate` (GitHub GET, semver, default-on, launch + ~daily); top
      in-window banner + menu-bar dot; Settings About auto-check toggle + Check/About buttons;
      SECURITY.md documents the GitHub egress.

### PR-D · Camera/mic privacy indicators (opt-in)  ✅ DONE (`b35b258`)
- [x] `CameraMicSensor` (CoreMediaIO/CoreAudio `DeviceIsRunningSomewhere`, passive, no TCC);
      `Store.cameraMicIndicatorEnabled` (default false); popover only-when-active "in use"
      chip; honest neutral label; Settings → Menu bar toggle.

### PR-E · Tune-Up run-all — ⛔ REVERTED, deferred to a later release (issue #77)
- First cut (`47ec979`) reverted: state didn't persist across sheet close/reopen, it was a
  popup not a pane, and it only sequenced Clean+Optimize. The real design (persistent pane that
  auto-flags apps to uninstall/update, brew updates, startup to review, big disks, then one-tap
  runs the safe set) is tracked in https://github.com/caezium/Burrow/issues/77.

### PR-F · Startup user-level disable (safe subset of decision 4)  ✅ DONE (`6ee0da4`)
- [x] `controllable` = user-scope, non-bundled, healthy; real Toggle via `StartupControl`
      (launchctl bootout/disable + enable/bootstrap in gui/$UID, reversible, no admin);
      disabled state read from `print-disabled`. System/bundled stay review-only.

### PR-G · Privileged helper (decision 4 "do it all") — BACKLOGGED 2026-06-14
> User decision 2026-06-14: backlog the privileged-helper track entirely; ship only the
> non-privileged PRs (A–F). Fan Auto/Cool/Max, system-daemon disable, and root purgeable
> reclaim wait for a future signing-enabled effort. Startup disable ships USER-scope only (F);
> Tune-Up ships Clean+Optimize only (E), no purgeable step.
- [ ] `SMAppService.daemon` target + launchd plist + XPC protocol + entitlements
      (`SMPrivilegedExecutables`/`SMAuthorizedClients`).
- [ ] Helper: SMC fan write (`FS!`/`F{n}Md`/`F{n}Tg`) with rpm clamp + auto-revert timer;
      `/bin/launchctl` system-daemon disable behind per-action root confirm + deny-list;
      `/usr/sbin/tmutil thinlocalsnapshots` purgeable reclaim.
- [ ] App-side client + Status/Popover fan controls (Auto/Cool/Max) + Optimize purgeable task.
- [ ] Release pipeline: Developer ID Application signing for the helper. **Needs the Apple
      Developer account — inert until then.**

## Standing rules
mo stays authoritative for clean/uninstall (helper only adds fan/launchctl/tmutil, never
deletes user files); honest verbs + no fake affordances; zh-Hans + accessibility per PR;
keep SECURITY.md/TELEMETRY.md truthful on any new egress (PR-C self-update).
