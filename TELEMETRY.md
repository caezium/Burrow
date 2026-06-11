# Burrow telemetry

Burrow collects **anonymous, opt-out** product analytics and crash reports so we
can see how many installs stay active, which versions to support, which features
get used, and when something breaks. This file is the exact, honest list of
what that means. The privacy summary lives in [SECURITY.md](SECURITY.md); this
is the detail.

## What and who

| Concern | SDK | Host (default) |
|---|---|---|
| Product analytics | [PostHog](https://posthog.com) | `us.i.posthog.com` |
| Crash / error reporting | [Sentry](https://sentry.io) | `*.ingest.us.sentry.io` (from the release DSN) |

Client code: [`Sources/Telemetry.swift`](Sources/Telemetry.swift) (PostHog) and
[`Sources/CrashReporter.swift`](Sources/CrashReporter.swift) (Sentry).

Unlike PostHog's fixed host, Sentry has no separate host setting — the ingest
endpoint is encoded in the **DSN injected at release time**. For official
builds that's the maintainer's Sentry project; a fork built with its own DSN
reports to its own project instead.

## Ground rules (enforced in code, not just promised)

- **Opt-out, on by default.** One switch — **Settings → Anonymous usage** —
  gates both SDKs (`Store.telemetryEnabled`). Off → PostHog is hard-muted
  (`config.optOut`) and Sentry is `close()`d.
- **Inert without keys.** The PostHog key and Sentry DSN are injected only at
  release time (Info.plist `PHPostHogApiKey` / `SentryDSN`, from build
  settings). A build from this repo ships them empty and touches neither
  network. See `scripts/release.env.example`.
- **Identity is random.** PostHog's own distinct id plus Sentry's own install
  id (two ids total) — neither derived from serial, MAC, hardware, or
  account. Opting out stops all sending but leaves the SDKs' local caches
  (ids, any queued events) on disk; deleting the app's Application Support
  and Caches folders removes them.
- **No PII, ever.** `sanitize()` drops sensitive keys (paths, file names,
  contents, urls, tokens, email, username, …) and only lets primitives through.
- **Sizes/counts/durations are bucketed**, never raw — see `bytesBucket`,
  `countBucket`, `secondsBucket`. E.g. `120MB → "100MB-1GB"`, `7 items → "1-9"`.

## Super properties (attached to every event)

`app_version`, `build_number`, `os_version` (e.g. `macOS 26.5.0`), `arch`
(`arm64` / `x86_64`), `locale`.

**Plus what the PostHog SDK attaches on its own** (its standard `$` context
properties): device model (e.g. `Mac14,9`), device marketing name (e.g.
`MacBook Pro` — not your hostname), bundle id, OS name/version, locale,
timezone, screen size, app version/build. No feature-flag preloading
(`preloadFeatureFlags = false`), so the only endpoint hit is event delivery.

**IP address:** as with any HTTPS request, the TCP connection still exposes
your IP to the receiving service at the network layer — but neither SDK
*stores* it. PostHog events carry `$ip = "0"`, so PostHog records no IP and
derives no GeoIP; the project additionally has **"Discard client IP data"**
enabled (defence in depth). Sentry runs with `sendDefaultPii = false`, so no
IP is attached to events either.

## Events

### Wired now
| Event | Props | Source |
|---|---|---|
| `app_opened` | `cold_start: bool` | `Telemetry.start()` |
| `app_terminated` | — | `AppDelegate.applicationWillTerminate` |
| `engine_missing` | — (launched without the `mo` CLI; an activation signal) | `AppDelegate` |
| `telemetry_opt_in_changed` | `enabled: bool` | `Telemetry.setEnabled` |

Plus whatever crashes/unhandled errors Sentry captures automatically (no
screenshots, no performance traces, `sendDefaultPii = false`). Sentry's
auto session tracking is **off** — there is no per-launch "release health"
ping; Sentry traffic happens only when something actually crashed or
errored. Crash reports carry the loaded binaries' file paths; Burrow scrubs
`/Users/<name>` from them before upload (`CrashReporter.scrubUserPaths`).

### Planned (not yet wired — listed so this doc stays the source of truth)
| Event | Props (all bucketed / non-PII) | Where it'll live |
|---|---|---|
| `screen_viewed` | `pane: home\|history\|cleanup\|analyze\|software\|settings\|tool` | `RootView` |
| `clean_performed` | `reclaimed_bucket`, `item_count_bucket`, `dry_run: bool` | `OperationCenter` |
| `purge_performed` | `reclaimed_bucket`, `category` | `OperationCenter` |
| `uninstall_performed` | `item_count_bucket` | `OperationCenter` |
| `analyze_run` / `optimize_run` | `duration_bucket` | respective views |
| `fda_state` | `granted: bool` | Privacy gate |
| `mcp_tool_invoked` | `tool: <burrow_*>` (agent-native usage signal) | `MCP.swift` — needs SDK init + per-call flush in the stdio subprocess; deferred for that reason |

When you wire one, move its row up and keep the props bucketed.

## Turning it off

Settings → **Anonymous usage** → off. Both SDKs stop immediately (PostHog sends
one final `telemetry_opt_in_changed`, flushes, then mutes; Sentry closes).
The SDKs' local files — the two random ids and any not-yet-sent queue — stay
on disk so a later re-enable reuses the same anonymous identity; nothing is
transmitted while opted out. There is no server-side deletion call.
