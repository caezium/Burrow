//
//  DiskScanner.swift
//  Burrow
//
//  Thin wrapper around `mo analyze --json <path>`. Mole already does
//  the heavy lifting (recursive size aggregation per directory, fast
//  parallel walk) — we just spawn it, parse the JSON, and return typed
//  entries. The treemap layer reads from the entries list.
//
//  Mole returns only the immediate children of the requested path, with
//  their aggregate sizes. The drill-in UX (click a directory to descend)
//  means we don't need to recurse upfront — each level is one mo call.
//  Typical home folder scan finishes in a few seconds.
//
//  Why not FileManager.enumerator: Mole's analyze-go walks via
//  getattrlistbulk which is ~10× faster than NSFileManager for large
//  trees, plus we get parity with `mo analyze` from the CLI — same path
//  scanned interactively from Burrow gives the same numbers.
//

import Foundation

struct DiskScanEntry: Identifiable, Hashable {
    let id: String       // absolute path; stable identity for hit-testing
    let name: String     // display name (last path component)
    let path: String     // full absolute path
    let size: Int64      // bytes; for directories this is the recursive aggregate
    let isDir: Bool
    let lastAccess: Date?

    /// Best-guess file kind for colouring. Extension if present,
    /// "<dir>" for directories, "" for unknown. Used as the colour key.
    var kind: String {
        if self.isDir { return "<dir>" }
        let url = URL(fileURLWithPath: self.path)
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? "<none>" : ext
    }
}

struct DiskScanResult {
    let path: String
    let totalSize: Int64
    let totalFiles: Int
    let entries: [DiskScanEntry]
    let scannedAt: Date
}

enum DiskScanError: Error, LocalizedError {
    case moNotFound
    case moTooOld(found: String?)
    case moFailed(exitCode: Int32, stderr: String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .moNotFound:
            return NSLocalizedString("Mole CLI (`mo`) not found on PATH.", comment: "")
        case .moTooOld(let found):
            return String(format: NSLocalizedString(
                "Disk analysis needs Mole %@ or newer (you have %@). Run `brew upgrade mole`, then try again.",
                comment: ""),
                MoleCLI.minimumAnalyzeJSONVersion,
                found ?? NSLocalizedString("an unknown version", comment: ""))
        case .moFailed(let code, let stderr):
            return String(format: NSLocalizedString("mo analyze exited %d: %@", comment: ""),
                          code, String(stderr.prefix(200)))
        case .parseFailed(let m):
            return String(format: NSLocalizedString("Couldn't parse mo analyze output: %@", comment: ""), m)
        }
    }
}

enum DiskScanner {
    /// Scan a single path level via `mo analyze --json`. Synchronous —
    /// callers must run on a background queue. Returns aggregated sizes
    /// for each direct child; drill in by calling again with the child's
    /// path.
    static func scan(_ path: String) throws -> DiskScanResult {
        guard case .installed = MoEngine.shared.availability() else {
            throw DiskScanError.moNotFound
        }
        // 5-minute timeout — `mo analyze` on the home dir is usually a
        // few seconds, but a cold cache + large external volume + no
        // indexing can stretch it. Beyond 5 min something's wrong.
        let result = try MoEngine.shared.capture(
            MoCommand(target: .mo, args: ["analyze", "--json", path], timeout: 300))
        guard result.exitCode == 0 else {
            if indicatesMissingJSONSupport(stderr: result.stderr) {
                throw DiskScanError.moTooOld(found: MoleCLI.version())
            }
            throw DiskScanError.moFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        guard let data = result.stdout.data(using: .utf8) else {
            throw DiskScanError.parseFailed("non-utf8 stdout")
        }
        return try Self.parse(data)
    }

    /// Pre-1.29 Mole doesn't know `analyze --json`: depending on vintage
    /// it either rejects the flag (Go's "flag provided but not defined")
    /// or ignores it and launches the TUI, which dies opening /dev/tty
    /// under a GUI parent ("could not open a new TTY", #35). Both mean
    /// the same thing for us: the user must upgrade mole. Pure → tested.
    static func indicatesMissingJSONSupport(stderr: String) -> Bool {
        stderr.contains("could not open a new TTY")
            || stderr.contains("flag provided but not defined")
    }

    // MARK: - Parsing

    /// Decode mo's JSON output into our typed shape. Loose decoding —
    /// any field we don't expose can change upstream without breaking
    /// us; we only fail if the spine (`entries[*].name`, `path`,
    /// `size`, `is_dir`) drifts.
    static func parse(_ data: Data) throws -> DiskScanResult {
        let raw: [String: Any]
        do {
            raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        } catch {
            throw DiskScanError.parseFailed(error.localizedDescription)
        }

        let path = raw["path"] as? String ?? "?"
        let totalSize = (raw["total_size"] as? Int64)
            ?? Int64(raw["total_size"] as? Int ?? 0)
        let totalFiles = raw["total_files"] as? Int ?? 0
        let entriesRaw = raw["entries"] as? [[String: Any]] ?? []

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        var entries: [DiskScanEntry] = []
        entries.reserveCapacity(entriesRaw.count)
        for e in entriesRaw {
            guard let name = e["name"] as? String,
                  let path = e["path"] as? String else { continue }
            let size = (e["size"] as? Int64) ?? Int64(e["size"] as? Int ?? 0)
            let isDir = e["is_dir"] as? Bool ?? false
            var lastAccess: Date? = nil
            if let s = e["last_access"] as? String {
                lastAccess = iso.date(from: s) ?? isoNoFrac.date(from: s)
            }
            entries.append(DiskScanEntry(
                id: path,
                name: name,
                path: path,
                size: size,
                isDir: isDir,
                lastAccess: lastAccess
            ))
        }
        // Largest first — gives the treemap a natural sort + matches
        // what `mo analyze`'s TUI shows.
        entries.sort { $0.size > $1.size }

        return DiskScanResult(
            path: path,
            totalSize: totalSize,
            totalFiles: totalFiles,
            entries: entries,
            scannedAt: Date()
        )
    }
}
