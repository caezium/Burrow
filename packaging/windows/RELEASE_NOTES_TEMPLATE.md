# Burrow v0.1.0-preview.1

This is the first Windows branch preview package for Burrow.

## Install

Recommended install after the WinGet manifest is published:

```powershell
winget install --id Caezium.Burrow -e
```

Direct download fallback:

- `Burrow-v0.1.0-preview.1-win-x64-setup.exe`
- `Burrow-v0.1.0-preview.1-win-x64.zip`
- `SHA256SUMS.txt`

This preview is unsigned. Verify SHA256 before running direct downloads and expect Windows SmartScreen reputation prompts. Stricter Application Control policies can block the unsigned setup executable until a signed release is available.

## Included

- Native WinUI Burrow-style shell.
- Mole-backed clean and optimize preview flows.
- Windows fallbacks for current Mole Windows interactive gaps.
- Local operation history and telemetry history.
- Loopback HTTP and stdio MCP agent surfaces.
- Tray HUD and status menu.

## Verification

- App build: required.
- Test suite: required.
- Local GUI smoke: required before publishing.
- Installer and ZIP SHA256: recorded in `SHA256SUMS.txt`.
- WinGet manifest: generated under `artifacts\release\winget\`.

## Known Preview Limits

See `BURROW_WINDOWS_ALIGNMENT.md` and `MOLE_WINDOWS_GAP.md`.
