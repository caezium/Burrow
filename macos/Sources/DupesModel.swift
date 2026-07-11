//
//  DupesModel.swift
//  Burrow
//
//  Typed shape + pure parser for `burrow dupes <dir> --json`: the conductor
//  forwards fclones' group report verbatim in the envelope's `data`, and the
//  GUI reads only the spine — `header.stats.redundant_file_size`,
//  `groups[].file_len`, `groups[].files[]` — so any other fclones field can
//  drift upstream without breaking us.
//
//  Parsed with JSONSerialization (like DiskScanner / BurrowEnvelope), not
//  Codable: byte counts must stay integer-exact — a 5 GB group is
//  5_000_000_123 B, not 5.000000123e9.
//

import Foundation

/// One duplicate group: N identical files of `fileLen` bytes each.
struct DupeGroup: Identifiable, Equatable {
    /// Size of ONE copy, in bytes (fclones `file_len`).
    let fileLen: Int64
    /// Absolute paths of every identical copy (fclones `files`), ≥ 2 in
    /// any group fclones emits.
    let files: [String]

    /// Stable identity for SwiftUI lists — the first path is unique per group.
    var id: String { files.first ?? "\(fileLen)" }

    /// Bytes reclaimable from this group if all but one copy went away.
    var redundantBytes: Int64 { fileLen * Int64(max(0, files.count - 1)) }
}

/// A whole dupes scan: groups largest-reclaim first, plus the report's
/// redundant-byte total.
struct DupesReport: Equatable {
    let groups: [DupeGroup]
    /// Total reclaimable bytes (fclones `header.stats.redundant_file_size`;
    /// computed from the groups when the header doesn't carry it).
    let redundantBytes: Int64

    /// Decode fclones' group-report JSON. Loose everywhere except the spine:
    /// a group missing `file_len` or `files` is dropped, a payload that isn't
    /// a JSON object is nil (never a crash on garbled conductor output).
    static func parse(_ data: Data) -> DupesReport? {
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        var groups: [DupeGroup] = []
        let groupsRaw = raw["groups"] as? [[String: Any]] ?? []
        groups.reserveCapacity(groupsRaw.count)
        for g in groupsRaw {
            let fileLen = (g["file_len"] as? Int64) ?? Int64(g["file_len"] as? Int ?? -1)
            guard fileLen >= 0,
                  let files = g["files"] as? [String], !files.isEmpty else { continue }
            groups.append(DupeGroup(fileLen: fileLen, files: files))
        }
        // Largest reclaim first — the group worth acting on leads the list.
        groups.sort { $0.redundantBytes > $1.redundantBytes }

        // Prefer the header's authoritative total; fall back to the sum of
        // per-group waste when stats are absent (or drifted).
        let stats = (raw["header"] as? [String: Any])?["stats"] as? [String: Any]
        let headerTotal = (stats?["redundant_file_size"] as? Int64)
            ?? (stats?["redundant_file_size"] as? Int).map(Int64.init)
        let total = headerTotal ?? groups.reduce(Int64(0)) { $0 + $1.redundantBytes }

        return DupesReport(groups: groups, redundantBytes: total)
    }
}

/// Which copies the user has ticked for removal — the same shape as CleanSelection so the
/// Duplicates pane reads like the Clean review checklist. Pure + tested. THE invariant:
/// every group always keeps at least one unticked copy (removing all copies of a file is
/// data loss, not deduplication) — a toggle that would violate it is refused.
struct DupesSelection: Equatable {
    private(set) var ticked: Set<String>

    /// Default selection: every copy EXCEPT each group's first (fclones lists its keep
    /// choice first) — the standard "keep one of each" starting point.
    init(report: DupesReport) {
        var t = Set<String>()
        for g in report.groups {
            for f in g.files.dropFirst() {
                t.insert(f)
            }
        }
        ticked = t
    }

    func isTicked(_ path: String) -> Bool { ticked.contains(path) }

    /// Toggle one copy. Ticking is refused (no-op) when it would select EVERY copy of the
    /// path's group — the keep-one guard.
    mutating func toggle(_ path: String, in report: DupesReport) {
        if ticked.contains(path) {
            ticked.remove(path)
            return
        }
        guard let group = report.groups.first(where: { $0.files.contains(path) }) else { return }
        let wouldBeTicked = group.files.filter { ticked.contains($0) || $0 == path }
        if wouldBeTicked.count >= group.files.count { return } // keep-one guard
        ticked.insert(path)
    }

    /// Is `path` the group's LAST unticked copy (the one the guard is protecting)?
    func isKeptCopy(_ path: String, in group: DupeGroup) -> Bool {
        !ticked.contains(path) && selectedCount(in: group) == group.files.count - 1
    }

    enum GroupState { case all, mixed, none }

    /// Tri-state over the group's selectable maximum (all copies minus the kept one).
    func groupState(_ group: DupeGroup) -> GroupState {
        let n = selectedCount(in: group)
        if n == 0 { return .none }
        return n >= group.files.count - 1 ? .all : .mixed
    }

    /// Group checkbox: at-max -> none; anything else -> the default all-but-first.
    mutating func toggleGroup(_ group: DupeGroup) {
        if groupState(group) == .all {
            for f in group.files { ticked.remove(f) }
        } else {
            for f in group.files { ticked.remove(f) }
            for f in group.files.dropFirst() { ticked.insert(f) }
        }
    }

    func selectedCount(in group: DupeGroup) -> Int {
        group.files.filter { ticked.contains($0) }.count
    }

    func selectedBytes(in report: DupesReport) -> Int64 {
        report.groups.reduce(Int64(0)) { sum, g in
            sum + g.fileLen * Int64(selectedCount(in: g))
        }
    }

    func selectedPaths(in report: DupesReport) -> [String] {
        report.groups.flatMap { g in g.files.filter { ticked.contains($0) } }
    }

    var isEmpty: Bool { ticked.isEmpty }
}

/// The conductor's dedupe PREVIEW (`burrow dupes dedupe <dir>`, no --apply): either
/// fclones' own dry-run plan (`cp -c <src> <dst>` per clone — exactly what --apply
/// executes) or a skip (nothing actionable). Parsed loose, like DupesReport.
struct DedupePreview: Equatable {
    /// Actionable duplicate groups the plan covers (0 when skipped).
    let groups: Int
    /// The dry-run command lines (`cp -c …`), empty when skipped.
    let plan: [String]
    /// True when the conductor skipped the action (protected / cross-volume / singletons).
    let skipped: Bool

    static func parse(_ data: Data) -> DedupePreview? {
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        if raw["skipped"] as? Bool == true {
            return DedupePreview(groups: 0, plan: [], skipped: true)
        }
        guard raw["preview"] as? Bool == true else { return nil }
        let groups = (raw["groups"] as? Int) ?? 0
        let plan = raw["plan"] as? [String] ?? []
        return DedupePreview(groups: groups, plan: plan, skipped: false)
    }
}
