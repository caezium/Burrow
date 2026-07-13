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
    /// Images the engine couldn't decode — HEIC (the dominant iPhone format) & friends. Surfaced
    /// so a folder of HEIC doesn't read as an empty "no similar photos" result. 0 on older
    /// engines that don't report it (the field is absent → treated as none skipped).
    let skippedUnsupported: Int
    /// The skipped count broken down by lowercased extension (e.g. ["heic": 42]). Empty when none.
    let skippedFormats: [String: Int]

    /// A short human note like "42 HEIC photos couldn't be read yet", or nil when nothing was
    /// skipped. Leads with HEIC (the case users hit) and rolls the rest into "other".
    var skippedNote: String? {
        guard skippedUnsupported > 0 else { return nil }
        let heic = (skippedFormats["heic"] ?? 0) + (skippedFormats["heif"] ?? 0)
        let others = skippedUnsupported - heic
        var parts: [String] = []
        if heic > 0 { parts.append("\(heic) HEIC") }
        if others > 0 { parts.append("\(others) other") }
        let what = parts.isEmpty ? "\(skippedUnsupported)" : parts.joined(separator: " + ")
        return "\(what) image\(skippedUnsupported == 1 ? "" : "s") couldn't be read (HEIC isn't supported yet)"
    }

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

        // Loose numeric read: the count arrives as an Int, but tolerate any NSNumber.
        let skipped = (raw["skipped_unsupported"] as? NSNumber)?.intValue ?? 0
        var formats: [String: Int] = [:]
        if let raw = raw["skipped_formats"] as? [String: Any] {
            for (k, v) in raw { if let n = (v as? NSNumber)?.intValue { formats[k] = n } }
        }

        return PhotosReport(
            dir: (raw["dir"] as? String) ?? "",
            threshold: (raw["threshold"] as? Int) ?? 0,
            groups: ranked,
            skippedUnsupported: skipped,
            skippedFormats: formats)
    }
}
