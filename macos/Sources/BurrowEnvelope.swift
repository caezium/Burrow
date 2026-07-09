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
        /// permission_denied | unsupported | not_found | process_failed | error
        let kind: String?
        let message: String?
        let platform: String?
        /// The unavailable feature, set when kind == "unsupported".
        let feature: String?
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
