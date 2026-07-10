//
//  AnalyzeProgress.swift
//  Burrow
//
//  Parser for `burrow analyze --progress` — the engine's live scan feed. The stream is NDJSON:
//  `{type:progress,files,dirs,bytes,path}` per tick during the concurrent walk, then a terminal
//  `{type:result,data:<analysis>}` whose `data` is exactly what `analyze --json` returns.
//
//  This is the PURE, unit-tested core for a live-filling treemap (#12): a streaming reader maps
//  each line through `parse`, drives a progress indicator off `.progress`, and hands `.result`'s
//  bytes to `DiskScanner.parse`. Kept dependency-free + testable so the reader and the UI rework
//  (which restructures AnalyzeView's currently-synchronous scan flow) can be built on a verified base.
//

import Foundation

enum AnalyzeProgressEvent: Equatable {
    /// A live counter tick during the scan.
    case progress(files: Int, dirs: Int, bytes: Int64, path: String)
    /// The terminal event: the analysis payload as raw bytes (same shape as `analyze --json`),
    /// ready for `DiskScanner.parse`.
    case result(Data)

    /// Parse one NDJSON line. Returns nil for blank lines and unknown/forward-compatible `type`s
    /// so the reader tolerates keep-alive blanks and new event kinds without breaking.
    static func parse(line: String) -> AnalyzeProgressEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return nil }

        switch type {
        case "progress":
            return .progress(
                files: Self.int(obj["files"]),
                dirs: Self.int(obj["dirs"]),
                bytes: Self.int64(obj["bytes"]),
                path: obj["path"] as? String ?? "")
        case "result":
            // Re-serialize the payload so DiskScanner.parse reads exactly what analyze --json emits.
            guard let payload = obj["data"],
                  let bytes = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
            return .result(bytes)
        default:
            return nil
        }
    }

    private static func int(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        return 0
    }

    private static func int64(_ v: Any?) -> Int64 {
        if let i = v as? Int64 { return i }
        if let i = v as? Int { return Int64(i) }
        if let d = v as? Double { return Int64(d) }
        return 0
    }
}
