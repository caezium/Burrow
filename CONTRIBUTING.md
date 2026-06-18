# Contributing to BurrowWin

Thanks for helping make Burrow usable on Windows. This branch should stay easy to review, safe to run, and honest about Mole Windows limitations.

## Development Rules

- Keep UI, ViewModel, and service boundaries clear. UI code should handle WinUI events; ViewModels should hold state and commands; services should own Windows/Mole integration.
- Prefer Mole Windows when it exposes a safe, non-interactive command. Use native Windows fallback only when Mole lacks JSON output or background-safe behavior.
- Keep destructive operations preview-first and confirmation-gated.
- Preserve local-only agent access: HTTP must bind to loopback and MCP destructive actions must remain opt-in.
- Use English for code names, comments, scripts, workflow text, and docs.

## Pull Request Checklist

- `dotnet build .\BurrowWin.csproj -p:Platform=x64 -nr:false -v:minimal`
- `dotnet build .\Tests\BurrowWin.Tests\BurrowWin.Tests.csproj -nr:false -v:minimal`
- `dotnet test .\Tests\BurrowWin.Tests\BurrowWin.Tests.csproj --no-build -v:minimal`
- If UI or startup behavior changed, run at least one `run-local.ps1` smoke route. Add `-ScreenshotPath artifacts\ui-smoke\<route>.png` when the change affects layout, navigation, charts, or autoscan result surfaces.
- Update `BURROW_WINDOWS_ALIGNMENT.md` when changing Mole fallback boundaries, release gates, or known gaps.

## Branch Readiness

A change is release-ready only when tests pass, the app can open a visible WinUI window, `/health` responds when HTTP is enabled, and release documentation remains accurate for a new contributor.
