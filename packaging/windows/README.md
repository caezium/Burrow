# Windows Packaging

Burrow Windows follows the upstream Burrow install rhythm: package manager first, direct download as a fallback.

## Artifacts

Release tooling writes:

- installer: `artifacts\release\Burrow-v0.1.0-preview.1-win-x64-setup.exe`
- portable ZIP fallback: `artifacts\release\Burrow-v0.1.0-preview.1-win-x64.zip`
- checksum file: `artifacts\release\SHA256SUMS.txt`
- release notes: `artifacts\release\RELEASE_NOTES.md`
- WinGet manifests: `artifacts\release\winget\Caezium\Burrow\0.1.0-preview.1\`

The installer is built from `Burrow.iss` with Inno Setup. It installs per-user to `%LOCALAPPDATA%\Programs\Burrow`, creates a Start Menu shortcut named `Burrow`, and points that shortcut at the internal `BurrowWin.exe`.

## WinGet

The generated manifest targets:

- PackageIdentifier: `Caezium.Burrow`
- PackageName: `Burrow`
- InstallerType: `inno`
- Scope: `user`
- Architecture: `x64`

Validate locally with:

```powershell
winget validate .\artifacts\release\winget\Caezium\Burrow\0.1.0-preview.1
```

## Signing

No code signing is performed for `v0.1.0-preview.1`. Users should verify SHA256 and expect Windows SmartScreen reputation prompts for direct downloads. Stricter Application Control policies can block the unsigned setup executable until a signed release is available.
