//
//  MoEngine.swift
//  Burrow
//
//  The single entry point to the `mo` runners (issue #48). Burrow grew several
//  process shapes — capture (small one-shot commands), streaming (clean /
//  optimize), and interactive PTY (purge / installer) — each found and spawned
//  at its own call site. `MoEngine` is the ONE facade callers reach for so
//  "how do I run mo?" has a single answer.
//
//  Three shapes hang off the facade as methods — CAPTURE, DISCOVERY, and
//  interactive PTY — each delegating to the existing, tested port; the facade
//  does NOT reimplement any spawn or PTY internals. STREAMING is reached
//  through the EXPOSED `streamPort` (not a wrapper method): `OperationFlow`
//  holds the `any ProcessPort` to drive its own reduce/notify/auth-cancel loop,
//  so the facade hands it the production port rather than the stream. The
//  one-shot ELEVATED path is NOT on the facade — it stays in
//  `SystemPrivilegeBroker.openElevated` (see `Connectivity.run`), the path
//  production has always used.
//
//  Behavior is preserved exactly: a `capture(_:)` call produces the same argv,
//  stdin, environment, timeout, and result fields that `MoleCLI.run` did, and
//  `interactive()` vends a FRESH `PTYTask` whose raw, escape-preserving output
//  the `SelectionSession` reducer depends on. The ports are injected
//  (production defaults are the real ones) so every shape is testable with
//  scripted fakes, matching the seams `MoleCLI`/`MoleProcess`/`ProcessPort`/
//  `PTYPort` already expose.
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
/// locations, cached + revalidated); tests inject a fake to drive resolution
/// deterministically.
protocol MoLocator: Sendable {
    /// The `mo` for a normal (unelevated) run — PATH allowed.
    func locate() -> String?
}

/// The production locator: delegates to `MoleCLI`'s existing discovery so the
/// caching/revalidation stays in one place.
struct SystemMoLocator: MoLocator {
    func locate() -> String? { MoleCLI.findExecutable() }
}

// MARK: - Facade

/// The one runner facade. The `mo` process shapes callers reach for — capture,
/// discovery, and interactive PTY — hang off this type as methods, and the
/// streaming port is exposed for `OperationFlow`; the ports are injected so
/// every path is testable in memory.
final class MoEngine {
    private let processPort: MoleProcessPort
    private let locator: MoLocator
    /// The streaming-op spawn port (clean / optimize). Exposed so
    /// `OperationFlow`, which holds an `any ProcessPort` and drives its own
    /// reduce/notify/auth-cancel loop, can take the facade's production port as
    /// its default without the facade reaching into that loop.
    let streamPort: ProcessPort
    /// Vends a FRESH interactive PTY session per call. A factory, not a shared
    /// instance, because a `PTYTask` is stateful per launch and each selection
    /// host (purge / installer) must own its own — two hosts sharing one pty
    /// would stomp each other's child and keystrokes.
    private let makePTY: @Sendable () -> PTYPort

    /// Production singleton. Wraps the real capture runner, `MoleCLI` discovery,
    /// the real streaming port, and the real PTY — the exact spawn paths the
    /// migrated call sites used before, just funneled through one type.
    static let shared = MoEngine()

    init(processPort: MoleProcessPort = SystemMoleProcess(),
         locator: MoLocator = SystemMoLocator(),
         // Elevated streaming runs prefer the privileged helper when it is
         // registered, approved, and build-matched; everything else — and any
         // elevated run the helper doesn't recognise — falls through to the
         // osascript port unchanged. See `PrivilegeRoute`.
         streamPort: ProcessPort = HelperAwareProcessPort(),
         makePTY: @escaping @Sendable () -> PTYPort = { PTYTask() }) {
        self.processPort = processPort
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

    // MARK: Status stream (mo status --watch, V1.44+)

    /// Stream `mo status --watch` as process events — each `.line` is one
    /// NDJSON status snapshot; `.exited` ends the stream (the caller falls back
    /// to polling). Runs indefinitely (no timeout); cancelling the consuming
    /// task terminates the child via the stream's onTermination. Returns nil if
    /// `mo` can't be resolved. Reuses the streaming port that drives
    /// clean/optimize, so there's no new spawn plumbing.
    func statusWatch() -> AsyncStream<ProcessEvent>? {
        guard let path = locator.locate() else { return nil }
        let spec = ProcessSpec(executable: path, arguments: ["status", "--watch"],
                               stdin: nil, elevated: false, timeout: nil)
        return streamPort.events(spec)
    }
}
