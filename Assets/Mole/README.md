<div align="center">
  <img src="https://cdn.tw93.fun/pic/cole.png" alt="Mole Logo" width="120" height="120" style="border-radius:50%" />
  <h1>Mole</h1>
  <p><em>Deep clean and optimize your Windows.</em></p>
</div>

<p align="center">
  <a href="https://github.com/tw93/mole/stargazers"><img src="https://img.shields.io/github/stars/tw93/mole?style=flat-square" alt="Stars"></a>
  <img src="https://img.shields.io/badge/channel-windows%20source-orange?style=flat-square" alt="Channel">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square" alt="License"></a>
  <a href="https://github.com/tw93/mole/commits"><img src="https://img.shields.io/github/commit-activity/m/tw93/mole?style=flat-square" alt="Commits"></a>
  <a href="https://twitter.com/HiTw93"><img src="https://img.shields.io/badge/follow-Tw93-red?style=flat-square&logo=Twitter" alt="Twitter"></a>
  <a href="https://t.me/+GclQS9ZnxyI2ODQ1"><img src="https://img.shields.io/badge/chat-Telegram-blueviolet?style=flat-square&logo=Telegram" alt="Telegram"></a>
</p>

> [!WARNING]
> **Experimental Status**: The Windows version is currently **not mature**. If your computer is critical or contains important data, **please do not use this tool**.

## Features

- **All-in-one toolkit**: CCleaner, IObit Uninstaller, WinDirStat, and Task Manager combined into a single PowerShell toolkit
- **Deep cleaning**: Scans and removes temp files, caches, and browser leftovers to reclaim gigabytes of space
- **Smart uninstaller**: Thoroughly removes apps along with AppData, preferences, and hidden remnants
- **Disk insights**: Visualizes usage, manages large files, and refreshes system services
- **Live monitoring**: Real-time stats for CPU, memory, disk, and network to diagnose performance issues
- **Source channel updates**: Install from the `windows` branch and refresh to the latest source with `mo update`

## Platform Support

Mole is designed for Windows 10/11. This is the native Windows version ported from the [macOS original](https://github.com/tw93/Mole/tree/main). For macOS users, please visit the [main branch](https://github.com/tw93/Mole) for the native macOS version.

## Requirements

- Windows 10/11
- PowerShell 5.1 or later (pre-installed on Windows 10/11)
- Git (required for source-channel install and `mo update`)
- Go 1.24+ (optional, only needed when building TUI tools locally)

## Quick Start

### Quick Install (One-Liner)

**Recommended:** Run this single command in PowerShell:

```powershell
iwr -useb https://raw.githubusercontent.com/tw93/Mole/windows/quick-install.ps1 | iex
```

This will clone the latest `windows` branch into your install directory and configure PATH.

### Manual Installation

If you prefer to review the code first or customize the installation:

```powershell
# Clone the windows branch into your install directory
$installDir = "$env:LOCALAPPDATA\Mole"
git clone --branch windows https://github.com/tw93/Mole.git $installDir
cd $installDir

# Run the installer in place (keeps .git for mo update)
powershell -ExecutionPolicy Bypass -File .\install.ps1 -InstallDir $installDir -AddToPath

# Optional: Create Start Menu shortcut
powershell -ExecutionPolicy Bypass -File .\install.ps1 -InstallDir $installDir -AddToPath -CreateShortcut
```

Run:

```powershell
mo                       # Interactive menu
mo clean                 # Deep cleanup
mo uninstall             # Remove apps + leftovers
mo optimize              # Refresh caches & services
mo analyze               # Visual disk explorer
mo status                # Live system health dashboard
mo update                # Pull the latest windows source
mo remove                # Remove Mole from this system
mo purge                 # Clean project build artifacts

mo --help                # Show help
mo --version             # Show installed version

mo clean --dry-run       # Preview the cleanup plan
mo clean --whitelist     # Manage protected caches
mo clean --dry-run --debug # Detailed preview with risk levels

mo optimize --dry-run    # Preview optimization actions
mo optimize --debug      # Run with detailed operation logs
mo purge --paths         # Configure project scan directories
```

Source-channel installs can later be refreshed with:

```powershell
mo update
```

If a matching Windows prerelease exists for the installed version, Mole will reuse/download prebuilt `analyze` and `status` binaries before falling back to a local Go build.

## macOS Parity

Windows is closest to macOS on these commands:

- `clean`
- `uninstall`
- `optimize`
- `analyze`
- `status`
- `purge`
- `update`
- `remove`

Still missing or intentionally platform-specific compared with `main`:

- `installer`: no dedicated Windows installer-file cleanup command yet
- `completion`: no PowerShell completion setup command yet
- `touchid`: macOS-only, not applicable on Windows
- Release channels: Windows currently uses a git source channel, not Homebrew/stable release installs
- Update options: `mo update --nightly` is not implemented on Windows
- Optimization controls: `mo optimize --whitelist` is not implemented on Windows
- Some UI depth: macOS `status` and `analyze` expose richer device-specific details than Windows today
- Windows prereleases use `Vx.y.z-windows` tags so they stay isolated from the macOS stable release channel

## Tips

- **Safety**: Built with strict protections. Preview changes with `mo clean --dry-run`.
- **Be Careful**: Although safe by design, file deletion is permanent. Please review operations carefully.
- **Debug Mode**: Use `--debug` for detailed logs (e.g., `mo clean --debug`). Combine with `--dry-run` for comprehensive preview including risk levels and file details.
- **Navigation**: Supports arrow keys for TUI navigation.
- **Configuration**: Use `mo clean --whitelist` to manage protected paths, `mo purge --paths` to configure scan directories.

## Features in Detail

### Deep System Cleanup

```powershell
mo clean
```

```
Scanning cache directories...

  ✓ User temp files                              12.3GB
  ✓ Browser cache (Chrome, Edge, Firefox)         8.5GB
  ✓ Developer tools (Node.js, npm, Python)       15.2GB
  ✓ Windows logs and temp files                   4.1GB
  ✓ App-specific cache (Spotify, Slack, VS Code)  6.8GB
  ✓ Recycle Bin                                    9.2GB

====================================================================
Space freed: 56.1GB | Free space now: 180.3GB
====================================================================
```

### Smart App Uninstaller

```powershell
mo uninstall
```

```
Select Apps to Remove
═══════════════════════════
▶ ☑ Adobe Photoshop 2024     (4.2GB) | Old
  ☐ IntelliJ IDEA             (2.8GB) | Recent
  ☐ Premiere Pro              (3.4GB) | Recent

Uninstalling: Adobe Photoshop 2024

  ✓ Removed application
  ✓ Cleaned 52 related files across 8 locations
    - AppData, Caches, Preferences
    - Logs, Registry entries
    - Extensions, Plugins

====================================================================
Space freed: 4.8GB
====================================================================
```

### System Optimization

```powershell
mo optimize
```

```
System: 12/32 GB RAM | 280/460 GB Disk (61%) | Uptime 6d

  ✓ Clear Windows Update cache
  ✓ Reset DNS cache
  ✓ Clean event logs and diagnostic reports
  ✓ Refresh Windows Search index
  ✓ Clear thumbnail cache
  ✓ Optimize startup programs
  ✓ System repairs (Font/Icon/Store/Search)

====================================================================
System optimization completed
====================================================================
```

### Disk Space Analyzer

```powershell
mo analyze
```

```
Analyze Disk  C:\Users\YourName\Documents  |  Total: 156.8GB

 ▶  1. ███████████████████  48.2%  |  📁 Downloads           75.4GB  >6mo
    2. ██████████░░░░░░░░░  22.1%  |  📁 Videos              34.6GB
    3. ████░░░░░░░░░░░░░░░  14.3%  |  📁 Pictures            22.4GB
    4. ███░░░░░░░░░░░░░░░░  10.8%  |  📁 Documents           16.9GB
    5. ██░░░░░░░░░░░░░░░░░   5.2%  |  📄 backup_2023.zip      8.2GB

  ↑↓←→ Navigate  |  O Open  |  F Show  |  Del Delete  |  L Large files  |  Q Quit
```

### Live System Status

Real-time dashboard with system health score, hardware info, and performance metrics.

```powershell
mo status
```

```
Mole Status  Health ● 92  Desktop PC · Intel i7 · 32GB · Windows 11

⚙ CPU                                    ▦ Memory
Total   ████████████░░░░░░░ 45.2%       Used    ███████████░░░░░░░  58.4%
Load    0.82 / 1.05 / 1.23 (8 cores)    Total   18.7 / 32.0 GB
Core 1  ███████████████░░░░  78.3%      Free    ████████░░░░░░░░░░  41.6%
Core 2  ████████████░░░░░░░  62.1%      Avail   13.3 GB

▤ Disk                                   ⚡ Power
Used    █████████████░░░░░░  67.2%      Status  AC Power
Free    156.3 GB                         Temp    58°C
Read    ▮▯▯▯▯  2.1 MB/s
Write   ▮▮▮▯▯  18.3 MB/s

⇅ Network                                ▶ Processes
Down    ▮▮▯▯▯  3.2 MB/s                 Code       ▮▮▮▮▯  42.1%
Up      ▮▯▯▯▯  0.8 MB/s                 Chrome     ▮▮▮▯▯  28.3%
```

Health score based on CPU, memory, disk, temperature, and I/O load. Color-coded by range.

### Project Artifact Purge

Clean old build artifacts (`node_modules`, `target`, `build`, `dist`, etc.) from your projects to free up disk space.

```powershell
mo purge
```

```
Select Categories to Clean - 18.5GB (8 selected)

➤ ● my-react-app      3.2GB | node_modules
  ● old-project       2.8GB | node_modules
  ● rust-app          4.1GB | target
  ● next-blog         1.9GB | node_modules
  ○ current-work      856MB | node_modules  | Recent
  ● django-api        2.3GB | venv
  ● vue-dashboard     1.7GB | node_modules
  ● backend-service   2.5GB | node_modules
```

Use with caution: This will permanently delete selected artifacts. Review carefully before confirming. Recent projects — less than 7 days old — are marked and unselected by default.

Custom scan paths can be configured with `mo purge --paths`.

## Installation Options

### Manual Installation

```powershell
# Install to custom location from a cloned windows branch
powershell -ExecutionPolicy Bypass -File .\install.ps1 -InstallDir C:\Tools\Mole -AddToPath

# Create Start Menu shortcut
powershell -ExecutionPolicy Bypass -File .\install.ps1 -InstallDir C:\Tools\Mole -AddToPath -CreateShortcut

# Refresh the source channel later
mo update
```

### Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
```

## Configuration

Mole stores its configuration in:

- Config: `~\.config\mole\`
- Cache: `~\.cache\mole\`
- Whitelist: `~\.config\mole\whitelist.txt`
- Purge paths: `~\.config\mole\purge_paths.txt`

## Directory Structure

```
mole/ (windows branch)
├── mole.ps1          # Main CLI entry point
├── install.ps1       # Windows installer
├── Makefile          # Build automation for Go tools
├── go.mod            # Go module definition
├── go.sum            # Go dependencies
├── bin/
│   ├── clean.ps1     # Deep cleanup orchestrator
│   ├── uninstall.ps1 # Interactive app uninstaller
│   ├── optimize.ps1  # System optimization
│   ├── purge.ps1     # Project artifact cleanup
│   ├── analyze.ps1   # Disk analyzer wrapper
│   ├── status.ps1    # Status monitor wrapper
│   ├── update.ps1    # Source channel updater
│   └── remove.ps1    # Self-uninstall wrapper
├── cmd/
│   ├── analyze/      # Disk analyzer (Go TUI)
│   │   └── main.go
│   └── status/       # System status (Go TUI)
│       └── main.go
└── lib/
    ├── core/
    │   ├── base.ps1      # Core definitions and utilities
    │   ├── common.ps1    # Common functions loader
    │   ├── file_ops.ps1  # Safe file operations
    │   ├── log.ps1       # Logging functions
    │   ├── tui_binaries.ps1 # TUI binary restore/build helpers
    │   └── ui.ps1        # Interactive UI components
    └── clean/
        ├── user.ps1      # User cleanup (temp, downloads, etc.)
        ├── caches.ps1    # Browser and app caches
        ├── dev.ps1       # Developer tool caches
        ├── apps.ps1      # Application leftovers
        └── system.ps1    # System cleanup (requires admin)
```

## Building TUI Tools

Install Go if you want to build the analyze and status tools locally:

```powershell
# From the repository root

# Build both tools
make build

# Or build individually
go build -o bin/analyze.exe ./cmd/analyze/
go build -o bin/status.exe ./cmd/status/

# The wrapper scripts try bin/ first, then Windows prerelease assets,
# then auto-build if Go is available
```

## Support

- If Mole saved you disk space, consider starring the repo or [sharing it](https://twitter.com/intent/tweet?url=https://github.com/tw93/Mole/tree/windows&text=Mole%20-%20Deep%20clean%20and%20optimize%20your%20Windows%20PC.) with friends.
- Have ideas or fixes? Check our [Contributing Guide](https://github.com/tw93/Mole/blob/windows/CONTRIBUTING.md), then open an issue or PR to help shape Mole's future.
- Love Mole? [Buy Tw93 an ice-cold Coke](https://miaoyan.app/cats.html?name=Mole) to keep the project alive and kicking! 🥤

## Community Love

### Phase 1: Core Infrastructure ✅

- [x] `install.ps1` - Windows installer
- [x] `mole.ps1` - Main CLI entry point
- [x] `lib/core/*` - Core utility libraries

### Phase 2: Cleanup Features ✅

- [x] `bin/clean.ps1` - Deep cleanup orchestrator
- [x] `bin/uninstall.ps1` - App removal with leftover detection
- [x] `bin/optimize.ps1` - System optimization
- [x] `bin/purge.ps1` - Project artifact cleanup
- [x] `lib/clean/*` - Cleanup modules

### Phase 3: TUI Tools ✅

- [x] `cmd/analyze/` - Disk usage analyzer (Go)
- [x] `cmd/status/` - Real-time system monitor (Go)
- [x] `bin/analyze.ps1` - Analyzer wrapper
- [x] `bin/status.ps1` - Status wrapper
- [x] `bin/update.ps1` - Source channel updater
- [x] `bin/remove.ps1` - Self-uninstall wrapper

### Phase 4: Testing & CI (Planned)

- [ ] `tests/` - Pester tests
- [ ] GitHub Actions workflows
- [ ] `scripts/build.ps1` - Build automation

Mole wouldn't be possible without these amazing contributors. They've built countless features that make Mole what it is today. Go follow them! ❤️

[![Contributors](https://contrib.rocks/image?repo=tw93/Mole)](https://github.com/tw93/Mole/graphs/contributors)

Join thousands of users worldwide who trust Mole to keep their systems clean and optimized.

## License

MIT License — feel free to enjoy and participate in open source.
