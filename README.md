# BurrowWin

BurrowWin is the Windows branch candidate for Burrow: a native WinUI 3 desktop shell for the Mole CLI (`mo`). It follows Burrow's product shape: a GUI-first system utility for status, cleanup, purge, installer cleanup, optimize, app management, disk analysis, history, activity, tray HUD, and local MCP/HTTP access for AI agents.

This branch intentionally maps only the safe Windows capabilities that exist in Mole today. When Mole Windows lacks a non-interactive JSON contract, BurrowWin uses a narrow Windows fallback and documents that boundary instead of pretending to be feature-complete with the macOS engine.

## Current Status

- Target framework: `.NET 8`, WinUI 3, Windows App SDK.
- Primary engine: bundled `Assets\Mole\mo.exe` shim or compatible Mole Windows script layout.
- Local agent surface: loopback HTTP on `127.0.0.1:9277` plus stdio MCP bridge.
- Recommended install path: WinGet package `Caezium.Burrow`.
- Release format: unsigned Inno Setup installer plus portable ZIP fallback, both with SHA256 checksums.
- Default release version: `v0.1.0-preview.1`.

See [BURROW_WINDOWS_ALIGNMENT.md](BURROW_WINDOWS_ALIGNMENT.md) for the current Windows adaptation map and known gaps.

## Install

The Windows branch follows Burrow's upstream install rhythm: package manager first, direct download as a fallback.

Recommended install after the WinGet manifest is published:

```powershell
winget install --id Caezium.Burrow -e
```

Before the preview is accepted into the community WinGet repository, build a release locally and test the generated manifest:

```powershell
.\scripts\build-release.ps1
winget install --manifest .\artifacts\release\winget\Caezium\Burrow\0.1.0-preview.1
```

Direct download fallback:

- `Burrow-v0.1.0-preview.1-win-x64-setup.exe`
- `Burrow-v0.1.0-preview.1-win-x64.zip`
- `SHA256SUMS.txt`

The preview is unsigned. Windows SmartScreen may warn on first launch, and stricter enterprise Application Control policies can block the unsigned setup executable. Verify the SHA256 checksum before running direct downloads. WinGet installs the .NET Desktop Runtime dependency; direct downloads may require .NET Desktop Runtime 8 if it is not already installed.

## Requirements

- Windows 10 1809 or newer, Windows 11 recommended.
- .NET Desktop Runtime 8.0 for running direct downloads.
- .NET SDK 8.0 for development.
- PowerShell 5.1 or newer.
- Windows App SDK dependencies are restored through NuGet during build.

## Develop

```powershell
dotnet restore .\BurrowWin.sln
dotnet build .\BurrowWin.csproj -p:Platform=x64 -nr:false -v:minimal
dotnet build .\Tests\BurrowWin.Tests\BurrowWin.Tests.csproj -nr:false -v:minimal
dotnet test .\Tests\BurrowWin.Tests\BurrowWin.Tests.csproj --no-build -v:minimal
```

Run the local GUI smoke test:

```powershell
.\run-local.ps1 -NoBuild -SmokeTest -Restart -RequireHealth -Route settings -TimeoutSeconds 60
.\run-local.ps1 -NoBuild -SmokeTest -Restart -RequireHealth -Route optimize -OptimizeAutoScan -TimeoutSeconds 120
```

For visual regression evidence, add `-ScreenshotPath`:

```powershell
.\run-local.ps1 -NoBuild -SmokeTest -Restart -RequireHealth -Route history -ScreenshotPath artifacts\ui-smoke\burrowwin-history.png -TimeoutSeconds 60
```

## Release

Build the unsigned installer, portable ZIP fallback, checksums, and WinGet manifest:

```powershell
.\scripts\build-release.ps1
```

The script repeats build/test/publish, writes the payload to `artifacts\release\Burrow-v0.1.0-preview.1-win-x64\`, creates `Burrow-v0.1.0-preview.1-win-x64-setup.exe`, creates `Burrow-v0.1.0-preview.1-win-x64.zip`, writes `SHA256SUMS.txt`, generates release notes, and writes WinGet manifests under `artifacts\release\winget\`.

The first preview installer and ZIP are unsigned. Windows may show a trust warning on first launch, and Application Control policies can block the unsigned setup executable. Verify hashes before running direct downloads.

## Security Model

BurrowWin binds HTTP only to loopback, keeps destructive MCP tools disabled by default, and requires explicit confirmation for real maintenance actions. Preview-first workflows are the expected default. See [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).
