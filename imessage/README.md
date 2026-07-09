# Burrow Cards — iMessage extension

Native iMessage cards for Burrow alerts, described by JSON, rendered on-device by a signed SwiftUI renderer.

The [alert sidecar](../tools/burrow-alerts) (or any agent) emits a **BurrowLayout** JSON document per message; this fixed, Apple-signed extension draws it as native SwiftUI. The JSON describes *what* to show (a disk gauge, a free-space row, a "clean" button) — it never executes code. Sent over Photon `customizedMiniApp()`, base64url-encoded in the message URL as `?p=<payload>`.

> **Why not just send SwiftUI from the server?** Apple doesn't let apps run downloaded UI code. So we ship a fixed renderer and send declarative JSON that selects from a known vocabulary — the [Scriptable](https://scriptable.app)/[HermesShare](https://github.com/time-attack/HermesShare) model. App Store legal, no web views, no eval.

## Status

This is an early scaffold. The **wire format is locked and tested** on both sides:

| Piece | State |
|---|---|
| `tools/burrow-alerts/src/burrowlayout.ts` | ✅ schema + `?p=` transport, unit-tested (round-trip) |
| `Shared/Sources/BurrowCards/BurrowLayout.swift` | ✅ matching Codable schema + base64url decoder |
| `Shared/Sources/BurrowCards/BurrowLayoutRenderer.swift` | ⬜ JSON tree → SwiftUI |
| `BurrowCardsExtension/` (MSMessagesAppViewController) | ⬜ decode `?p=` → render |
| `BurrowCardsHost/` (host app + debug harness) | ⬜ |
| `project.yml` (xcodegen) | ⬜ |

The Swift schema is written to match the TS round-trip test byte-for-byte — change one side, change both.

## Reality check

- **iOS-only.** iMessage app extensions don't run in macOS Messages. You receive cards on your iPhone.
- **Requires the extension installed on the *receiving* device.** Without it, the message falls back to a standard bubble (thumbnail + caption). The sidecar already sends a text fallback for everyone else — cards are a per-device upgrade, not a hard dependency.
- iOS 26+ / Xcode 26+.

## Build & sideload (your own iPhone)

```bash
brew install xcodegen
cd imessage
xcodegen generate          # once project.yml lands
open BurrowCards.xcodeproj
```

Set your Apple **Team ID** in `project.yml` (`DEVELOPMENT_TEAM`) or Xcode → Signing & Capabilities (both the host app and the extension). A free Apple account works for sideloading to your own device. Build/run the host app to your iPhone; the extension installs with it. Then in Messages → `+` → Burrow Cards.

## Wiring the sidecar

Point `tools/burrow-alerts` at this extension:

```jsonc
// config.local.json
"card": {
  "appName": "Burrow",
  "extensionBundleId": "dev.caezium.Burrow.imessage",
  "teamId": "<your Apple Team ID>",
  "url": "https://burrow.henryzh.dev/card"   // base; sidecar appends ?p=<layout>
}
```

The sidecar builds a `BurrowLayout` (`src/burrowlayout.ts`), base64url-encodes it into the `url` as `?p=`, and sends via `customizedMiniApp`. `bun run check:card` fires a sample.

## Schema

`BurrowLayout` = `{ version, title, subtitle?, accentColorHex?, root, actions? }`. `root` is a recursive `BurrowNode`:

`vstack` · `hstack` · `section` · `text` · `statusBadge` · `progressBar` · `gauge` · `keyValueRow`

Actions are `{ id, label, systemImage?, deepLinkURL }` — `burrow://action?id=…` buttons that insert a reply into the thread.

## Acknowledgments

Node vocabulary and the "declarative JSON → signed native renderer" approach are derived from [**HermesShare**](https://github.com/time-attack/HermesShare) (MIT). Burrow Cards trims the schema to system-health alerts and re-brands the transport/deep-link scheme.
