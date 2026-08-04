<!-- Latest release ONLY. This file is the GitHub release body (release.yml --notes-file), so it must contain just the newest version. OVERWRITE it each release; do not accumulate. Full prose history lives in docs/releases.json → docs/releases.html (the site Releases page). -->

# Burrow 0.11.2

A system-metrics, updater, and launch-reliability patch. This release corrects
CPU sampling, stops expected Sparkle conditions from looking like product
defects, gives AppKit a settled launch turn before creating the menu-bar item,
and makes sampled app hangs reliably reach the issue tracker.

> **Affected macOS 27 beta users:** please install 0.11.2 and report the result
> in [#319](https://github.com/caezium/Burrow/issues/319). The exact Beta 4
> compatibility guard remains in place, and the issue stays open until a
> notarized build is verified on a Mac that reproduced the freeze.

## Fixed
- **CPU usage now reflects a representative sampling interval.** The bundled
  engine keeps a tick baseline across refreshes, samples before the other
  collectors fan out, and derives total usage from summed tick deltas. This
  removes the roughly doubled readings and coarse per-core fractions reported in
  [#335](https://github.com/caezium/Burrow/issues/335). A cold one-shot status
  command can take about 600 ms longer; ongoing GUI sampling reuses its existing
  refresh interval and adds no wait. ([#340](https://github.com/caezium/Burrow/pull/340))
- **Updater failures now mean what they say.** Running from a disk image or a
  translocated location, ordinary network failures, and user cancellation remain
  measurable in PostHog without opening Sentry issues. Sparkle keeps ownership of
  its native move-to-Applications and scheduled-retry UI. Configuration,
  signature, installation, and unknown failures still create exactly one
  scrubbed Sentry diagnostic per cycle. ([#339](https://github.com/caezium/Burrow/pull/339))
- **The normal menu-bar path no longer races the first AppKit launch turn.**
  Burrow waits one second before creating its status item, then retains the
  existing 30-second stability window. The safeguard for macOS 27 Beta 4 build
  `26A5388g` remains exact-build-only; a later macOS build returns to the normal
  guarded path automatically. ([#339](https://github.com/caezium/Burrow/pull/339))

## Improved
- **App-hang evidence can no longer disappear at the Sentry bridge.** Sampled
  hangs are collected into bounded weekly GitHub digests instead of being
  silently skipped. Cursor pagination reaches older unseen groups, full digests
  roll into numbered parts, and deferred groups remain eligible for the next
  run. ([#339](https://github.com/caezium/Burrow/pull/339))
- **Launch and updater health now have explicit lifecycle outcomes.** Fixed-name
  scheduled, stabilizing, and stable milestones include bounded app release,
  macOS build, launch phase, and status-item state, so future failures can be
  separated without collecting free text or user data.

## Privacy
- **Telemetry remains optional, unlinked, and non-tracking.** One Settings
  switch disables both PostHog analytics and Sentry diagnostics. Updater
  diagnostics contain fixed categories and bounded error domains/codes—never
  descriptions, URLs, response bodies, network names, paths, screen content, or
  files. The privacy manifest remains unchanged and accurate.

## Security
- **Publishing still fails closed, including the external Homebrew tap.** Before
  any release build begins, CI requires every signing, notarization, Sparkle,
  and tap credential, then proves the tap token with a reversible Git
  write. The tap credential is isolated from the engine checkout so a successful
  notarized release cannot fail at the final cask push because the wrong token
  was left in Git configuration.
