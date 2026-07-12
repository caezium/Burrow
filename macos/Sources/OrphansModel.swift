//
//  OrphansModel.swift
//  Burrow
//
//  Typed shape + pure parser for `burrow orphans <dir> --json`: the conductor
//  emits {roots, installed_count, count, orphans:[{name, path, confidence,
//  evidence[], default_selected}]} and the GUI reads only that spine — extra
//  fields (inventory_sources, future evidence kinds) can drift upstream
//  without breaking us.
//
//  Parsed with JSONSerialization (like DupesModel / DiskScanner), not
//  Codable: loose everywhere except the spine, nil (never a crash) on
//  garbled conductor output.
//

import Foundation

/// One leftover candidate: an app-artifact-shaped file or folder that matches
/// no installed app.
struct OrphanHit: Identifiable, Equatable {
    let name: String
    /// Absolute path of the candidate.
    let path: String
    /// burrow-cli's confidence grade — "medium" (bundle-id-shaped, vendor
    /// signature) above "weak" (loose name); Windows also emits "low".
    let confidence: String
    /// Why it was flagged (e.g. "app-artifact-shaped",
    /// "not-matched-to-installed-inventory").
    let evidence: [String]
    /// Always false today (the scanner never preselects) — carried so a
    /// future acting pane inherits the CLI's judgement, not its own.
    let defaultSelected: Bool

    /// Stable identity for SwiftUI lists — paths are unique per scan.
    var id: String { path }
}

/// A whole leftover scan: hits strongest-confidence first, plus the scan's
/// roots and inventory size (the denominator that makes "orphan" meaningful).
struct OrphansReport: Equatable {
    let roots: [String]
    /// How many installed apps the scan matched against (0 = unknown).
    let installedCount: Int
    /// The CLI's own hit count (falls back to the parsed rows when absent).
    let count: Int
    let orphans: [OrphanHit]

    /// Rank a confidence tier for sorting: medium > low > weak > anything new.
    static func tierRank(_ confidence: String) -> Int {
        switch confidence {
        case "medium": return 0
        case "low":    return 1
        case "weak":   return 2
        default:       return 3
        }
    }

    /// Decode the orphans JSON. Loose everywhere except the spine: a hit
    /// missing `name` or `path` is dropped, missing confidence degrades to
    /// "weak", and a payload that isn't a JSON object is nil (never a crash).
    static func parse(_ data: Data) -> OrphansReport? {
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        var hits: [OrphanHit] = []
        let hitsRaw = raw["orphans"] as? [[String: Any]] ?? []
        hits.reserveCapacity(hitsRaw.count)
        for h in hitsRaw {
            guard let name = h["name"] as? String, !name.isEmpty,
                  let path = h["path"] as? String, !path.isEmpty else { continue }
            hits.append(OrphanHit(
                name: name,
                path: path,
                confidence: (h["confidence"] as? String) ?? "weak",
                evidence: (h["evidence"] as? [String]) ?? [],
                defaultSelected: (h["default_selected"] as? Bool) ?? false))
        }
        // Strongest evidence first; stable within a tier so the CLI's
        // name-sorted order survives.
        let ranked = hits.enumerated().sorted {
            let (l, r) = (tierRank($0.element.confidence), tierRank($1.element.confidence))
            return l != r ? l < r : $0.offset < $1.offset
        }.map(\.element)

        return OrphansReport(
            roots: (raw["roots"] as? [String]) ?? [],
            installedCount: (raw["installed_count"] as? Int) ?? 0,
            count: (raw["count"] as? Int) ?? ranked.count,
            orphans: ranked)
    }
}
