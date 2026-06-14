//
//  MoEngine.swift
//  Burrow
//
//  The single entry point to the `mo` runners (issue #48). Burrow grew three
//  process shapes — capture (small one-shot commands), streaming (clean /
//  optimize), and PTY (purge / installer) — plus a one-shot elevated path,
//  each found and spawned at its own call site. `MoEngine` is the ONE facade
//  callers reach for so "how do I run mo?" has a single answer.
//
//  This slice (slice 2) wraps the CAPTURE + ELEVATED entry points and the
//  discovery lookup, delegating to the existing, tested ports — it does NOT
//  reimplement them. The streaming (`OperationFlow`/`SystemProcessPort`) and
//  interactive PTY (`MoInteractive`/`PTYTask`) shapes are deliberately left in
//  place; folding those onto the facade is the next slice.
//
//  Behavior is preserved exactly: a `capture(_:)` call produces the same argv,
//  stdin, environment, timeout, and result fields that `MoleCLI.run` did, and
//  `runElevatedClassified` routes through the same `PrivilegeBroker` against
//  the same trusted-location resolution. The ports are injected (production
//  defaults are the real ones) so the facade is testable with scripted fakes,
//  matching the seams `MoleCLI`/`MoleProcess`/`PrivilegeBroker` already expose.
//

import Foundation

// MARK: - Command shape

/// One `mo` invocation, described once. `target` chooses how the executable is
/// resolved (the discovered `mo`, or an explicit path like Homebrew's `brew`);
/// the rest mirrors what the capture runner already accepts so migrating a
/// `MoleCLI.run(...)` call is a 1:1 translation.
struct MoCommand: Equatable {
    enum Target: Equatable {
        /// Resolve through discovery (`MoLocator.locate`); falls back to a
        /// non-existent path so a missing `mo` surfaces as a nonzero exit, the
        /// same degradation `MoleCLI.run` had.
        case mo
        /// Run this exact executable path (the brew straggler, test binaries).
        case executable(String)
    }

    var target: Target
    var args: [String]
    var stdin: String?
    var environment: [String: String]?
    /// Same default as `MoleCLI.run` (10 s) so an unspecified timeout behaves
    /// identically to the pre-facade call.
    var timeout: TimeInterval

    init(target: Target,
         args: [String],
         stdin: String? = nil,
         environment: [String: String]? = nil,
         timeout: TimeInterval = 10) {
        self.target = target
        self.args = args
        self.stdin = stdin
        self.environment = environment
        self.timeout = timeout
    }
}

// MARK: - Capture result

/// What a captured run produced. A thin rename of `MoleProcessResult` /
/// `MoleCLI.Result` so the typed parsers keep reading the same fields; the
/// success convention is still `exitCode == 0`, and `timedOut` distinguishes a
/// timeout kill from a genuine nonzero exit (issue #48's "no exit-15 lie").
struct Captured: Equatable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    var timedOut: Bool = false
}

// MARK: - Discovery

/// Where `mo` is, or that it's missing. Mirrors `MoleCLI.findExecutable()`
/// returning `String?`, but names the miss so call sites read intent.
enum Availability: Equatable {
    case installed(path: String)
    case missing
}

/// Discovery seam. Production resolves through `MoleCLI` (PATH + known
/// locations, cached + revalidated for normal lookups; trusted-locations-only
/// for elevated runs); tests inject a fake to drive resolution deterministically.
protocol MoLocator: Sendable {
    /// The `mo` for a normal (unelevated) run — PATH allowed.
    func locate() -> String?
    /// The `mo` for an ELEVATED run — known install locations ONLY, never a
    /// user-writable PATH entry (running an attacker-shadowed binary as root is
    /// the whole threat model).
    func locateTrusted() -> String?
}

/// The production locator: delegates to `MoleCLI`'s existing discovery so the
/// caching/revalidation and trusted-only semantics stay in one place.
struct SystemMoLocator: MoLocator {
    func locate() -> String? { MoleCLI.findExecutable() }
    func locateTrusted() -> String? { MoleCLI.trustedExecutable() }
}

// MARK: - Facade

/// The one runner facade. Capture + elevated + discovery in this slice; the
/// ports are injected so every path is testable in memory.
final class MoEngine {
    private let processPort: MoleProcessPort
    private let privilegeBroker: PrivilegeBroker
    private let locator: MoLocator

    /// Production singleton. Wraps the real capture runner, the real osascript
    /// broker, and `MoleCLI` discovery — the exact spawn paths the migrated
    /// call sites used before, just funneled through one type.
    static let shared = MoEngine()

    init(processPort: MoleProcessPort = SystemMoleProcess(),
         privilegeBroker: PrivilegeBroker = SystemPrivilegeBroker(),
         locator: MoLocator = SystemMoLocator()) {
        self.processPort = processPort
        self.privilegeBroker = privilegeBroker
        self.locator = locator
    }

    // MARK: Discovery

    /// Is `mo` installed, and where? Uses the normal (PATH-allowed) lookup.
    func availability() -> Availability {
        if let path = locator.locate() { return .installed(path: path) }
        return .missing
    }

    // MARK: Capture

    /// Capture stdout + stderr of one command. Blocks until the child exits —
    /// call off the main thread. A `.mo` target that can't be resolved runs
    /// `/usr/bin/false`, so a missing binary degrades to a nonzero exit instead
    /// of throwing, exactly as `MoleCLI.run` did. Times out per `command`; on
    /// timeout the child is killed and `Captured.timedOut` is set (the run
    /// returns a nonzero exit, it does NOT throw for the timeout).
    @discardableResult
    func capture(_ command: MoCommand) throws -> Captured {
        let executable: String
        switch command.target {
        case .mo:
            // `/usr/bin/false` mirrors `MoleCLI.run`'s fallback: an unresolved
            // `mo` yields a clean nonzero exit, never a crash.
            executable = locator.locate() ?? "/usr/bin/false"
        case .executable(let path):
            executable = path
        }

        let result = try MoleProcess.capture(
            executable: executable,
            args: command.args,
            stdin: command.stdin,
            environment: command.environment,
            timeout: command.timeout,
            port: processPort
        )
        return Captured(
            stdout: result.stdout,
            stderr: result.stderr,
            exitCode: result.exitCode,
            timedOut: result.timedOut
        )
    }

    // MARK: Elevated one-shot

    /// Run `mo <args>` ONCE with administrator rights, returning the classified
    /// outcome (`.authCancelled` distinguished from a command that ran and
    /// failed). Resolves through the TRUSTED locations only — never PATH — and
    /// routes through the same `PrivilegeBroker` the one-shot config commands
    /// (`touchid enable/disable`) already use. No `mo` in a trusted spot →
    /// `.launchFailed`, matching the old guard.
    func runElevatedClassified(args: [String]) -> ElevatedOutcome {
        guard let mo = locator.locateTrusted() else { return .launchFailed }
        return privilegeBroker.openElevated(executable: mo, args: args)
    }
}
