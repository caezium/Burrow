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
    /// `reason` is what the run actually said, read from whichever channel the resolved binary
    /// says it on (`BurrowEnvelope.failureReason`) — NOT stderr, which the Rust engine leaves
    /// empty on every classified failure. nil means the run said nothing at all.
    case moFailed(exitCode: Int32, reason: String?)
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
        case .moFailed(let code, let reason):
            // "mo analyze exited 2:" with nothing after the colon is what this printed for every
            // engine failure, because it was formatting stderr and the engine writes none. Say
            // so explicitly when there really is nothing, instead of trailing off.
            guard let reason, !reason.isEmpty else {
                return String(format: NSLocalizedString(
                    "mo analyze exited %d with no error output.", comment: ""), code)
            }
            return String(format: NSLocalizedString("mo analyze exited %d: %@", comment: ""),
                          code, String(reason.prefix(200)))
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
    /// `timeout` bounds a single level's walk: the top-level scan keeps the generous default, but
    /// the per-child walk passes a short one so one huge child (e.g. a package cache with millions
    /// of files) times out + shows partial instead of stalling the whole scan for minutes.
    static func scan(_ path: String, timeout: TimeInterval = 300) throws -> DiskScanResult {
        // Prefer the bundled conductor: `burrow analyze --json <path>` runs the bundled engine,
        // so disk analysis works even with NO system `mo` installed (the hard requirement just
        // below). The envelope's `data` is the same analyze-go JSON, so `parse` is unchanged; any
        // conductor miss (not bundled, engine error, empty/garbled) falls through to the direct
        // engine, so behavior is never worse than before.
        if BurrowConductor.isAvailable, let viaConductor = try? conductorScan(path, timeout: timeout) {
            return viaConductor
        }
        guard case .installed = MoEngine.shared.availability() else {
            throw DiskScanError.moNotFound
        }
        // 5-minute timeout — `mo analyze` on the home dir is usually a
        // few seconds, but a cold cache + large external volume + no
        // indexing can stretch it. Beyond 5 min something's wrong.
        let result = try MoEngine.shared.capture(
            MoCommand(target: .mo, args: ["analyze", "--json", path], timeout: timeout))
        guard result.exitCode == 0 else {
            // `moTooOld` is a mo-family diagnosis and stays reachable only from a mo-family
            // binary, so the 0.x engine cannot spuriously trip this 1.29.0 gate. The reason
            // is `indicatesMissingJSONSupport`: it matches two strings that only Go's flag
            // package and mole's TUI produce, and it reads STDERR. The Rust engine reports
            // every failure it classifies — bad path, unknown flag, unknown command — as an
            // `ok:false` envelope on STDOUT and writes nothing to stderr (re-verified against
            // burrow-engine @ 945000a). `found:` carries the product name anyway, so if a
            // future engine ever did reach this line the message reads "needs Mole 1.29.0
            // (you have burrow-engine 0.1.0)" — legible as a scale mismatch — rather than
            // looking like an ancient mo.
            //
            // The envelope guard makes that invariant CHECKED rather than incidental. Today it
            // can't change an answer — an envelope means the engine answered, and the engine's
            // stderr is empty, so the string match already can't fire — but it states the rule
            // ("this diagnosis is only about a mo-family binary") in a form a test can pin, so
            // an engine that one day prints anything at all to stderr can't be mistaken for a
            // 2023 mo and sent to `brew upgrade mole`.
            if BurrowEnvelope.inOutput(result.stdout) == nil,
               indicatesMissingJSONSupport(stderr: result.stderr) {
                throw DiskScanError.moTooOld(found: MoleCLI.versionReport()?.display)
            }
            throw DiskScanError.moFailed(
                exitCode: result.exitCode,
                reason: BurrowEnvelope.failureReason(stdout: result.stdout, stderr: result.stderr))
        }
        // A zero exit is not on its own a success: unwrap the engine's envelope (whose payload
        // is `data`, NOT its own top level — decoding the envelope directly yields a scan with
        // path "?" and zero entries, an empty-looking disk rather than an error), and refuse an
        // `ok:false` body even if the process somehow exited 0. A legacy `mo` has no envelope
        // and its stdout passes through byte-for-byte, as before.
        guard let data = BurrowEnvelope.payloadBytes(stdout: result.stdout) else {
            throw DiskScanError.moFailed(
                exitCode: result.exitCode,
                reason: BurrowEnvelope.failureReason(stdout: result.stdout, stderr: result.stderr))
        }
        return try Self.parse(data)
    }

    /// Scan via the bundled conductor (`burrow analyze --json <path>`). Throws on any miss —
    /// not bundled, timeout, an `ok:false` envelope, or no `data` — so `scan` can fall back to
    /// the direct engine. The `data` payload is the same analyze-go JSON, decoded by `parse`.
    private static func conductorScan(_ path: String, timeout: TimeInterval) throws -> DiskScanResult {
        let envelope = try BurrowConductor.capture("analyze", [path], timeout: timeout)
        guard let data = envelope.data else {
            throw DiskScanError.parseFailed("conductor returned an envelope with no data")
        }
        return try Self.parse(data)
    }

    /// Pre-1.29 Mole doesn't know `analyze --json`: depending on vintage
    /// it either rejects the flag (Go's "flag provided but not defined")
    /// or ignores it and launches the TUI, which dies opening /dev/tty
    /// under a GUI parent ("could not open a new TTY", #35). Both mean
    /// the same thing for us: the user must upgrade mole. Pure → tested.
    ///
    /// # What it does per binary shape, now that two can answer
    ///
    ///   * **A legacy mo-family binary** — unchanged, and this is its whole job. Those two
    ///     strings are produced by Go's `flag` package and mole's own TUI; the diagnosis they
    ///     support ("your mole is too old, `brew upgrade mole`") is only ever true of a
    ///     mo-family binary, and stderr is where that binary says them.
    ///   * **The Rust engine** — never fires, and must not. Its stderr is empty on every
    ///     classified failure, so it cannot match; and it should not be TAUGHT to match, because
    ///     "too old" is meaningless across the two version scales (the engine is a 0.x line —
    ///     see `MoleCLI.EngineVersion`) and telling a user on the bundled engine to run
    ///     `brew upgrade mole` would be advice about a program they don't have. Its real reason
    ///     lives in the `ok:false` envelope and is read by `BurrowEnvelope.failureReason`.
    ///
    /// So this deliberately still takes only `stderr` and still knows nothing about envelopes.
    /// Callers scope it to the binary it's about (`BurrowEnvelope.inOutput(stdout) == nil`)
    /// rather than this function widening to cover a shape it has no correct answer for.
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
