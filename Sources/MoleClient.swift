//
//  MoleClient.swift
//  Burrow
//
//  The typed `mo` command surface: one place that knows how each subcommand is
//  invoked and how its output maps to a typed value. Built on the capture
//  runner (`MoleCLI.run`); the parsing is pure so it's unit-tested against
//  captured output. Views and the MCP server call this instead of each
//  re-implementing "spawn mo X → parse".
//
//  (Note: the SnapshotProducer still keeps Mole's raw `status` JSON — it stores and
//  patches the text — so it doesn't go through `status()` here.)
//

import Foundation

enum MoleClient {

    // MARK: - Installed apps (`mo uninstall --list`)

    /// Installed apps + the exact names `mo uninstall` accepts. Sizes can take a
    /// while on a full /Applications, so callers give it room.
    static func listApps(timeout: TimeInterval = 180) -> [InstalledApp] {
        guard let res = try? MoEngine.shared.capture(
                MoCommand(target: .mo, args: ["uninstall", "--list"], timeout: timeout)),
              res.exitCode == 0 else { return [] }
        return parseApps(Data(res.stdout.utf8))
    }

    /// Pure parser for `mo uninstall --list` JSON. Drops rows without the fields
    /// needed to act on them (name + path).
    static func parseApps(_ data: Data) -> [InstalledApp] {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let name = d["name"] as? String,
                  let path = d["path"] as? String else { return nil }
            let sizeStr = d["size"] as? String ?? "--"
            return InstalledApp(
                id: (d["bundle_id"] as? String).map { $0 + "|" + path } ?? path,
                name: name,
                bundleId: d["bundle_id"] as? String ?? "",
                source: d["source"] as? String ?? "App",
                uninstallName: d["uninstall_name"] as? String ?? name,
                path: path,
                sizeStr: sizeStr,
                sizeBytes: parseSize(sizeStr),
                lastUsed: nil)   // computed lazily, only when sorting by Recent
        }
    }

    /// Parse a human size string ("1.5GB", "250MB", "--") into bytes.
    static func parseSize(_ s: String) -> Int64 {
        let t = s.trimmingCharacters(in: .whitespaces).uppercased()
        if t == "--" || t.isEmpty { return 0 }
        let units: [(String, Double)] = [("TB", 1_099_511_627_776), ("GB", 1_073_741_824),
                                         ("MB", 1_048_576), ("KB", 1024), ("B", 1)]
        for (u, mult) in units where t.hasSuffix(u) {
            let num = Double(t.dropLast(u.count).trimmingCharacters(in: .whitespaces)) ?? 0
            return Int64(num * mult)
        }
        return Int64(Double(t) ?? 0)
    }

    // MARK: - Other commands (delegate to the existing tested parsers)

    /// Past cleanup sessions (`mo history --json`).
    static func history() -> [HistorySession] {
        MoleHistory.load()
    }

    /// A fresh system snapshot (`mo status --json`). Decodes to the typed model.
    /// The periodic producer does NOT use this — it keeps the raw JSON to store +
    /// patch — but one-shot readers can.
    static func status(timeout: TimeInterval = 8) -> MoleStatus? {
        guard let res = try? MoEngine.shared.capture(
                MoCommand(target: .mo, args: ["status", "--json"], timeout: timeout)),
              res.exitCode == 0,
              let s = try? JSONDecoder().decode(MoleStatus.self, from: Data(res.stdout.utf8))
        else { return nil }
        return s
    }
}
