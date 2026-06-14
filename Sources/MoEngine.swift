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
//  All FOUR process shapes now hang off this one facade (issue #48 complete):
//  CAPTURE + ELEVATED + DISCOVERY (slice 2) plus STREAMING (clean / optimize)
//  and interactive PTY (purge / installer), added here. Every shape delegates
//  to the existing, tested port — the facade does NOT reimplement any spawn,
//  elevation, or PTY internals; it just funnels "how do I run mo?" to one type.
//
//  Behavior is preserved exactly: a `capture(_:)` call produces the same argv,
//  stdin, environment, timeout, and result fields that `MoleCLI.run` did;
//  `runElevatedClassified` routes through the same `PrivilegeBroker` against
//  the same trusted-location resolution; `stream(_:)` hands back the SAME
//  `AsyncStream<ProcessEvent>` `SystemProcessPort` already produced (the
//  elevated-osascript-tail, auth-cancel classification, and line-splitting are
//  untouched); and `interactive()` vends a FRESH `PTYTask` whose raw,
//  escape-preserving output the `SelectionSession` reducer depends on. The
//  ports are injected (production defaults are the real ones) so every shape is
//  testable with scripted fakes, matching the seams `MoleCLI`/`MoleProcess`/
//  `PrivilegeBroker`/`ProcessPort`/`PTYPort` already expose.
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

/// The one runner facade. All four `mo` process shapes — capture, elevated
/// one-shot, streaming, and interactive PTY — plus discovery hang off this
/// type; the ports are injected so every path is testable in memory.
final class MoEngine {
    private let processPort: MoleProcessPort
    private let privilegeBroker: PrivilegeBroker
    private let locator: MoLocator
    /// The streaming-op spawn port (clean / optimize). Exposed (not just used
    /// by `stream(_:)`) so `OperationFlow`, which holds an `any ProcessPort`
    /// and drives its own reduce/notify/auth-cancel loop, can take the facade's
    /// production port as its default without the facade reaching into that loop.
    let streamPort: ProcessPort
    /// Vends a FRESH interactive PTY session per call. A factory, not a shared
    /// instance, because a `PTYTask` is stateful per launch and each selection
    /// host (purge / installer) must own its own — two hosts sharing one pty
    /// would stomp each other's child and keystrokes.
    private let makePTY: @Sendable () -> PTYPort

    /// Production singleton. Wraps the real capture runner, the real osascript
    /// broker, `MoleCLI` discovery, the real streaming port, and the real PTY —
    /// the exact spawn paths the migrated call sites used before, just funneled
    /// through one type.
    static let shared = MoEngine()

    init(processPort: MoleProcessPort = SystemMoleProcess(),
         privilegeBroker: PrivilegeBroker = SystemPrivilegeBroker(),
         locator: MoLocator = SystemMoLocator(),
         streamPort: ProcessPort = SystemProcessPort(),
         makePTY: @escaping @Sendable () -> PTYPort = { PTYTask() }) {
        self.processPort = processPort
        self.privilegeBroker = privilegeBroker
        self.locator = locator
        self.streamPort = streamPort
        self.makePTY = makePTY
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

    // MARK: Streaming (clean / optimize)

    /// Stream a long-running `mo` op line-by-line. Hands the spec straight to
    /// the injected streaming port and returns its `AsyncStream<ProcessEvent>`
    /// unchanged — the plain/elevated spawn, the osascript temp-log tail, the
    /// ANSI strip + line split, and the auth-cancel classification all stay in
    /// `SystemProcessPort`. Cancelling the consuming task still terminates the
    /// child via the stream's `onTermination`, exactly as before. The caller
    /// (`OperationFlow`) owns the reduce/notify/cancel loop; this is only the
    /// spawn source.
    func stream(_ spec: ProcessSpec) -> AsyncStream<ProcessEvent> {
        streamPort.events(spec)
    }

    // MARK: Interactive PTY (purge / installer)

    /// Open a FRESH interactive PTY session for a selection TUI (`mo purge` /
    /// `mo installer`). Each call returns its own `PTYPort` because the session
    /// is stateful (one child per launch, mutable callbacks) and each host must
    /// own its own. The session delivers RAW, escape-preserving output — the
    /// `SelectionSession` reducer parses Mole's redraw frames, so nothing here
    /// strips or rewrites the bytes.
    func interactive() -> PTYPort {
        makePTY()
    }
}
