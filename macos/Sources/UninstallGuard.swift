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
//  Post-repoint, "unparseable" is the NORMAL case against the bundled engine: it answers every
//  command in its JSON envelope, never the legacy "Matched N app(s):" text below, so
//  `matchedApps` returns nil on (almost) every real call and callers abort. See
//  `unavailableReason` for why that must stay true for now rather than be "fixed".
//

import Foundation

enum UninstallGuard {

    /// Why uninstall can't be verified against the bundled engine, in the one sentence surfaced
    /// verbatim by both the GUI's abort alert (`SoftwareView`) and the MCP `uninstall` tool's
    /// refusal (`ActionWire.uninstallAbort`) — one wording, so a person and an agent reading the
    /// tool's JSON learn the same true thing instead of each caller inventing its own guess at
    /// "couldn't verify". Not run through `NSLocalizedString`: it's shared verbatim with the
    /// non-localized MCP wire text, matching how `SettingsView` already states this build's other
    /// engine-capability gaps (e.g. `touchIDEngineSupported`'s footnote) in plain, unlocalized text.
    ///
    /// Do NOT respond to this by teaching `matchedApps` to decode the engine's JSON — that would
    /// ENABLE uninstall, and uninstall is not safe to enable yet, for three separate engine-side
    /// reasons that have nothing to do with parsing:
    ///
    ///  1. `burrow-engine uninstall` resolves exactly ONE bundle id per invocation
    ///     (`args.iter().find(|a| !a.starts_with("--"))` feeding `find_leftovers(home,
    ///     bundle_id)`) — every app after the first in a multi-app request is silently dropped.
    ///  2. Burrow passes DISPLAY NAMES (`InstalledApp.uninstallName`, sourced from the old
    ///     digger-era `--list`) where the engine wants an exact bundle id — `leftover_paths`
    ///     interpolates the argument directly into paths like `Library/Containers/{bundle_id}`.
    ///     A display name coincidentally matches for the handful of apps whose support files
    ///     happen to be named that way and finds nothing for everyone else, so a "fixed" guard
    ///     would produce PARTIAL, ARBITRARY deletions — not the uniform no-op this produces today.
    ///  3. As of this writing, `--permanent` is unparsed by the engine (removal runs through
    ///     `execute_clean`'s `fs::remove_dir_all`/`remove_file` unconditionally) and there is no
    ///     Trash path, so every real uninstall would be a hard delete despite the confirm
    ///     sheet's "moves to the Trash (recoverable)" promise. `caezium/burrow-engine` is a
    ///     separate, actively-developed repo — confirm this specific point against its current
    ///     source before relying on it; #1 and #2 above don't depend on it and are each
    ///     independently sufficient to keep this guard closed even if #3 already landed.
    ///
    /// All three need fixing on the engine side (and the app needs to start sending bundle ids)
    /// before this guard's fail-closed behavior should be relaxed.
    static let unavailableReason = "Uninstall isn't available in this build: the bundled engine "
        + "can only resolve one app per request and expects an exact bundle id where Burrow "
        + "currently sends display names, so there's no reliable way to confirm what it would "
        + "actually remove before anything is deleted."

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
