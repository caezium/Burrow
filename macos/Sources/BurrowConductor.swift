//
//  BurrowConductor.swift
//  Burrow
//
//  Runs the bundled `burrow` CONDUCTOR (caezium/burrow-cli) and returns parsed envelopes.
//  The conductor wraps the engine with the stable Burrow contract — one JSON envelope per
//  command, NDJSON streaming for progress — so the GUI parses ONE shape instead of each call
//  site re-implementing "spawn the engine → parse its output".
//
//  Resolution: the conductor ships beside the engine in the app bundle (Resources/burrow, from
//  bundle-burrow.sh); we point it at the sibling-bundled engine via BURROW_ENGINE_DIR. Spawning
//  reuses the tested capture stack (MoEngine + MoleProcess) via a `.executable(path)` target —
//  no new process plumbing. When the conductor isn't bundled (dev/CI builds without the
//  vendor/burrow-cli submodule) `isAvailable` is false and callers fall back to the direct engine.
//

import Foundation

enum BurrowConductor {

    // MARK: - Resolution

    /// The bundled conductor binary, or nil if this build didn't ship one — callers then fall
    /// back to the direct engine (MoEngine).
    static func executableURL() -> URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let burrow = res.appendingPathComponent("burrow")
        return FileManager.default.isExecutableFile(atPath: burrow.path) ? burrow : nil
    }

    /// The bundled engine directory the conductor should target (Resources/engine, from
    /// bundle-engine.sh), or nil if the engine isn't bundled either.
    static func engineDir() -> URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let dir = res.appendingPathComponent("engine")
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir)
        return (exists && isDir.boolValue) ? dir : nil
    }

    /// The bundled `fclones` sidecar (Resources/fclones, from bundle-fclones.sh), or nil if this
    /// build didn't ship one. `burrow dupes` shells out to fclones; without a bundled copy it falls
    /// back to a `$BURROW_FCLONES`/PATH fclones, and if none exists the Duplicates pane shows
    /// "fclones not found".
    static func fclonesURL() -> URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let fclones = res.appendingPathComponent("fclones")
        return FileManager.default.isExecutableFile(atPath: fclones.path) ? fclones : nil
    }

    /// True when a bundled conductor is present. Call sites branch on this to decide between the
    /// conductor path and the legacy direct-engine path.
    static var isAvailable: Bool { executableURL() != nil }

    // MARK: - Pure command shaping (unit-tested)

    /// The argv a JSON one-shot is invoked with: `<command> [args…] --json`. `--json` forces the
    /// stable envelope even when stdout is a TTY.
    static func argv(command: String, args: [String]) -> [String] {
        [command] + args + ["--json"]
    }

    /// The environment for a conductor run: the inherited environment plus BURROW_ENGINE_DIR
    /// pointing at the bundled engine (the conductor otherwise walks up looking for a sibling
    /// `burrow-engine/`, which the app layout — Resources/engine — deliberately doesn't match).
    static func environment(engineDir: URL?) -> [String: String] {
        // Fully qualified: the Burrow module has its own `ProcessInfo` (a status model), which
        // would otherwise shadow Foundation's here.
        var env = Foundation.ProcessInfo.processInfo.environment
        if let dir = engineDir { env["BURROW_ENGINE_DIR"] = dir.path }
        // Point the conductor at the bundled fclones for `dupes` — but don't OVERRIDE a user's
        // own $BURROW_FCLONES if they set one (they may prefer a newer/system fclones).
        if env["BURROW_FCLONES"] == nil, let fclones = fclonesURL() {
            env["BURROW_FCLONES"] = fclones.path
        }
        return env
    }

    // MARK: - Capture (one-shot JSON commands)

    /// Run `burrow <command> [args…] --json` and return the parsed success envelope. Reuses the
    /// tested capture runner (timeout + Captured result) by targeting the conductor's exact path.
    /// Throws `BurrowConductorError.notBundled` when no conductor is bundled, or `.engine(kind:
    /// message:)` on a timeout, an empty/garbled response, or an `ok:false` envelope — carrying
    /// the conductor's classified error kind so the UI can react (permissions vs unavailable vs …).
    static func capture(_ command: String,
                        _ args: [String] = [],
                        timeout: TimeInterval = 300,
                        engine: MoEngine = .shared) throws -> BurrowEnvelope {
        guard let exe = executableURL() else { throw BurrowConductorError.notBundled }
        let cmd = MoCommand(
            target: .executable(exe.path),
            args: argv(command: command, args: args),
            environment: environment(engineDir: engineDir()),
            timeout: timeout)
        let result = try engine.capture(cmd)

        // A timeout or missing binary degrades to a nonzero exit with no stdout (the capture
        // runner never throws for those) — surface it before we try to parse an empty string.
        guard !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if result.timedOut {
                throw BurrowConductorError.engine(kind: "process_failed",
                                                  message: "burrow \(command) timed out")
            }
            throw BurrowConductorError.engine(kind: "process_failed",
                                              message: "burrow \(command) produced no output (exit \(result.exitCode))")
        }

        let envelope = try BurrowEnvelope.parse(result.stdout)
        if !envelope.ok {
            throw BurrowConductorError.engine(
                kind: envelope.error?.kind ?? "error",
                message: envelope.error?.message ?? "burrow \(command) failed")
        }
        return envelope
    }

    // MARK: - Streaming clean/optimize (opt-in)

    /// Default ON (hand-validated on a real build): streaming clean/optimize route through the
    /// bundled conductor (`burrow <cmd> --stream`), falling back to the direct engine on any
    /// miss. Kill-switch:
    ///   `defaults write dev.caezium.Burrow BurrowStreamViaConductor -bool NO`
    static var streamingEnabled: Bool {
        (UserDefaults.standard.object(forKey: "BurrowStreamViaConductor") as? Bool) ?? true
    }

    /// Default OFF: the per-child walk stays the default because its "scanning <child> · k/N"
    /// progress tells the user WHAT is being measured. The single streamed `analyze --progress` is
    /// faster but its only signal is a running file count (the engine's per-tick path is usually
    /// empty), which reads as opaque. Opt into the fast-but-opaque path with:
    ///   `defaults write dev.caezium.Burrow BurrowStreamAnalyze -bool YES`
    static var streamingAnalyzeEnabled: Bool {
        (UserDefaults.standard.object(forKey: "BurrowStreamAnalyze") as? Bool) ?? false
    }

    /// The streamable engine commands the conductor forwards with `--stream`. purge/installer are
    /// an interactive TUI (PTY) and uninstall is irreversible + matcher-gated — those stay direct.
    private static let streamableCommands: Set<String> = ["clean", "optimize"]

    /// Translate a `mo` streaming argv into the conductor equivalent. `mo` runs LIVE by default and
    /// `--dry-run` previews; burrow INVERTS that (dry-run by default, `--apply` to execute). So we
    /// drop `--dry-run` (preview → burrow's default) or add `--apply` (live), then force `--stream`
    /// so the engine's output flows line-by-line through the pipe instead of one buffered envelope.
    /// Pure + unit-tested — the semantic mapping is the safety-critical part, so it's verified.
    static func streamArgv(fromMo moArgs: [String]) -> [String] {
        let isPreview = moArgs.contains("--dry-run")
        var out = moArgs.filter { $0 != "--dry-run" }
        if !isPreview { out.append("--apply") }   // mo-live → burrow needs --apply
        out.append("--stream")
        return out
    }

    /// When the switch is on AND a conductor is bundled AND this is a non-elevated streamable
    /// command, the (burrow path, translated argv) to spawn instead of `mo`. Otherwise nil, so the
    /// caller keeps the direct-engine path UNCHANGED. Elevated runs (osascript, fresh env that
    /// wouldn't inherit BURROW_ENGINE_DIR) deliberately stay on `mo`.
    static func streamOverride(moArgs: [String], elevated: Bool) -> (executable: String, arguments: [String])? {
        guard streamingEnabled,
              !elevated,
              let command = moArgs.first,
              streamableCommands.contains(command),
              let burrow = executableURL()?.path else { return nil }
        return (burrow, streamArgv(fromMo: moArgs))
    }
}

/// Why a conductor run couldn't produce a usable success envelope.
enum BurrowConductorError: Error, LocalizedError {
    /// No `burrow` binary is bundled — the caller should fall back to the direct engine.
    case notBundled
    /// The conductor ran but reported (or amounted to) a failure; `kind` is the classified
    /// reason from the envelope (permission_denied | unsupported | not_found | process_failed | error).
    case engine(kind: String, message: String)

    var errorDescription: String? {
        switch self {
        case .notBundled:
            return "the bundled burrow conductor is unavailable"
        case .engine(let kind, let message):
            return "\(message) [\(kind)]"
        }
    }
}
