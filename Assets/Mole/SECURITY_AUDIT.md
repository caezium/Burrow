# Mole Security Audit Report

<div align="center">

**Status:** PASSED | **Risk Level:** LOW | **Version:** 1.19.0 (2026-01-09)

</div>

---

## Audit Overview

| Attribute | Details |
|-----------|---------|
| Audit Date | January 9, 2026 |
| Audit Conclusion | **PASSED** |
| Mole Version | V1.19.0 |
| Audited Branch | `main` (HEAD) |
| Scope | Shell scripts, Go binaries, Configuration |
| Methodology | Static analysis, Threat modeling, Code review |
| Review Cycle | Every 6 months or after major feature additions |
| Next Review | June 2026 |

**Key Findings:**

- Multi-layer validation effectively blocks risky system modifications.
- Conservative cleaning logic ensures safety (e.g., 60-day dormancy rule).
- Comprehensive protection for VPNs, AI tools, and core system components.
- Atomic operations prevent state corruption during crashes.
- Dry-run and whitelist features give users full control.
- Installer cleanup scans safely and requires user confirmation.

---

## Security Philosophy

**Core Principle: "Do No Harm"**

We built Mole on a **Zero Trust** architecture for filesystem operations. Every modification request is treated as dangerous until it passes strict validation.

**Guiding Priorities:**

1. **System Stability First** - We'd rather leave 1GB of junk than delete 1KB of your data.
2. **Conservative by Default** - High-risk operations always require explicit confirmation.
3. **Fail Safe** - When in doubt, we abort immediately.
4. **Transparency** - Every operation is logged and allows a preview via dry-run mode.

---

## Threat Model

### Attack Vectors & Mitigations

| Threat | Risk Level | Mitigation | Status |
|--------|------------|------------|--------|
| Accidental System File Deletion | Critical | Multi-layer path validation, system directory blocklist | Mitigated |
| Path Traversal Attack | High | Absolute path enforcement, relative path rejection | Mitigated |
| Symlink Exploitation | High | Symlink detection in privileged mode | Mitigated |
| Command Injection | High | Control character filtering, strict validation | Mitigated |
| Empty Variable Deletion | High | Empty path validation, defensive checks | Mitigated |
| Race Conditions | Medium | Atomic operations, process isolation | Mitigated |
| Network Mount Hangs | Medium | Timeout protection, volume type detection | Mitigated |
| Privilege Escalation | Medium | Restricted sudo scope, user home validation | Mitigated |
| False Positive Deletion | Medium | 3-char minimum, fuzzy matching disabled | Mitigated |
| VPN Configuration Loss | Medium | Comprehensive VPN/proxy whitelist | Mitigated |

---

## Defense Architecture

### Multi-Layered Validation System

All automated operations pass through hardened middleware (`lib/core/file_ops.sh`) with 4 layers of validation:

#### Layer 1: Input Sanitization

| Control | Protection Against |
|---------|---------------------|
| Absolute Path Enforcement | Path traversal attacks (`../etc`) |
| Control Character Filtering | Command injection (`\n`, `\r`, `\0`) |
| Empty Variable Protection | Accidental `rm -rf /` |
| Secure Temp Workspaces | Data leakage, race conditions |

**Code:** `lib/core/file_ops.sh:validate_path_for_deletion()`

#### Layer 2: System Path Protection ("Iron Dome")

Even with `sudo`, these paths are **unconditionally blocked**:

```bash
/                    # Root filesystem
/System              # macOS system files
/bin, /sbin, /usr    # Core binaries
/etc, /var           # System configuration
/Library/Extensions  # Kernel extensions
```

**Exception:** `/System/Library/Caches/com.apple.coresymbolicationd/data` (safe, rebuildable cache).

**Code:** `lib/core/file_ops.sh:60-78`

#### Layer 3: Symlink Detection

For privileged operations, pre-flight checks prevent symlink-based attacks:

- Detects symlinks from cache folders pointing to system files.
- Refuses recursive deletion of symbolic links in sudo mode.
- Validates real path vs. symlink target.

**Code:** `lib/core/file_ops.sh:safe_sudo_recursive_delete()`

#### Layer 4: Permission Management

When running with `sudo`:

- Auto-corrects ownership back to user (`chown -R`).
- Restricts operations to the user's home directory.
- Enforces multiple validation checkpoints.

### Interactive Analyzer (Go)

The analyzer (`mo analyze`) uses a distinct security model:

- Runs with standard user permissions only.
- Respects macOS System Integrity Protection (SIP).
- **Two-Key Confirmation:** Deletion requires ⌫ (Delete) to enter confirmation mode, then Enter to confirm. Prevents accidental double-press of the same key.
- **Trash Instead of Delete:** Files are moved to macOS Trash using Finder's native API, allowing easy recovery if needed.
- OS-level enforcement (cannot delete `/System` due to Read-Only Volume).

**Code:** `cmd/analyze/*.go`

---

## Safety Mechanisms

### Conservative Cleaning Logic

#### The "60-Day Rule" for Orphaned Data

| Step | Verification | Criterion |
|------|--------------|-----------|
| 1. App Check | All installation locations | Must be missing from `/Applications`, `~/Applications`, `/System/Applications` |
| 2. Dormancy | Modification timestamps | Untouched for ≥60 days |
| 3. Vendor Whitelist | Cross-reference database | Adobe, Microsoft, and Google resources are protected |

**Code:** `lib/clean/apps.sh:orphan_detection()`

#### Active Uninstallation Heuristics

For user-selected app removal:

- **Sanitized Name Matching:** "Visual Studio Code" → `VisualStudioCode`, `.vscode`
- **Safety Limit:** 3-char minimum (prevents "Go" matching "Google")
- **Disabled:** Fuzzy matching and wildcard expansion for short names.
- **User Confirmation:** Required before deletion.

**Code:** `lib/clean/apps.sh:uninstall_app()`

#### System Protection Policies

| Protected Category | Scope | Reason |
|--------------------|-------|--------|
| System Integrity Protection | `/Library/Updates`, `/System/*` | Respects macOS Read-Only Volume |
| Spotlight & System UI | `~/Library/Metadata/CoreSpotlight` | Prevents UI corruption |
| System Components | Control Center, System Settings, TCC | Centralized detection via `is_critical_system_component()` |
| Time Machine | Local snapshots, backups | Checks `backupd` process, aborts if active |
| VPN & Proxy | Shadowsocks, V2Ray, Tailscale, Clash | Protects network configs |
| AI & LLM Tools | Cursor, Claude, ChatGPT, Ollama, LM Studio | Protects models, tokens, and sessions |
| Startup Items | `com.apple.*` LaunchAgents/Daemons | System items unconditionally skipped |

**Orphaned Helper Cleanup (`opt_startup_items_cleanup`):**

Removes LaunchAgents/Daemons whose associated app has been uninstalled:

- Checks `AssociatedBundleIdentifiers` to detect orphans.
- Skips all `com.apple.*` system items.
- Skips paths under `/System/*`, `/usr/bin/*`, `/usr/lib/*`, `/usr/sbin/*`, `/Library/Apple/*`.
- Uses `safe_remove` / `safe_sudo_remove` with path validation.
- Unloads service via `launchctl` before deletion.
- **Timeout Protection:** 10-second limit on `mdfind` operations.

**Code:** `lib/optimize/tasks.sh:opt_startup_items_cleanup()`

### Crash Safety & Atomic Operations

| Operation | Safety Mechanism | Recovery Behavior |
|-----------|------------------|-------------------|
| Network Interface Reset | Atomic execution blocks | Wi-Fi/AirDrop restored to pre-operation state |
| Swap Clearing | Daemon restart | `dynamic_pager` handles recovery safely |
| Volume Scanning | Timeout + filesystem check | Auto-skip unresponsive NFS/SMB/AFP mounts |
| Homebrew Cache | Pre-flight size check | Skip if <50MB (avoids long delays) |
| Network Volume Check | `diskutil info` with timeout | Prevents hangs on slow/dead mounts |
| SQLite Vacuum | App-running check + 20s timeout | Skips if Mail/Safari/Messages active |
| dyld Cache Update | 24-hour freshness check + 180s timeout | Skips if recently updated |
| App Bundle Search | 10s timeout on mdfind | Fallback to standard paths |

**Timeout Example:**

```bash
run_with_timeout 5 diskutil info "$mount_point" || skip_volume
```

**Code:** `lib/core/base.sh:run_with_timeout()`, `lib/optimize/*.sh`

---

## User Controls

### Dry-Run Mode

**Command:** `mo clean --dry-run` | `mo optimize --dry-run`

**Behavior:**

- Simulates the entire operation without modifying a single file.
- Lists every file/directory that **would** be deleted.
- Calculates total space that **would** be freed.
- **Zero risk** - no actual deletion commands are executed.

### Custom Whitelists

**File:** `~/.config/mole/whitelist`

**Format:**

```bash
# One path per line - exact matches only
/Users/username/important-cache
~/Library/Application Support/CriticalApp
```

- Paths are **unconditionally protected**.
- Applies to all operations (clean, optimize, uninstall).
- Supports absolute paths and `~` expansion.

**Code:** `lib/core/file_ops.sh:is_whitelisted()`

### Interactive Confirmations

We mandate confirmation for:

- Uninstalling system-scope applications.
- Removing large data directories (>1GB).
- Deleting items from shared vendor folders.

---

## Testing & Compliance

### Test Coverage

Mole uses **BATS (Bash Automated Testing System)** for automated testing.

| Test Category | Coverage | Key Tests |
|---------------|----------|-----------|
| Core File Operations | 95% | Path validation, symlink detection, permissions |
| Cleaning Logic | 87% | Orphan detection, 60-day rule, vendor whitelist |
| Optimization | 82% | Cache cleanup, timeouts |
| System Maintenance | 90% | Time Machine, network volumes, crash recovery |
| Security Controls | 100% | Path traversal, command injection, symlinks |

**Total:** 180+ tests | **Overall Coverage:** ~88%

**Test Execution:**

```bash
bats tests/              # Run all tests
bats tests/security.bats # Run specific suite
```

### Standards Compliance

| Standard | Implementation |
|----------|----------------|
| OWASP Secure Coding | Input validation, least privilege, defense-in-depth |
| CWE-22 (Path Traversal) | Enhanced detection: rejects `/../` components, safely handles `..` in directory names |
| CWE-78 (Command Injection) | Control character filtering |
| CWE-59 (Link Following) | Symlink detection before privileged operations |
| Apple File System Guidelines | Respects SIP, Read-Only Volumes, TCC |

### Security Development Lifecycle

- **Static Analysis:** `shellcheck` runs on all shell scripts.
- **Code Review:** All changes are manually reviewed by maintainers.
- **Dependency Scanning:** Minimal external dependencies, all carefully vetted.

### Known Limitations

| Limitation | Impact | Mitigation |
|------------|--------|------------|
| Requires `sudo` for system caches | Initial friction | Clear documentation explaining why |
| 60-day rule may delay cleanup | Some orphans remain longer | Manual `mo uninstall` is always available |
| No undo functionality | Deleted files are unrecoverable | Dry-run mode and warnings are clear |
| English-only name matching | May miss non-English apps | Fallback to Bundle ID matching |

**Intentionally Out of Scope (Safety):**

- Automatic deletion of user documents/media.
- Encryption key stores or password managers.
- System configuration files (`/etc/*`).
- Browser history or cookies.
- Git repository cleanup.

---

## Dependencies

### System Binaries

Mole relies on standard, SIP-protected macOS system binaries:

| Binary | Purpose | Fallback |
|--------|---------|----------|
| `plutil` | Validate `.plist` integrity | Skip invalid plists |
| `tmutil` | Time Machine interaction | Skip TM cleanup |
| `dscacheutil` | System cache rebuilding | Optional optimization |
| `diskutil` | Volume information | Skip network volumes |

### Go Dependencies (Interactive Tools)

The compiled Go binary (`analyze-go`) includes:

| Library | Version | Purpose | License |
|---------|---------|---------|---------|
| `bubbletea` | v0.23+ | TUI framework | MIT |
| `lipgloss` | v0.6+ | Terminal styling | MIT |
| `gopsutil` | v3.22+ | System metrics | BSD-3 |
| `xxhash` | v2.2+ | Fast hashing | BSD-2 |

**Supply Chain Security:**

- All dependencies are pinned to specific versions.
- Regular security audits.
- No transitive dependencies with known CVEs.
- **Automated Releases**: Binaries are compiled and signed via GitHub Actions.
- **Source Only**: The repository contains no pre-compiled binaries.

---

**Our Commitment:** This document certifies that Mole implements industry-standard defensive programming practices and strictly adheres to macOS security guidelines. We prioritize system stability and data integrity above all else.

*For security concerns or vulnerability reports, please open an issue or contact the maintainers directly.*
