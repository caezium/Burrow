//
//  UninstallGuard.swift
//  Burrow
//
//  Pre-flight verification for the Software tab's uninstall. Burrow's
//  confirm sheet shows the apps the USER picked, but `mo uninstall <names>`
//  does its own name matching before acting — if mo's matcher resolves a
//  name to more (or different) apps than the one confirmed, the executed
//  set silently diverges from the confirmed set.
//
//  The guard closes that gap without driving a TTY: run
//  `mo uninstall --dry-run <names>` first (non-destructive; exits at its
//  prompt on stdin EOF), parse the "Matched N app(s):" list mo prints, and
//  only proceed to the real run when it equals what the user confirmed.
//  Anything unparseable fails CLOSED — no real run.
//

import Foundation

enum UninstallGuard {

    /// App names mo reports it matched, parsed from (ANSI-decorated)
    /// `mo uninstall --dry-run` output:
    ///
    ///     ◎ Matched 2 app(s):
    ///     1. Slack  120MB  |  Last: 2d ago
    ///     2. Python Launcher  315KB  |  Last: 1y ago
    ///
    /// Returns `[]` for "No matching applications found.", the parsed names
    /// for a matched list, and nil when the output fits neither shape
    /// (parse failure → caller must abort).
    static func matchedApps(inDryRunOutput raw: String) -> [String]? {
        let text = Ansi.strip(raw)
        if text.contains("No matching applications found") { return [] }

        let lines = text.components(separatedBy: .newlines)
        guard let headerIdx = lines.firstIndex(where: {
            $0.contains("Matched") && $0.contains("app(s):")
        }) else { return nil }

        var names: [String] = []
        for line in lines[(headerIdx + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }   // blank line ends the list
            guard let ordinal = trimmed.range(of: #"^\d+\.\s+"#,
                                              options: .regularExpression) else { break }
            // The name sits between the "N. " ordinal and the two-space
            // column gap before the size — app names can contain single
            // spaces ("Python Launcher"), columns are separated by two.
            let rest = trimmed[ordinal.upperBound...]
            let name = rest.range(of: "  ").map { String(rest[..<$0.lowerBound]) } ?? String(rest)
            let cleaned = name.trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty { names.append(cleaned) }
        }
        // A "Matched N" header with no parseable rows is a format we don't
        // understand — fail closed rather than claim "nothing matched".
        return names.isEmpty ? nil : names
    }

    /// Human-readable description of how `matched` diverges from
    /// `confirmed`, or nil when the sets agree. Case-insensitive: both
    /// sides ultimately come from mo's own canonical names.
    static func mismatchDescription(confirmed: [String], matched: [String]) -> String? {
        let confirmedSet = Set(confirmed.map { $0.lowercased() })
        let matchedSet = Set(matched.map { $0.lowercased() })
        guard confirmedSet != matchedSet else { return nil }

        var parts: [String] = []
        let extra = matched.filter { !confirmedSet.contains($0.lowercased()) }
        let missing = confirmed.filter { !matchedSet.contains($0.lowercased()) }
        if !extra.isEmpty {
            parts.append(String(format: NSLocalizedString("mo would also remove: %@", comment: ""),
                                extra.joined(separator: ", ")))
        }
        if !missing.isEmpty {
            parts.append(String(format: NSLocalizedString("mo did not match: %@", comment: ""),
                                missing.joined(separator: ", ")))
        }
        return parts.joined(separator: " · ")
    }
}
