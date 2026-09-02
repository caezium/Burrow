//
//  BurrowEnvelope.swift
//  Burrow
//
//  The stable Burrow conductor envelope. Every `burrow <cmd> --json` response is ONE of
//  these: success carries `data` (the engine's JSON payload, verbatim), failure carries a
//  classified `error`. Consumers branch on a single top-level `ok` — one shape for every
//  command, regardless of which engine served it. Mirrors burrow-cli's src/output.rs
//  (caezium/burrow-cli#4) and the Windows BurrowEnvelope (#248).
//
//  Parsed with JSONSerialization (like DiskScanner / MoleHistory), not Codable: the engine's
//  `data` must round-trip to the command's own decoder WITHOUT the integer-vs-float precision
//  a Codable `Double` bridge would blur (health_score 92 must stay 92, not become 92.0).
//

import Foundation

/// The engine's classified failure kinds — the `error.kind` strings of an `ok:false` envelope
/// (burrow-engine `envelope.rs`). Spelled once, so a producer on this side (`BurrowEngine.capture`
/// synthesising a kind for a timeout) and a consumer branching on one use the same token.
enum ErrorKind: String {
    case permissionDenied = "permission_denied"
    case unsupported
    case notFound = "not_found"
    case processFailed = "process_failed"
    case invalidOutput = "invalid_output"
    case error
}

struct BurrowEnvelope {
    let ok: Bool
    let command: String?
    let burrowCli: String?
    /// The engine payload on success, as raw JSON bytes for the command's own decoder
    /// (JSONDecoder<MoleStatus>, DiskScanner.parse, …). nil on failure.
    let data: Data?
    /// The classified reason on failure. nil on success.
    let error: BurrowError?

    struct BurrowError {
        /// The classified kind, verbatim from the wire — see `ErrorKind` for the known values.
        let kind: String?
        let message: String?
        let platform: String?
        /// The unavailable feature, set when kind == "unsupported".
        let feature: String?

        /// `kind` as one of the engine's classified values; nil for an unknown or absent kind.
        var errorKind: ErrorKind? { kind.flatMap(ErrorKind.init(rawValue:)) }
    }

    enum ParseError: Error, LocalizedError {
        case notJSON
        case notAnObject
        var errorDescription: String? {
            switch self {
            case .notJSON: return "burrow output was not valid JSON"
            case .notAnObject: return "burrow envelope was not a JSON object"
            }
        }
    }

    /// Parse one conductor envelope. Throws if the output isn't a JSON object; otherwise
    /// returns the envelope to branch on via `.ok`. Does NOT throw on `ok:false` — that is a
    /// valid envelope the caller inspects through `.error`.
    static func parse(_ stdout: String) throws -> BurrowEnvelope {
        guard let raw = stdout.data(using: .utf8) else { throw ParseError.notJSON }
        let obj: Any
        do { obj = try JSONSerialization.jsonObject(with: raw) }
        catch { throw ParseError.notJSON }
        guard let dict = obj as? [String: Any] else { throw ParseError.notAnObject }

        // Re-serialize the `data` subtree back to bytes so the command's concrete decoder reads
        // exactly what the engine emitted (JSONSerialization preserves int-vs-float).
        var dataBytes: Data?
        if let d = dict["data"], !(d is NSNull) {
            dataBytes = try? JSONSerialization.data(withJSONObject: d)
        }
        var err: BurrowError?
        if let e = dict["error"] as? [String: Any] {
            err = BurrowError(
                kind: e["kind"] as? String,
                message: e["message"] as? String,
                platform: e["platform"] as? String,
                feature: dict["feature"] as? String)   // sibling of `error`, per the contract
        }
        return BurrowEnvelope(
            ok: dict["ok"] as? Bool ?? false,
            command: dict["command"] as? String,
            burrowCli: dict["burrow_cli"] as? String,
            data: dataBytes,
            error: err)
    }
}

// MARK: - Reading one capture, whichever binary answered
//
// The repoint moved WHERE a failure is reported. The legacy Go/bash `mo` wrote its diagnosis to
// STDERR and exited nonzero; the Rust engine classifies every failure it recognises into an
// `ok:false` envelope on STDOUT and writes NOTHING to stderr at all. Measured against
// burrow-engine @ 945000a, capturing the two streams separately:
//
//     analyze /nonexistent   exit=1  stdout=193B  stderr=0B   (kind: error)
//     dupes /nonexistent     exit=1  stdout=370B  stderr=0B   (kind: process_failed)
//     status --bogus         exit=2  stdout=165B  stderr=0B   (kind: error)
//     bogus-cmd              exit=2  stdout=164B  stderr=0B   (kind: error)
//
// (Goldens + re-capture recipe: plans/repoint-redo-groundtruth/engine-error*.golden.json. Note
// the exit codes are not uniform — 1 for a command that ran and failed, 2 for malformed argv —
// so nothing may key off a particular non-zero value.)
//
// So every call site that read `stderr` for the reason showed the user an empty reason — "mo
// analyze exited 2:" with nothing after the colon — while the message sat in the stdout it had
// just thrown away. Both binary shapes are still reachable (`EngineCLI.trustedExecutable` falls
// through bundled engine → installed burrow-engine → legacy `mo`, and `findExecutable` adds a
// PATH `mo` after that), so these read the envelope when there IS one and fall back to stderr
// when there isn't, rather than picking a side.
extension BurrowEnvelope {

    /// The envelope in `stdout`, or nil when this output is not one.
    ///
    /// `parse` succeeds on ANY JSON object, so it is NOT the discriminator: a bare
    /// `{"path":…,"entries":[…]}` from a legacy `mo --json` parses "fine" into an envelope
    /// whose `ok` merely defaulted to false, which would read as a failed run. `burrow_cli` is
    /// the discriminator — present on every real envelope, success AND failure, and emitted by
    /// no mo-family binary. Same test `ToolCatalog.cleanupHistoryResult`,
    /// `ToolCatalog.deletionsLogPath` and `UninstallPreview.fromEngineEnvelope` already make by
    /// hand; named once so a new call site cannot pick a weaker one.
    static func inOutput(_ stdout: String) -> BurrowEnvelope? {
        guard let envelope = try? parse(stdout), envelope.burrowCli != nil else { return nil }
        return envelope
    }

    /// True only when an envelope IS present and says the command failed. False for a legacy
    /// binary (no envelope) and false for a success envelope — so a caller can narrow a
    /// success into a failure with it, and can never be handed a spurious failure by a shape
    /// that simply isn't an envelope.
    static func reportsFailure(stdout: String) -> Bool {
        guard let envelope = inOutput(stdout) else { return false }
        return !envelope.ok
    }

    /// The classified failure kind (permission_denied | unsupported | not_found |
    /// process_failed | invalid_output | error) when the engine answered with an `ok:false`
    /// envelope; nil for a success, and nil for a legacy binary that has no kinds to report.
    static func failureKind(stdout: String) -> String? {
        guard let envelope = inOutput(stdout), !envelope.ok else { return nil }
        return envelope.error?.kind
    }

    /// The ONE reason string to show for a failed run, whichever binary answered. nil means the
    /// run genuinely said nothing — callers should then say so ("no error output") rather than
    /// print an empty reason after a colon, which is the bug this exists to close.
    ///
    /// Order, and why: the engine's classified `error.message` first, because when an envelope
    /// is present it is the only place the reason exists. Then stderr, which is where a legacy
    /// `mo` diagnoses. Then stdout, because some legacy paths print their complaint there
    /// instead (`SoftwareView`'s uninstall-failure alert already did exactly this fallback, and
    /// it is the one site that kept working through the repoint). ANSI is stripped from the two
    /// raw streams — mo decorates its output — and is a no-op on the engine's JSON.
    ///
    /// A failure envelope ANSWERS THE QUESTION even when its `message` is empty, so that case
    /// returns nil rather than falling through to the raw streams. The fall-through was the bug:
    /// the raw stdout of an `ok:false` run IS the envelope, so an engine that classified a
    /// failure without a message put the JSON itself on screen — `{"ok":false,"burrow_cli":…}` in
    /// an alert — which is strictly worse than the "no error output" sentence the callers already
    /// have ready for nil. stderr can't rescue it either: the engine writes nothing there.
    static func failureReason(stdout: String, stderr: String) -> String? {
        if let envelope = inOutput(stdout), !envelope.ok {
            let message = (envelope.error?.message ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? nil : message
        }
        for stream in [stderr, stdout] {
            let text = Ansi.strip(stream).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// The bytes a command's own decoder should read from one capture.
    ///
    /// Three shapes reach these call sites and only this distinction separates them:
    ///   * an `ok:true` envelope — the engine; the payload is `data`, and reading the envelope's
    ///     own top level instead finds no `entries`/`path`/`health_score` and decodes to an
    ///     EMPTY result, which is a confident wrong answer, not a visible failure;
    ///   * an `ok:false` envelope — a failure; nil, so no caller can decode an error envelope
    ///     as if it were a payload;
    ///   * no envelope — a legacy `mo`, whose own `--json` IS the payload; returned unchanged.
    ///
    /// Note this never turns a failure into a success: the only new success is unwrapping an
    /// envelope that already said `ok:true`.
    static func payloadBytes(stdout: String) -> Data? {
        guard let envelope = inOutput(stdout) else { return stdout.data(using: .utf8) }
        guard envelope.ok else { return nil }
        return envelope.data
    }
}
