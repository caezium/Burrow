//
//  MoleHistory.swift
//  Burrow
//
//  Thin wrapper around `mo history --json` — Mole's record of past
//  cleanup/optimize/uninstall sessions. Distinct from Burrow's own
//  metrics "History" (the SQLite sample series); this is the cleanup
//  activity log. We just spawn, parse, and return typed sessions.
//

import Foundation

struct HistorySession: Identifiable {
    let id = UUID()
    let command: String        // "clean", "optimize", "uninstall", …
    let startedAt: String
    let endedAt: String        // "" when the session didn't finish cleanly
    let items: Int
    let size: String           // human string from Mole, e.g. "2.93GB"
    let operationCount: Int
    let removed: Int
    let trashed: Int
    let skipped: Int
    let failed: Int

    var isComplete: Bool { !endedAt.isEmpty }
}

enum MoleHistory {
    /// Decode `mo history --json`. Loose: we only depend on `sessions[*]`
    /// and the fields we surface; unknown keys can drift upstream freely.
    static func parse(_ data: Data) -> [HistorySession] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = obj["sessions"] as? [[String: Any]] else { return [] }
        return sessions.map { s in
            let actions = s["actions"] as? [String: Any] ?? [:]
            return HistorySession(
                command: s["command"] as? String ?? "?",
                startedAt: s["started_at"] as? String ?? "",
                endedAt: s["ended_at"] as? String ?? "",
                items: intVal(s["items"]),
                size: s["size"] as? String ?? "",
                operationCount: intVal(s["operation_count"]),
                removed: intVal(actions["removed"]),
                trashed: intVal(actions["trashed"]),
                skipped: intVal(actions["skipped"]),
                failed: intVal(actions["failed"]))
        }
    }

    /// Run `mo history --json` and parse it. Synchronous — call off-main.
    static func load() -> [HistorySession] {
        guard let res = try? MoEngine.shared.capture(
                MoCommand(target: .mo, args: ["history", "--json"], timeout: 30)),
              res.exitCode == 0,
              let data = res.stdout.data(using: .utf8) else { return [] }
        return parse(data)
    }

    private static func intVal(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        return 0
    }
}
