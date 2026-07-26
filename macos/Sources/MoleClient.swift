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

    /// `listAppsResult`'s outcome — kept distinct from a plain `[InstalledApp]` because an empty
    /// ARRAY collapses two very different situations: "the lookup failed" (the bundled engine
    /// has no `--list` at all, post-repoint — every real call today) and "the lookup succeeded
    /// and there are genuinely no apps". A caller (a human reading the Software tab, or an agent
    /// deciding whether to keep looking for something to uninstall) needs to tell those apart
    /// rather than treat both as "no apps installed".
    enum ListAppsResult {
        case ok([InstalledApp])
        case unavailable
    }

    /// Installed apps + the exact names `mo uninstall` accepts, distinguishing a failed lookup
    /// from a genuinely empty result. Sizes can take a while on a full /Applications, so callers
    /// give it room.
    static func listAppsResult(timeout: TimeInterval = 180) -> ListAppsResult {
        guard let res = try? MoEngine.shared.capture(
                MoCommand(target: .mo, args: ["uninstall", "--list"], timeout: timeout)),
              res.exitCode == 0 else { return .unavailable }
        return .ok(parseApps(Data(res.stdout.utf8)))
    }

    /// Convenience for callers that don't need to distinguish "couldn't check" from "genuinely
    /// empty" — both collapse to `[]`. Prefer `listAppsResult` wherever the caller can act on, or
    /// must surface, that distinction (see `SoftwareModel.fetch`, `ToolCatalog.callListApps`).
    static func listApps(timeout: TimeInterval = 180) -> [InstalledApp] {
        if case .ok(let apps) = listAppsResult(timeout: timeout) { return apps }
        return []
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

    /// Parse a human size string ("1.5GB", "250MB", "--") into bytes. Forwards
    /// to the shared `Fmt.parseSize` (single source of truth, shared with
    /// `CleanList.parseSize`); kept as a named entry so the typed-row decode
    /// above and `MoleClientTests` read by intent at the call site.
    static func parseSize(_ s: String) -> Int64 { Fmt.parseSize(s) }

    // MARK: - Other commands (delegate to the existing tested parsers)

    /// Past cleanup sessions (`mo history --json`).
    static func history() -> [HistorySession] {
        MoleHistory.load()
    }

}
