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
//  `matchedApps` returns nil on (almost) every real call and callers abort. Teaching it to read
//  that JSON is easy and is NOT the thing standing in the way — read `unavailableReason`'s doc
//  comment before touching it: it records what has since been fixed, the one blocker that is
//  left, and the order the two remaining steps have to happen in.
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
    /// # What has been fixed, and what still keeps this closed
    ///
    /// This used to list THREE engine-side reasons. Two of them are now gone, and leaving a stale
    /// reason list here is precisely how someone opens the guard on the strength of half a fix, so
    /// the current state, verified against the real `burrow-engine` binary (not inferred from its
    /// source), is:
    ///
    ///  1. ~~One bundle id per invocation.~~ FIXED. `uninstall` collects every positional and runs
    ///     `uninstall::resolve::match_apps_by_name` over the same inventory `--list` prints, so a
    ///     three-app request resolves three apps and reports the ones that matched nothing in an
    ///     `unmatched` array instead of dropping them.
    ///  2. ~~Burrow sends display names.~~ FIXED on this side. `SoftwareModel.uninstallBatch` is
    ///     now the single resolver for BOTH the dry-run preview and the real run, and it sends
    ///     `bundleId` — refusing outright for the rows where that value is `""`, `"unknown"`, or
    ///     flag-shaped (see `SoftwareModel.isSendableBundleID` for what each of those resolves to).
    ///  3. ~~`--permanent` unparsed, no Trash path.~~ FIXED. The engine parses `--permanent` and
    ///     routes every surviving candidate through `crate::trash::move_to_trash` by default
    ///     (`/usr/bin/trash`, falling back to Finder via AppleScript), reporting a failed Trash
    ///     move as an ordinary per-item error rather than falling back to a hard delete.
    ///
    /// **The remaining blocker is not a parsing problem, and it is not on this side.** The
    /// engine's `uninstall` removes an app's per-app support files under `~/Library` — containers,
    /// Application Support, caches, preferences, logs, saved state, HTTP storage, WebKit data,
    /// cookies — and nothing else. It never deletes the `.app` bundle and never runs
    /// `brew uninstall --cask`, both of which the bash oracle's `batch_uninstall_applications`
    /// does; the engine states this in `src/cli.rs`'s own docs, and its dry-run enumeration
    /// contains no `.app` path at all. So the action behind Burrow's "Remove" button — take these
    /// applications off this machine — is one the engine cannot currently carry out, and a guard
    /// opened today would run something narrower than the row, the button and the tab all mean.
    ///
    /// # What opening it would take
    ///
    /// Two things, in this order. FIRST, the engine has to remove the `.app` bundle (and handle
    /// brew-managed casks) so the action matches its name — or Burrow's Software tab has to be
    /// deliberately redesigned around "clear this app's data", which is a product decision, not a
    /// build one. SECOND, and only then, `matchedApps` needs to decode the engine's dry-run
    /// envelope: `data.apps[]` carries `{query, name, bundle_id, path}` per resolved app plus a
    /// top-level `unmatched[]`, so comparing `query` values against what `uninstallBatch` sent is
    /// an EXACT preflight in a single namespace — strictly better than the text parser below,
    /// which compares display names. Do the second without the first and the button quietly means
    /// something else than it says.
    static let unavailableReason = "Uninstall isn't available in this build: the bundled engine "
        + "removes an app's leftover support files but never the app itself — no .app deletion "
        + "and no `brew uninstall --cask` — so it can't carry out the removal this button offers, "
        + "and its JSON dry-run isn't a format this pre-flight can confirm a matched set from."

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
