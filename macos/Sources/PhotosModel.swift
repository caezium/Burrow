//
//  PhotosModel.swift
//  Burrow
//
//  Typed shape + pure parser for `burrow photos <dir> --json`: the conductor
//  emits {dir, threshold, similar_groups:[{paths:[String]}]} — each group is
//  burrow-cli's photos::Group, an OBJECT with a `paths` key (not a bare
//  array). The GUI reads only that spine.
//
//  Parsed with JSONSerialization (like DupesModel / DiskScanner), not
//  Codable: loose everywhere except the spine, nil (never a crash) on
//  garbled conductor output.
//

import Foundation

/// One cluster of visually-similar images (dHash within the scan threshold).
struct PhotoGroup: Identifiable, Equatable {
    /// Absolute paths of every member — ≥ 2 in any group the CLI emits.
    let paths: [String]

    /// Stable identity for SwiftUI lists — greedy clustering never puts one
    /// path in two groups, so the first member is unique per group.
    var id: String { paths.first ?? "" }
}

/// A whole similar-photos scan: groups largest first, plus the scanned dir
/// and the hamming threshold that produced them.
struct PhotosReport: Equatable {
    let dir: String
    /// dHash hamming-distance threshold (CLI default 10; 0 when absent).
    let threshold: Int
    let groups: [PhotoGroup]

    /// Decode the photos JSON. Loose everywhere except the spine: a group
    /// that isn't {paths:[...]} — or holds fewer than two paths — is dropped,
    /// and a payload that isn't a JSON object is nil (never a crash).
    static func parse(_ data: Data) -> PhotosReport? {
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        var groups: [PhotoGroup] = []
        let groupsRaw = raw["similar_groups"] as? [[String: Any]] ?? []
        groups.reserveCapacity(groupsRaw.count)
        for g in groupsRaw {
            guard let paths = g["paths"] as? [String], paths.count >= 2 else { continue }
            groups.append(PhotoGroup(paths: paths))
        }
        // Largest cluster first — the set with the most near-copies leads.
        // Stable within a size so the CLI's path-sorted order survives.
        let ranked = groups.enumerated().sorted {
            let (l, r) = ($0.element.paths.count, $1.element.paths.count)
            return l != r ? l > r : $0.offset < $1.offset
        }.map(\.element)

        return PhotosReport(
            dir: (raw["dir"] as? String) ?? "",
            threshold: (raw["threshold"] as? Int) ?? 0,
            groups: ranked)
    }
}
