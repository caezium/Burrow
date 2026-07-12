//
//  NetModel.swift
//  Burrow
//
//  Typed shape + pure parser for `burrow net --json`: the conductor emits
//  {count, by_total_bytes:[{name, pid, bytes_in, bytes_out, total,
//  metric_source, metric_note?}]}. On macOS the rows are nettop BYTE
//  counters (metric_source "macos_nettop_bytes"); other platforms may
//  degrade to connection counts and say so in metric_note — the pane
//  surfaces that caveat instead of mislabeling counts as bytes.
//
//  Parsed with JSONSerialization (like DupesModel / DiskScanner), not
//  Codable: byte counts must stay integer-exact, and garbled conductor
//  output parses to nil, never a crash.
//

import Foundation

/// One process's network attribution for the sample window.
struct NetRow: Identifiable, Equatable {
    let name: String
    let pid: Int
    let bytesIn: Int64
    let bytesOut: Int64
    /// bytes_in + bytes_out on macOS; a connection count on degraded sources.
    let total: Int64
    /// Where the numbers came from (e.g. "macos_nettop_bytes").
    let metricSource: String
    /// Caveat when the source isn't byte counters (Windows fallbacks).
    let metricNote: String?

    /// Stable identity for SwiftUI lists — name+pid is unique per sample.
    var id: String { "\(name).\(pid)" }
}

/// A whole net sample: rows ranked by total descending.
struct NetReport: Equatable {
    let rows: [NetRow]

    /// The first metric caveat across the rows (nil on healthy macOS
    /// byte-counter samples) — shown once under the table, not per row.
    var note: String? { rows.lazy.compactMap(\.metricNote).first }

    /// Decode the net JSON. Loose everywhere except the spine: a row missing
    /// `name` is dropped, absent byte fields degrade to 0 (total recomputed
    /// from in+out when missing), and a payload that isn't a JSON object is
    /// nil (never a crash).
    static func parse(_ data: Data) -> NetReport? {
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        func int64(_ v: Any?) -> Int64? {
            (v as? Int64) ?? (v as? Int).map(Int64.init)
        }

        var rows: [NetRow] = []
        let rowsRaw = raw["by_total_bytes"] as? [[String: Any]] ?? []
        rows.reserveCapacity(rowsRaw.count)
        for r in rowsRaw {
            guard let name = r["name"] as? String, !name.isEmpty else { continue }
            let bytesIn = int64(r["bytes_in"]) ?? 0
            let bytesOut = int64(r["bytes_out"]) ?? 0
            rows.append(NetRow(
                name: name,
                pid: (r["pid"] as? Int) ?? 0,
                bytesIn: bytesIn,
                bytesOut: bytesOut,
                total: int64(r["total"]) ?? (bytesIn + bytesOut),
                metricSource: (r["metric_source"] as? String) ?? "",
                metricNote: r["metric_note"] as? String))
        }
        // The CLI ranks by total already — re-sort defensively (stable on
        // ties so the CLI's name/pid tiebreak survives).
        let ranked = rows.enumerated().sorted {
            let (l, r) = ($0.element.total, $1.element.total)
            return l != r ? l > r : $0.offset < $1.offset
        }.map(\.element)

        return NetReport(rows: ranked)
    }
}
