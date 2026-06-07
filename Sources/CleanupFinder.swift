//
//  CleanupFinder.swift
//  Burrow
//
//  Burrow-side scanners for the file-based cleanup tools where the user
//  should choose WHAT to remove. Mole's `installer`/`purge` are interactive
//  TUIs with no scriptable selection, so for genuine in-app selection we
//  find the candidates ourselves and move only the chosen ones to the
//  Trash (recoverable, no sudo). Clean stays on `mo` — system caches need
//  Mole's whitelist + elevation, which we don't want to reimplement.
//
//  The scan functions take their directories as a parameter so they're
//  unit-testable against a temp folder.
//

import Foundation

/// One removable thing the user can select. `id` is the absolute path so a
/// re-scan keeps selection stable.
struct FileFinding: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let size: Int64
    let isDir: Bool
    let location: String   // human label, e.g. "Downloads"
}

/// Leftover installer files (`.dmg`, `.pkg`, `.iso`, `.xip`) — the same
/// types `mo installer` targets — found in the standard download spots.
enum InstallerFinder {
    static let extensions: Set<String> = ["dmg", "pkg", "iso", "xip"]

    /// Standard download locations. Each has an Info.plist usage string, so
    /// macOS prompts once with a clear message instead of the per-folder
    /// flood the cache scanners trigger.
    static func defaultDirs() -> [(label: String, url: URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            ("Downloads", home.appendingPathComponent("Downloads")),
            ("Desktop", home.appendingPathComponent("Desktop")),
            ("Documents", home.appendingPathComponent("Documents")),
        ]
    }

    /// Scan the given directories (top level only) for installer files,
    /// largest first.
    static func scan(in dirs: [(label: String, url: URL)]) -> [FileFinding] {
        let fm = FileManager.default
        var out: [FileFinding] = []
        for (label, dir) in dirs {
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]) else { continue }
            for url in items where extensions.contains(url.pathExtension.lowercased()) {
                let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                // Logical size — matches what Finder and `mo` report.
                let size = Int64(vals?.fileSize ?? 0)
                out.append(FileFinding(name: url.lastPathComponent, path: url.path,
                                       size: size, isDir: vals?.isDirectory ?? false,
                                       location: label))
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    static func scan() -> [FileFinding] { scan(in: defaultDirs()) }
}

/// Move the given paths to the Trash. Returns the paths that couldn't be
/// trashed (e.g. permission denied) so the UI can report partial failure.
/// Trash is recoverable, so this never permanently deletes.
enum CleanupTrasher {
    @discardableResult
    static func trash(_ paths: [String]) -> [String] {
        let fm = FileManager.default
        var failed: [String] = []
        for path in paths {
            do {
                try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            } catch {
                failed.append(path)
            }
        }
        return failed
    }
}
