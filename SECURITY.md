# Security & trust

Burrow is a GUI that ships its own MIT engine, a fork of the
[`mo` (Mole)](https://github.com/tw93/Mole) CLI. Starting with 0.11.0, official
releases must pass Developer ID signing and Apple notarization before they can
publish. This page is the honest account of what
the app does, what touches the network, and how it handles admin rights, so you
can decide before you run it. The actual cleaning/scanning is done by that
bundled engine (MIT, © tw93 for the original); audit it too.

## Code signing

The tag-release workflow fails closed unless it can sign the app and every
bundled executable with a **Developer ID Application** certificate, enable the
hardened runtime, obtain secure timestamps, receive an accepted notarization
result, staple the ticket, and pass Gatekeeper assessment. The external
Homebrew cask is updated only after that verified artifact exists, and its live
0.11.0 definition preserves quarantine so Gatekeeper can verify the stapled
ticket. Maintainer setup and release verification are in the [macOS signing
runbook](docs/macos-signing.md).

The published 0.11.0 app was independently checked after download: its bundle
identifier is `dev.caezium.Burrow`, its Developer ID Team ID is `YGSM2722TZ`,
the hardened runtime and secure timestamp are present, `stapler validate`
succeeds, and Gatekeeper reports `source=Notarized Developer ID`.

The release also embeds Sparkle 2.9.4 with a checked-in Ed25519 public key.
After notarization, CI signs the update ZIP and `appcast.xml`, verifies both
signatures and the private/public key match, and keeps a new GitHub release in
draft until both assets exist. Sparkle verifies the signed feed and archive
again on the Mac before installing.

Version 0.11.0 is the first Sparkle-enabled release, so it proves the signed
feed, archive, and updater integration but cannot yet prove an upgrade to a
newer build. Issue [#281](https://github.com/caezium/Burrow/issues/281) remains
open until the first 0.11-to-successor update completes on a shipped app.

Burrow 0.10.5 predates this release gate and used a coherent ad-hoc signature,
not Developer ID or notarization; its Homebrew cask used a quarantine bypass.
Older archives also predate the current distribution guarantee. Locally built
copies still use an ad-hoc signature so macOS can bind Full Disk Access to a
coherent development identity, but that is not a substitute for Developer ID
or notarization and changes between builds.

## Privileged (admin) operations — no background helper

This is the part people rightly scrutinize in cleaners. Burrow's model:

- **Burrow installs no privileged/background helper and no XPC root
  service.** There is nothing persistently running as root and nothing for
  another local process to connect to.
- When **Clean** or **Optimize** needs admin rights, **macOS's own
  authorization dialog** asks for your password, and Burrow runs the
  matching `mo` command for that single action, then exits. You see and
  approve every elevation. (See `CommandRunner.runElevated` in
  `macos/Sources/TaskReport.swift`.)
- **Honest caveat:** official builds elevate the engine sealed inside the
  Developer ID signed app. A source build can fall back to an external `mo`;
  if it does, that executable is only as trustworthy as its install location
  (Homebrew prefixes are normally user-writable). Review the engine and the
  elevation path before granting admin, or skip the admin-only system caches.

## Network & privacy

- **No account, no sign-in, no ads, no "upgrade to Pro."** Your metrics,
  history, and file contents stay on the Mac — with one opt-in exception:
  pointing the optional AI "Explain" lens at a **hosted** endpoint sends the
  metrics fact sheet you're explaining to that endpoint (it's off by default
  and local-first; see below).
- **Anonymous analytics + crash reporting (opt-out).** Burrow uses
  [PostHog](https://posthog.com) for product analytics and
  [Sentry](https://sentry.io) for crash/error reports, so we can see how many
  installs stay active, which versions to support, which features get used,
  and when something crashes. **What's sent:** a random install id per SDK
  (two ids, minted by the SDKs, not derived from your hardware, serial, or
  account), the app + macOS version, CPU architecture, device model, locale,
  and coarse feature-usage events with sizes and counts **bucketed into
  ranges**. **What's never sent:** file names, file contents, paths (crash
  reports scrub `/Users/<name>`), your home folder, your metrics/history, or
  any account identity. **Your IP isn't stored**, either — PostHog events
  carry `$ip = "0"` (and the project discards client IPs), and Sentry sets
  `sendDefaultPii = false`. It's **on by default**; turn it off in **Settings → Anonymous
  usage** and both PostHog and Sentry stop. The exact event list is in
  **[TELEMETRY.md](TELEMETRY.md)**; the client code is
  [`macos/Sources/Telemetry.swift`](macos/Sources/Telemetry.swift) and
  [`macos/Sources/CrashReporter.swift`](macos/Sources/CrashReporter.swift). Both SDKs are
  **inert in source/dev builds** — keys are injected only at release time, so
  a build from this repo phones neither home. The **Windows app** does the same
  thing (opt-out via **Settings → Share crash reports & analytics**) — its own
  separate Sentry project, and the **shared** macOS PostHog project tagged
  `platform: "windows"`; client code is
  [`windows/Services/AppTelemetry.cs`](windows/Services/AppTelemetry.cs), keys
  injected via `BURROWWIN_SENTRY_DSN` / `BURROWWIN_POSTHOG_API_KEY` — see
  **[TELEMETRY.md](TELEMETRY.md)**.
- **Local-only surfaces:**
  - The MCP **HTTP query server** binds `127.0.0.1:9277` (loopback only; **on
    by default**). It serves your local metrics to local MCP clients; it is not
    reachable off-device, and it sends no CORS grant, so web pages in your
    browser can't read it either. In the Windows preview, the Settings toggle
    disables REST endpoints but keeps the loopback `/mcp` route bound so the
    stdio bridge can continue to work.
  - The **stdio MCP server** (`Burrow --mcp`) is a local subprocess.
  - History is a local **SQLite** file under
    `~/Library/Application Support/Burrow/`.
- **Other outbound paths:**
  - **Burrow self-update check:** when "Check for updates automatically" is on
    (Settings → About, on by default), Sparkle makes an unauthenticated GET to
    the signed `appcast.xml` GitHub Release asset on launch and about once a
    day. It sends no Burrow analytics or device profile. If an update exists,
    Sparkle presents its native UI and waits for approval before downloading
    or installing it. Turn the toggle off to make checks fully manual; the
    menu and Settings buttons still work.
  - The Software → **Updates** tab runs `brew outdated`, which contacts
    Homebrew's update feeds — the same check `brew` does for itself. It reads
    version info; it sends nothing about you. App version checks (Sparkle
    appcasts, App Store lookups) still happen only when you click "Check for
    updates".
  - The engine inside `Burrow.app` never self-updates because changing a file
    inside the bundle would invalidate its Developer ID seal. It updates only
    with a signed Burrow release. Source builds using an external engine keep
    a user-initiated engine updater in Settings.
  - The optional **AI "Explain" lens** (off by default) talks to
    `127.0.0.1` (Ollama / LM Studio). If you configure a hosted
    OpenAI-compatible endpoint instead, the metrics summary being explained
    is sent to that endpoint with your API key.

## Reporting a vulnerability

Open a [GitHub issue](https://github.com/caezium/Burrow/issues) or a
private security advisory on the repo. Because Burrow can run privileged
cleanup, security reports are taken seriously — please include the file and
line if you can.
