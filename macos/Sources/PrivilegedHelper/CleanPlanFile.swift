//
//  CleanPlanFile.swift
//  Burrow / BurrowHelper (shared)
//
//  The plan file `burrow clean --apply --plan <file>` reads: UTF-8, one absolute path per line,
//  `#` comment lines allowed. The engine removes ONLY the listed paths — no re-scan — and
//  re-checks each through its own deletion rails, refusing anything outside its clean roots as
//  `protected` with reason `not_a_clean_target`. That is what lets the review's Confirm run
//  exactly what was ticked without enumerating the caches a second time (a second scan can
//  find caches the user never saw).
//
//  Written by two parties, so the writer lives in the shared contract: the app writes one into
//  its own Application Support directory for the osascript route, and the privileged helper
//  writes its OWN — from the paths it validated itself, into a root-only directory — for the
//  helper route, so root never reads a delete list out of a user-writable file. Both go through
//  `render`, so the rules are one function: absolute, no `..` component, no control character
//  (a newline in a path would smuggle a second line), and the count bounded to what a review can
//  hold. The rules are deliberately structural: WHICH paths are allowed is the engine's rail and
//  the daemon's policy, not this file's job.
//

import Foundation

enum CleanPlanFile {
    enum Rejection: Error, Equatable, LocalizedError {
        case empty
        case tooMany(Int)
        case notAbsolute(String)
        case traversal(String)
        case controlCharacter(String)

        var errorDescription: String? {
            switch self {
            case .empty: return "The clean plan is empty."
            case .tooMany(let n): return "The clean plan lists \(n) paths, more than one review can hold."
            case .notAbsolute(let p): return "The clean plan contains a relative path: \(p)"
            case .traversal(let p): return "The clean plan contains a path with '..': \(p)"
            case .controlCharacter(let p): return "The clean plan contains a path with a control character: \(p)"
            }
        }
    }

    /// The same ceiling the helper's reviewed-path policy enforces, so a plan the daemon
    /// would refuse is never written in the first place.
    static let maximumEntries = 4096

    static let header = "# Burrow reviewed clean plan: one absolute path per line. The engine removes only these, each re-checked through its deletion rails."

    /// Validate `paths` and render the file body. Pure → unit-tested. Duplicates collapse
    /// (order preserved); everything else that is not a well-formed absolute path throws.
    static func render(paths: [String]) throws -> String {
        var seen = Set<String>()
        var lines: [String] = []
        for path in paths {
            guard path.hasPrefix("/"), path != "/" else { throw Rejection.notAbsolute(path) }
            guard !path.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
                throw Rejection.traversal(path)
            }
            guard !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw Rejection.controlCharacter(path)
            }
            if seen.insert(path).inserted { lines.append(path) }
        }
        guard !lines.isEmpty else { throw Rejection.empty }
        guard lines.count <= maximumEntries else { throw Rejection.tooMany(lines.count) }
        return ([header] + lines).joined(separator: "\n") + "\n"
    }

    /// Render and write `<uuid>.plan` into `directory` (created if missing), readable by the
    /// owner only. Returns the file's URL; the caller deletes it after the run.
    @discardableResult
    static func write(paths: [String], in directory: URL) throws -> URL {
        let body = try render(paths: paths)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("\(UUID().uuidString).plan")
        try Data(body.utf8).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }
}
