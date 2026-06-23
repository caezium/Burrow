# Security & trust

Burrow is a GUI that drives the [`mo` (Mole)](https://github.com/tw93/Mole)
CLI. It is pre-1.0 and **not yet signed with a Developer ID** — this page is the honest
account of what it does, what touches the network, and how it handles
admin rights, so you can decide before you run it. The actual
cleaning/scanning is done by `mo` (MIT, © tw93); audit that too.

## Code signing

macOS release builds are **ad-hoc signed**: the signature is cryptographically
valid (`codesign --verify --strict` passes), but it carries no Developer ID, so
the build is **not notarized** and its identity changes on every build.
Practically:

- Gatekeeper still shows the "unidentified developer" prompt on first launch.
  Install via the Homebrew cask (it strips the quarantine flag for you), or run
  `xattr -cr /Applications/Burrow.app` after copying the app.
- Because the identity is per-build, a permission you grant (e.g. Full Disk
  Access) has to be re-granted after each update.

A stable **Developer ID** signature — which fixes both points — is the planned
next step. Code signing is a real security mechanism (a cryptographic identity
macOS can rely on), not a formality.

If you're not comfortable running a non-notarized app that can ask for admin
rights, build it yourself from source.

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
- **Honest caveat:** that elevation runs your Homebrew-installed `mo` as
  root. On a default Apple-Silicon Homebrew, `/opt/homebrew` is
  user-writable, so treat `mo` like any binary you'd `sudo` — only as
  trustworthy as your Homebrew install. If your threat model is strict,
  review `mo` and the elevation path before granting admin, or skip the
  admin-only system caches (Burrow runs fine without them).

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
  [`Sources/Telemetry.swift`](Sources/Telemetry.swift) and
  [`Sources/CrashReporter.swift`](Sources/CrashReporter.swift). Both SDKs are
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
  - **Burrow self-update check:** when "Check for updates automatically"
    is on (Settings → About, on by default), Burrow makes one unauthenticated
    GET to the GitHub Releases API on launch and about once a day to see if a
    newer Burrow exists. It reads a version tag; it sends nothing about you,
    and never installs anything — a found update only shows a banner. Turn the
    toggle off to make the check fully manual (the menu/Settings button still
    works).
  - The Software → **Updates** tab runs `brew outdated`, which contacts
    Homebrew's update feeds — the same check `brew` does for itself. It reads
    version info; it sends nothing about you. App version checks (Sparkle
    appcasts, App Store lookups) still happen only when you click "Check for
    updates".
  - **Settings → Update Mole** runs `mo update` (Mole's own self-update
    traffic), only when you click it.
  - The optional **AI "Explain" lens** (off by default) talks to
    `127.0.0.1` (Ollama / LM Studio). If you configure a hosted
    OpenAI-compatible endpoint instead, the metrics summary being explained
    is sent to that endpoint with your API key.

## Reporting a vulnerability

Open a [GitHub issue](https://github.com/caezium/Burrow/issues) or a
private security advisory on the repo. Because Burrow can run privileged
cleanup, security reports are taken seriously — please include the file and
line if you can.
