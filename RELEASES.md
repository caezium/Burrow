<!-- Latest release ONLY. This file is the GitHub release body (release.yml --notes-file), so it must contain just the newest version. OVERWRITE it each release; do not accumulate. Full prose history lives in docs/releases.json → docs/releases.html (the site Releases page). -->

# Burrow 0.11.1

A guarded-startup and diagnostics patch for the system-wide input freeze
reported on macOS 27 Beta 4. This release reduces the risky launch surface on
the affected build and records enough redacted state to isolate any remaining
failure without collecting screen contents or user files.

> **Affected macOS 27 beta users:** please install 0.11.1 and report the result
> in [#319](https://github.com/caezium/Burrow/issues/319). The issue remains open
> until the notarized release is verified on a Mac that reproduced the freeze.

## Fixed
- **The affected macOS 27 beta gets a safer launch path.** On Beta 4 build
  `26A5388g`, Burrow starts with a Dock icon instead of creating its menu-bar
  status item. The fallback is deliberately limited to that exact build and is
  retried after either Burrow or macOS changes. Manual update checks remain
  available even when automatic Sparkle startup is paused.
- **Interrupted launches recover one component at a time.** A durable launch
  journal gives the status item and Sparkle separate 30-second stability
  windows. If launch is interrupted, the next run suppresses only the component
  whose window was active, shows a recovery alert, and offers a one-click
  redacted diagnostic report. ([#321](https://github.com/caezium/Burrow/pull/321))

## Improved
- **Sentry can now explain hangs that never become crashes.** Release-health
  sessions, hang tracking, low-memory context, fixed-name sampled performance
  spans, and coarse launch/updater state cover the failure modes that a normal
  crash report misses. Outbound data is scrubbed fail closed, with no
  screenshots, view hierarchies, user paths, URLs, request bodies, or automatic
  UI, file, database, and network tracing.
- **PostHog analytics no longer bring an AppKit-facing SDK into startup.** Burrow
  still sends the same opt-out semantic product, screen, and operation events to
  PostHog, but a small background HTTPS transport replaces `posthog-ios`. It has
  a bounded serialized retry queue and no session replay, autocapture, remote
  feature flags, AppKit timer, or main-thread disk I/O. Existing 0.11.0 anonymous
  identities are migrated once so release-to-release funnels remain accurate.
- **The first signed Sparkle successor is ready to test.** This is the first
  update after 0.11.0, so it exercises the complete signed in-app update path
  tracked in [#281](https://github.com/caezium/Burrow/issues/281). The issue stays
  open until a real 0.11.0-to-0.11.1 update succeeds.

## Privacy
- **Telemetry remains optional, unlinked, and non-tracking.** One Settings
  switch disables both PostHog analytics and Sentry diagnostics. The privacy
  manifest continues to declare Product Interaction, Other Usage, Crash,
  Performance, and Other Diagnostic data; this release adds no signing-specific
  telemetry and records no screen content.

## Security
- **The release chain remains fail closed.** The tag cannot publish unless the
  app is Developer ID signed, notarized, stapled, accepted by Gatekeeper, and
  both the update archive and appcast pass Sparkle signature verification.
