//
//  MoleCLI.swift
//  Burrow
//
//  Wrapper around the `mo` command. Burrow doesn't ship Mole — it depends
//  on a system-installed copy (`brew install mole`), found via PATH.
//
//  Three commands matter to Burrow today:
//    * `mo status --json` — periodic sampling (SnapshotProducer uses this).
//      Emits the full system snapshot as JSON in ~3 KB. Auto-emits JSON
//      when stdout is not a TTY, but we pass `--json` explicitly so the
//      contract is visible in the args.
//    * `mo clean` / `mo optimize` — CleanView / OptimizeView (streamed).
//    * `mo analyze --json` — Analyze treemap (DiskScanner).
//    * `mo uninstall --list` — Software tab app list (JSON).
//
//  Everything routes through `run(args:)` so subprocess plumbing
//  (timeout, env, NSPipe management) lives in one place.
//

import Foundation
import AppKit  // NSAlert
import os

enum MoleCLI {
    /// Test seam: when set, discovery checks ONLY these paths (no trusted
    /// list, no `which` fallback) so cache semantics are deterministic.
    internal static var discoveryCandidates: [String]?

    /// Cached positive discovery (issue #48). Call sites hit
    /// `findExecutable()` on every sampler tick and tool run; without this
    /// each call re-stats three paths and may shell out to `which`.
    private static let discoveryCache = OSAllocatedUnfairLock<String?>(initialState: nil)

    static func resetDiscoveryCache() {
        discoveryCache.withLock { $0 = nil }
    }

    /// Locate the `mo` executable. Checks PATH plus a few known install
    /// locations because GUI apps inherit a stripped-down PATH that often
    /// doesn't include Homebrew's bin directory.
    ///
    /// Positive hits are cached and REVALIDATED with one stat per call (a
    /// vanished binary must not keep being served); misses are never cached
    /// (the user installs mo mid-session and the installer view rechecks).
    static func findExecutable() -> String? {
        if let cached = discoveryCache.withLock({ $0 }) {
            if FileManager.default.isExecutableFile(atPath: cached) { return cached }
            discoveryCache.withLock { $0 = nil }
        }
        let found = discover()
        if let found { discoveryCache.withLock { $0 = found } }
        return found
    }

    private static func discover() -> String? {
        if let candidates = discoveryCandidates {
            return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        // Hardcoded locations first — fastest path and works in the
        // GUI-launched case where PATH is `/usr/bin:/bin:/usr/sbin:/sbin`
        // and Homebrew is invisible.
        if let trusted = trustedExecutable() { return trusted }
        // Last resort: ask the shell. Will work if the user launched Burrow
        // from a terminal with their PATH set up, but not from Finder.
        if let viaShell = try? run(args: ["which", "mo"], executable: "/usr/bin/env").stdout,
           let first = viaShell.split(separator: "\n").first {
            let trimmed = String(first).trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, FileManager.default.isExecutableFile(atPath: trimmed) {
                return trimmed
            }
        }
        return nil
    }

    /// The known install locations ONLY — no PATH lookup. ELEVATED runs
    /// must resolve through this: accepting a user-writable PATH entry
    /// would hand root to whatever binary shadowed `mo` first.
    static func trustedExecutable() -> String? {
        let candidates = [
            "/opt/homebrew/bin/mo",      // Apple Silicon Homebrew
            "/usr/local/bin/mo",          // Intel Homebrew / manual install
            "/usr/bin/mo",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// Build the `do shell script` source for one elevated invocation:
    /// every argv element single-quoted for the shell, the whole command
    /// then escaped for embedding in an AppleScript string literal, and an
    /// optional output redirect to a (quoted) log file. The ONE builder
    /// shared by every elevated path, so the two escaping passes can't
    /// drift apart again (one runner had them, the other didn't).
    ///
    /// Prompt model (audited against mo 1.42, June 2026). One elevated run
    /// = one osascript invocation = exactly ONE admin password prompt:
    ///   * `mo` never adds prompts under us. Running as root, its
    ///     `ensure_sudo_session` / `request_sudo_access` short-circuit on
    ///     `sudo -n true`; its per-stage prompts (osascript password
    ///     dialogs in lib/clean/dev.sh etc.) only fire in UN-elevated real
    ///     runs, and every one sits behind a `DRY_RUN` early-return, so
    ///     scans never auth at all.
    ///   * What CAN'T be consolidated: prompts across separate runs (an
    ///     elevated scan, then the real clean). macOS defines the
    ///     `system.privilege.admin` right with shared=false, so the
    ///     credential from one osascript process never carries to the
    ///     next — re-prompting per run is OS policy, not a Burrow bug.
    ///     Pooling them would take a resident privileged helper
    ///     (SMAppService daemon + XPC), a deliberate non-goal for now.
    static func elevatedScript(executable: String, args: [String],
                               redirectTo logPath: String? = nil) -> String {
        func shQuote(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        var raw = ([executable] + args).map(shQuote).joined(separator: " ")
        if let logPath { raw += " > \(shQuote(logPath)) 2>&1" }
        let inner = raw.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(inner)\" with administrator privileges"
    }

    // MARK: - Install / version

    /// Canonical install command (Homebrew). Shown in the guided install
    /// flow; we never run it for the user.
    static let installCommand = "brew install mole"
    /// Where to send users without Homebrew.
    static let repoURL = URL(string: "https://github.com/tw93/Mole")!

    /// Current `mo` version, or nil if not installed / unparsable.
    static func version() -> String? {
        guard let res = try? run(args: ["--version"], timeout: 5) else { return nil }
        let text = res.stdout.isEmpty ? res.stderr : res.stdout
        return parseVersion(text)
    }

    /// Pull a semver out of `mo --version` output, whatever decoration it
    /// wraps it in ("mole 1.41.0", "v1.41.0", …). Pure → unit-tested.
    static func parseVersion(_ output: String) -> String? {
        for token in output.split(whereSeparator: { !($0.isNumber || $0 == ".") }) {
            let parts = token.split(separator: ".")
            if parts.count >= 2, parts.allSatisfy({ Int($0) != nil }) {
                return String(token)
            }
        }
        return nil
    }

    /// Oldest Mole whose `analyze` knows `--json` (added in V1.29.0,
    /// explicitly "for non-TTY environments"). Older versions launch the
    /// TUI instead, which opens /dev/tty and dies when the parent is a
    /// GUI app with no controlling terminal (#35).
    static let minimumAnalyzeJSONVersion = "1.29.0"

    /// Modal alert shown at launch when `mo` isn't installed. We block on
    /// it because there's nothing useful Burrow can do without Mole, and a
    /// background app silently failing is the worst possible UX for this
    /// dependency model.
    static func showMissingAlert() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Mole CLI not found", comment: "")
        alert.informativeText = NSLocalizedString("""
            Burrow uses the Mole CLI (`mo`) for system metrics and cleanup. \
            Install it with:

                brew install mole

            Then relaunch Burrow.
            """, comment: "")
        alert.alertStyle = .critical
        alert.addButton(withTitle: NSLocalizedString("Quit", comment: ""))
        _ = alert.runModal()
    }

    /// Result of a subprocess invocation. `exitCode == 0` is the success
    /// convention; callers that care about diagnostics should look at
    /// `stderr` when it's non-zero, and `timedOut` distinguishes "the
    /// timeout killed it" from a genuine failure (issue #48).
    struct Result {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        var timedOut: Bool = false
    }

    /// The subprocess runner. Production uses `SystemMoleProcess`; tests inject
    /// a fake (reset in `tearDown`). Test-only seam — not a configuration point.
    internal static var processPort: MoleProcessPort = SystemMoleProcess()

    /// The one-shot elevated runner (issue #48). Production spawns real
    /// osascript via `SystemPrivilegeBroker`; tests inject a fake so the
    /// build-the-osascript-spec quoting + auth-cancel classification run in
    /// memory with no auth dialog. Test-only seam — reset in `tearDown`.
    internal static var privilegeBroker: PrivilegeBroker = SystemPrivilegeBroker()

    /// Run an executable with the given args, capturing stdout + stderr.
    /// Blocks until the process exits — callers are responsible for
    /// running this on a background queue. Times out after `timeout`
    /// seconds; on timeout the process is terminated and the call returns a
    /// non-zero `exitCode` (it does NOT throw). Callers treat any non-zero
    /// exit as failure rather than distinguishing timeout from other errors.
    ///
    /// `stdin` feeds the child's standard input then closes it (EOF). This
    /// is how the uninstall flow answers Mole's `Proceed? [y/N]` and
    /// `Enter confirm` prompts — a GUI app's inherited stdin is closed, so
    /// without this `mo uninstall <app>` blocks forever on the prompt.
    @discardableResult
    static func run(args: [String],
                    executable: String? = nil,
                    stdin: String? = nil,
                    timeout: TimeInterval = 10) throws -> Result {
        let resolvedExecutable = executable ?? (findExecutable() ?? "/usr/bin/false")
        let processResult = try MoleProcess.capture(
            executable: resolvedExecutable,
            args: args,
            stdin: stdin,
            timeout: timeout,
            port: processPort
        )
        return Result(
            stdout: processResult.stdout,
            stderr: processResult.stderr,
            exitCode: processResult.exitCode,
            timedOut: processResult.timedOut
        )
    }

    /// Run `mo <args>` ONCE with administrator rights via the macOS auth
    /// dialog. That dialog is PASSWORD-ONLY: the `system.privilege.admin`
    /// right authenticates through SecurityAgent's classic mechanism, which
    /// never offers Touch ID — pam_tid (`mo touchid`) covers terminal
    /// `sudo`, not this path. Blocking — call off the main thread. For
    /// one-shot privileged config like `touchid enable/disable`, not for
    /// streamed jobs (OperationFlow does those).
    ///
    /// The spawn now goes through `PrivilegeBroker` so the osascript quoting
    /// and auth-cancel classification are testable in memory (issue #48); the
    /// `Int32` return is preserved for existing callers that only branch on
    /// "did it work" (a dismissed prompt collapses to a nonzero code, exactly
    /// as before). New callers that want the named outcome use
    /// `runElevatedClassified`.
    static func runElevated(args: [String]) -> Int32 {
        runElevatedClassified(args: args).exitCode
    }

    /// As `runElevated`, but returns the classified outcome — `.authCancelled`
    /// for a dismissed prompt is distinguished from a command that ran and
    /// failed, so callers can show the right message without re-deriving the
    /// "nonzero might mean cancel" heuristic themselves.
    static func runElevatedClassified(args: [String]) -> ElevatedOutcome {
        guard let mo = trustedExecutable() else { return .launchFailed }
        return privilegeBroker.openElevated(executable: mo, args: args)
    }
}
