# Burrow 0.8.2

A fix release: a Full Disk Access grant now actually takes effect, and Burrow
asks for notification permission up front instead of mid-alert. Still
local-first.

## Fixed
- **Full Disk Access is honored again.** The shipped app's embedded framework
  signatures were malformed (`codesign --verify --strict` failed on
  `Sentry.framework`), so macOS couldn't validate Burrow's identity and silently
  ignored a Full Disk Access grant — turning it on in System Settings appeared to
  do nothing. The release now re-signs the app and every nested framework
  inside-out so the signature is valid and the grant takes effect. After
  updating, toggle Full Disk Access off and back on once. (Burrow is still
  ad-hoc-signed, so a re-grant is needed after each update until it ships with a
  Developer ID signature.) (#177)

## Changed
- **Notification permission is requested up front.** Burrow now asks once — when
  you finish onboarding or first enable a notifying feature — instead of
  springing the system prompt the moment a notification tries to fire.

# Burrow 0.8.1

A stability release: the live dashboard no longer freezes, live status now
streams, and there's a one-click Homebrew update button — plus the Windows
preview catches up on its code review. Still local-first.

## Fixed
- **No more "App Hanging" freezes.** The Overview dashboard used to re-render
  its whole grid — every chart tile and the full process table — once a second;
  now only the small Disk / Network tiles update that often, the rest on the
  snapshot. Opening **Settings** and the **About** panel no longer blocks the
  main thread either (login-item status, metrics-folder sizing, and the
  engine-version lookup all moved off it), and **PostHog telemetry now flushes
  off the main thread**.

## Changed
- **Live status streams by default.** With Mole 1.44+, Burrow streams
  `mo status --watch` (newline-delimited JSON) instead of polling `mo status
  --json` — lower latency and less subprocess churn. It falls back to polling
  on older `mo` or if the stream drops, so the dashboard never stalls.

## Added
- **Update with Homebrew** — for cask installs, the update prompt now has a
  one-click button that runs `brew upgrade --cask burrow` and relaunches,
  instead of just printing the command.

## Windows preview
- Closed out the port review: **MCP tool parity with macOS**
  (`burrow_list_apps`, `burrow_purge`, `burrow_installer` — all preview-only
  over MCP), stdio MCP that survives the HTTP toggle, **brand assets / palette /
  fonts / app icon aligned to the Mac**, honest docs, and real MCP +
  deletion-guard test coverage. (Earlier review rounds added Recycle-Bin
  routing, a drive-root guard, and SHA-256 verification of the bundled engine
  binary.) Still an unsigned, build-from-source preview.
