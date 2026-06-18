# Release Process

Burrow Windows preview releases follow the upstream Burrow install rhythm: package manager first, direct download as a fallback.

## Local Release

```powershell
.\scripts\build-release.ps1
```

The script:

1. restores the solution,
2. builds the app for x64,
3. builds and runs tests,
4. publishes the unpackaged WinUI app,
5. creates the unsigned Inno Setup installer,
6. creates the portable ZIP fallback,
7. writes `SHA256SUMS.txt`,
8. writes a release notes draft,
9. writes WinGet manifests for `Caezium.Burrow`.

The generated user-facing artifacts are:

- `artifacts\release\Burrow-v0.1.0-preview.1-win-x64-setup.exe`
- `artifacts\release\Burrow-v0.1.0-preview.1-win-x64.zip`
- `artifacts\release\SHA256SUMS.txt`
- `artifacts\release\winget\Caezium\Burrow\0.1.0-preview.1\`

The preview setup executable is unsigned. Windows SmartScreen may warn, and stricter Application Control policies can block installer execution until a signed release is available.

## WinGet

After publishing the GitHub Release, submit the generated manifest directory to `microsoft/winget-pkgs`.

Preview validation:

```powershell
winget validate .\artifacts\release\winget\Caezium\Burrow\0.1.0-preview.1
winget install --manifest .\artifacts\release\winget\Caezium\Burrow\0.1.0-preview.1
```

`winget validate` can report that dependency package validation is deferred for `Microsoft.DotNet.DesktopRuntime.8`; that dependency must still exist in the community repository before submission.

Once accepted, users install with:

```powershell
winget install --id Caezium.Burrow -e
```

## Required Smoke Tests

After a release build, run:

```powershell
.\run-local.ps1 -NoBuild -SmokeTest -Restart -RequireHealth -Route settings -TimeoutSeconds 60
.\run-local.ps1 -NoBuild -SmokeTest -Restart -RequireHealth -Route optimize -OptimizeAutoScan -TimeoutSeconds 120
```

When validating UI changes, capture repeatable local screenshots:

```powershell
.\run-local.ps1 -NoBuild -SmokeTest -Restart -RequireHealth -Route history -ScreenshotPath artifacts\ui-smoke\burrowwin-history.png -TimeoutSeconds 60
.\run-local.ps1 -NoBuild -SmokeTest -Restart -RequireHealth -Route clean -CleanAutoScan -ScreenshotPath artifacts\ui-smoke\burrowwin-clean.png -TimeoutSeconds 120
```

CI does not run GUI smoke because GitHub-hosted Windows runners do not provide a normal interactive desktop session.
