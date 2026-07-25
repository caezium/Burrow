<!-- Latest release ONLY. This file is the GitHub release body (release.yml --notes-file), so it must contain just the newest version. OVERWRITE it each release; do not accumulate. Full prose history lives in docs/releases.json → docs/releases.html (the site Releases page). -->

# Burrow 0.10.2

A fix release. Three crashes are gone — the menu-bar popover, the streaming
task report, and a nil-font HUD metric — and the in-app updater no longer
silently reopens the same build when Homebrew won't upgrade in place.

## Fixes
- **No more menu-bar popover or streaming-report crashes.** Two `EXC_BAD_ACCESS`
  faults inside SwiftUI's view graph — one in the menu-bar popover header
  button, one in the live task report/ticker as a job streamed — are fixed by
  keeping those view subtrees structurally stable across snapshot and scroll
  updates instead of restructuring them mid-update.
  ([#299](https://github.com/caezium/Burrow/pull/299))
- **The menu-bar metric no longer crashes on a nil font.**
  `NSFont.monospacedSystemFont` is declared non-null but can transiently return
  nil under memory pressure; that null reached CoreText and crashed at draw
  time (Sentry BURROW-8Y). The metric widgets now fall back to the plain system
  font — cosmetic at worst, never a crash.
  ([#290](https://github.com/caezium/Burrow/pull/290))
- **In-app update actually updates.** When the cask "cannot be upgraded as-is,"
  Homebrew prints a warning but exits 0 — so the one-click updater reported
  success and reopened the same build. It now detects the refusal by message
  and runs the `brew reinstall --force` Homebrew recommends.
  ([#287](https://github.com/caezium/Burrow/pull/287))

