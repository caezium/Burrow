//
//  UninstallPreview.swift
//  Burrow
//
//  Parser + classifier for `mo uninstall --dry-run <app>` — the
//  enumeration behind the expandable leftover review (design 2.2).
//  Every path Burrow ever trashes selectively MUST come from this
//  enumeration: the engine's safety scan decided the candidate set,
//  Burrow only narrows it.
//
//  Output shape (mole 1.41, fixture in Tests/UninstallPreviewTests):
//
//      Files to be removed:
//
//      ◎ Maccy , 239.6MB
//        ✓ /Applications/Maccy.app
//        ✓ ~/Library/Containers/org.p0deje.Maccy
//        ...
//
//  Anything unrecognized parses to an empty preview and the UI falls
//  back to the classic whole-app flow.
//

import Foundation

struct UninstallPreview: Equatable {
    enum Kind: Equatable {
        case application, appSupport, preferences, container, groupContainer
        case helper, loginItem, cache, log, other

        /// Auto-selected kinds are the removal essentials. Caches, logs,
        /// group containers (shared between apps!) and unknowns need a
        /// human look first.
        var autoSelected: Bool {
            switch self {
            case .application, .appSupport, .preferences, .container, .helper, .loginItem:
                return true
            case .cache, .log, .groupContainer, .other:
                return false
            }
        }

        var label: String {
            switch self {
            case .application:    return NSLocalizedString("Application", comment: "uninstall kind")
            case .appSupport:     return NSLocalizedString("App Support", comment: "uninstall kind")
            case .preferences:    return NSLocalizedString("Preferences", comment: "uninstall kind")
            case .container:      return NSLocalizedString("Container", comment: "uninstall kind")
            case .groupContainer: return NSLocalizedString("Group Container", comment: "uninstall kind")
            case .helper:         return NSLocalizedString("Helper", comment: "uninstall kind")
            case .loginItem:      return NSLocalizedString("Login Item", comment: "uninstall kind")
            case .cache:          return NSLocalizedString("Temporary Cache", comment: "uninstall kind")
            case .log:            return NSLocalizedString("Logs", comment: "uninstall kind")
            case .other:          return NSLocalizedString("Other", comment: "uninstall kind")
            }
        }
    }

    struct Entry: Identifiable, Equatable {
        let path: String        // as printed (may be ~-relative)
        let kind: Kind
        var id: String { path }

        var expandedPath: String { (path as NSString).expandingTildeInPath }
    }

    let appName: String?
    let totalText: String?      // "239.6MB"
    let entries: [Entry]

    /// Paths in `entries` that Burrow must NOT hand-delete, and the sentence saying why. Keyed by
    /// the path exactly as it appears in `entries`.
    ///
    /// It exists because `items[]` alone is a trap. The engine emits an app's `.app` as `items[0]`
    /// on `bundle.present` ALONE — no refusal check, deliberately, because the preview has to show
    /// that the application is in scope even when it will not come away (`bundle.rs:584-591`). The
    /// verdict lives one field over, in `apps[].application`, which this parser used to drop
    /// entirely. So a bundle the engine refuses, and a Homebrew cask the engine will hand to
    /// `brew uninstall --cask --zap`, both arrived in the review UI as an ordinary `.application`
    /// row — auto-ticked — and the reviewed-subset path trashes ticked paths itself, with
    /// `FileManager.trashItem`, without ever consulting the engine again.
    ///
    /// Two different lies, one shape: Burrow hand-deleting what a protection rail declined, and
    /// Burrow trashing a cask's `.app` out from under Homebrew, whose Caskroom then still believes
    /// it is installed.
    var handRemovalRefusals: [String: String] = [:]

    var isEmpty: Bool { entries.isEmpty }

    /// The paths that may be ticked when the review first opens: the auto-selected kinds, minus
    /// anything Burrow is not allowed to remove by hand. One place, so the rule cannot be applied
    /// at one call site and forgotten at another.
    var defaultTicked: Set<String> {
        Set(entries.filter { $0.kind.autoSelected && handRemovalRefusals[$0.path] == nil }
                   .map(\.path))
    }

    /// Ticked paths Burrow must refuse to hand-delete — the rail `trashSubsets` fails closed on.
    func refusedAmong(_ ticked: Set<String>) -> [(path: String, reason: String)] {
        ticked.sorted().compactMap { path in
            handRemovalRefusals[path].map { (path, $0) }
        }
    }

    // MARK: - Parsing

    static func parse(_ lines: [String]) -> UninstallPreview {
        var appName: String?
        var totalText: String?
        var entries: [Entry] = []
        var inFileList = false

        for raw in lines {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Files to be removed") { inFileList = true; continue }
            guard inFileList else { continue }
            if t.hasPrefix("➤") || t.hasPrefix("===") { break }

            if t.hasPrefix("◎") {
                // "◎ Maccy , 239.6MB"
                let body = t.dropFirst().trimmingCharacters(in: .whitespaces)
                if let comma = body.range(of: ",", options: .backwards) {
                    appName = String(body[..<comma.lowerBound]).trimmingCharacters(in: .whitespaces)
                    totalText = String(body[comma.upperBound...]).trimmingCharacters(in: .whitespaces)
                } else {
                    appName = body
                }
            } else if t.hasPrefix("✓") || t.hasPrefix("✔") {
                let path = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
                guard path.hasPrefix("/") || path.hasPrefix("~") else { continue }
                entries.append(Entry(path: path, kind: classify(path)))
            }
        }
        return UninstallPreview(appName: appName, totalText: totalText, entries: entries)
    }

    /// Path shape → kind. Order matters: more specific prefixes first.
    static func classify(_ path: String) -> Kind {
        let p = path.hasPrefix("~") ? path : (path as NSString).abbreviatingWithTildeInPath
        if p.hasSuffix(".app") { return .application }
        if p.contains("/Library/Group Containers/") { return .groupContainer }
        if p.contains("/Library/Containers/") { return .container }
        if p.contains("/Library/Application Support/") { return .appSupport }
        if p.contains("/Library/Preferences/") { return .preferences }
        if p.contains("/Library/Application Scripts/") { return .helper }
        if p.contains("/Library/LaunchAgents/") || p.contains("/Library/LaunchDaemons/") { return .loginItem }
        if p.contains("/Library/Caches/") || p.hasPrefix("/private/var/folders/")
            || p.hasPrefix("/var/folders/") || p.hasPrefix("/tmp/") || p.hasPrefix("/private/tmp/") { return .cache }
        if p.contains("/Library/Logs/") { return .log }
        return .other
    }

    // MARK: - Bundled-engine JSON parsing
    //
    // `mo uninstall --dry-run <bundle-id>` against the BUNDLED ENGINE never emits the ANSI text
    // `parse(_:)` above understands — the engine only ever speaks its JSON envelope:
    // `data: {dry_run, bundle_id, total_bytes, total_human, items: [{path, label, size,
    // size_human}]}` (confirmed against the real `burrow-engine` binary). `classify(_:)` is pure
    // path-shape logic with no dependency on how the path was obtained, so a JSON-derived entry
    // classifies identically to a text-derived one.

    /// Build a preview from a captured `uninstall --dry-run <bundle-id>` response. Returns nil
    /// when `stdout` isn't envelope-shaped at ALL — the caller's signal that a real, non-engine
    /// `mo` answered instead and should be parsed with the legacy text `parse(_:)` above. An
    /// envelope that IS present but `ok:false`, or whose `data` doesn't carry a usable `items`
    /// array, comes back as an EMPTY preview (not nil) — same as `parse(_:)`'s own "recognized
    /// input, nothing found" case — so a caller only has ONE "couldn't enumerate" state to
    /// handle instead of two, and must treat it as "unavailable", never as "nothing to remove".
    static func fromEngineEnvelope(_ stdout: String) -> UninstallPreview? {
        guard let envelope = try? BurrowEnvelope.parse(stdout), envelope.burrowCli != nil else {
            return nil
        }
        guard envelope.ok, let data = envelope.data,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = payload["items"] as? [[String: Any]]
        else {
            return UninstallPreview(appName: nil, totalText: nil, entries: [])
        }
        let entries = items.compactMap { item -> Entry? in
            guard let path = item["path"] as? String else { return nil }
            return Entry(path: path, kind: classify(path))
        }
        // `apps[]` — the half of the payload this parser used to ignore. Decoded through
        // `UninstallGuard.decodePlan` rather than re-read here, so the review UI and the pre-flight
        // are looking at ONE decoding of the engine's verdict instead of two that can drift.
        var refusals: [String: String] = [:]
        let apps = UninstallGuard.decodePlan(payload).apps
        var matchedBundlePaths = Set<String>()
        for app in apps {
            let bundle = app.application
            let path = bundle.path.isEmpty ? app.path : bundle.path
            guard !path.isEmpty else { continue }
            // The duplicate path fields must identify the same bundle. A refusal indexed by
            // a different path cannot authorize an application row for hand removal.
            if app.path.isEmpty || app.path == path { matchedBundlePaths.insert(path) }
            if let refusal = bundle.refusal, !refusal.isEmpty {
                refusals[path] = refusal
            } else if bundle.isHomebrewCask {
                refusals[path] = String(
                    format: NSLocalizedString("Homebrew installed %1$@ — it has to be removed with `brew uninstall --cask --zap %2$@`. Trashing the app on its own would leave Homebrew still believing it's installed.", comment: "uninstall review"),
                    app.name, bundle.cask ?? app.name)
            }
        }
        for entry in entries where entry.kind == .application && !matchedBundlePaths.contains(entry.path) {
            refusals[entry.path] = NSLocalizedString("Application paths in the uninstall preview do not match. Rescan before trying again.", comment: "uninstall path mismatch")
        }
        return UninstallPreview(appName: nil, totalText: payload["total_human"] as? String,
                                entries: entries, handRemovalRefusals: refusals)
    }
}
