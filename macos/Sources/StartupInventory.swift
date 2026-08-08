//
//  StartupInventory.swift
//  Burrow
//
//  Enumerates what starts with this Mac (design 2.4): user launch
//  agents, system-visible launch agents and daemons — all from the
//  world-readable plist directories, no admin needed. Broken items
//  (unparseable plist, executable that no longer exists) surface as
//  error rows instead of disappearing.
//
//  This is the shared inventory layer: StartupView renders it today;
//  the roadmap's watcher (#12) and `burrow_diff` (#8) read the same
//  shape later. Root-scope details (other users' agents, daemon
//  internals) would need one elevated enumeration — deliberately not
//  shipped yet rather than half-shipped.
//

import Foundation

struct StartupItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case launchAgent, launchDaemon, loginItem

        var label: String {
            switch self {
            case .launchAgent:  return NSLocalizedString("Launch agent", comment: "startup kind")
            case .launchDaemon: return NSLocalizedString("Launch daemon", comment: "startup kind")
            case .loginItem:    return NSLocalizedString("Login item", comment: "startup kind")
            }
        }
    }

    enum Scope: Equatable { case user, system }

    enum Problem: Equatable {
        case parseFailed, danglingExecutable

        var label: String {
            switch self {
            case .parseFailed:        return NSLocalizedString("Unreadable configuration", comment: "")
            case .danglingExecutable: return NSLocalizedString("Program is missing", comment: "")
            }
        }
    }

    let label: String
    let kind: Kind
    let scope: Scope
    let plistPath: String
    let executable: String?
    let problem: Problem?

    var id: String { plistPath }

    /// Helpers living inside an app bundle are managed by that app —
    /// the UI marks them "Bundled inside an app; review only".
    var bundledInApp: Bool { executable?.contains(".app/") == true }

    /// User-scope, not bundled in an app, and not broken — the only items
    /// Burrow can safely enable/disable without admin (launchctl in the
    /// per-user gui domain). Everything else stays review-only. Modern Login
    /// (BTM) items aren't launchctl-toggleable — the owning app or System
    /// Settings manages them — so they're never controllable.
    var controllable: Bool { scope == .user && kind != .loginItem && !bundledInApp && problem == nil }

    /// The classification subline: kind + who manages it.
    var subline: String {
        if kind == .loginItem {
            return NSLocalizedString("Login item · System Settings manages it; review only", comment: "")
        }
        let management = bundledInApp
            ? NSLocalizedString("Bundled inside an app; review only", comment: "")
            : (scope == .system
                ? NSLocalizedString("System-wide; review only", comment: "")
                : NSLocalizedString("Yours; toggle to disable", comment: ""))
        return "\(kind.label) · \(management)"
    }
}

/// Enable/disable user launch agents via `launchctl` in the per-user gui
/// domain — no admin needed (system/bundled items stay read-only). The
/// disable persists across reboots and is reversible. Best-effort: launchctl's
/// exit codes are uneven, so state is re-read from `print-disabled` to confirm.
enum StartupControl {
    private static let launchctl = "/bin/launchctl"
    private static var domain: String { "gui/\(getuid())" }

    /// Labels currently disabled in the per-user database.
    static func disabledLabels() -> Set<String> {
        guard let out = try? MoEngine.shared.capture(
            MoCommand(target: .executable(launchctl), args: ["print-disabled", domain], timeout: 8)).stdout
        else { return [] }
        var disabled: Set<String> = []
        for line in out.components(separatedBy: "\n") {
            // "com.example.foo" => disabled   (newer)  or  => true  (older)
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.contains("=>") else { continue }
            let lower = t.lowercased()
            guard lower.contains("=> disabled") || lower.contains("=> true") else { continue }
            if let open = t.range(of: "\""),
               let close = t.range(of: "\"", range: open.upperBound..<t.endIndex) {
                disabled.insert(String(t[open.upperBound..<close.lowerBound]))
            }
        }
        return disabled
    }

    /// Enable or disable one controllable user agent. Returns whether the
    /// re-read state matches the request.
    @discardableResult
    static func setEnabled(_ enabled: Bool, item: StartupItem) -> Bool {
        guard item.controllable else { return false }
        let svc = "\(domain)/\(item.label)"
        if enabled {
            _ = run(["enable", svc])
            _ = run(["bootstrap", domain, item.plistPath])   // load now
        } else {
            _ = run(["bootout", svc])                         // unload now (ok if not loaded)
            _ = run(["disable", svc])                         // persist
        }
        let nowDisabled = disabledLabels().contains(item.label)
        return enabled ? !nowDisabled : nowDisabled
    }

    @discardableResult
    private static func run(_ args: [String]) -> Int32 {
        (try? MoEngine.shared.capture(
            MoCommand(target: .executable(launchctl), args: args, timeout: 12)).exitCode) ?? -1
    }
}

enum StartupInventory {
    /// One plist → one item. Failures classify, they don't vanish.
    static func item(fromPlist url: URL, kind: StartupItem.Kind,
                     scope: StartupItem.Scope) -> StartupItem {
        let fallbackLabel = url.deletingPathExtension().lastPathComponent
        guard let dict = NSDictionary(contentsOf: url) as? [String: Any] else {
            return StartupItem(label: fallbackLabel, kind: kind, scope: scope,
                               plistPath: url.path, executable: nil, problem: .parseFailed)
        }
        let label = (dict["Label"] as? String) ?? fallbackLabel
        let executable = (dict["Program"] as? String)
            ?? (dict["ProgramArguments"] as? [String])?.first
        var problem: StartupItem.Problem?
        if let exe = executable, !FileManager.default.fileExists(atPath: exe) {
            // A target on an external drive that's currently UNPLUGGED isn't
            // broken — don't flag it (PRD §Startup, RemovableVolumeGuard).
            let mounted = Set((try? FileManager.default.contentsOfDirectory(atPath: "/Volumes"))?
                .map { "/Volumes/\($0)" } ?? [])
            if RemovableVolumeGuard.classify(missingPath: exe, mountedVolumes: mounted) == .broken {
                problem = .danglingExecutable
            }
        }
        return StartupItem(label: label, kind: kind, scope: scope,
                           plistPath: url.path, executable: executable, problem: problem)
    }

    /// All .plist items in one directory. Missing directory = empty.
    static func scan(directory: URL, kind: StartupItem.Kind,
                     scope: StartupItem.Scope) -> [StartupItem] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.pathExtension == "plist" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { item(fromPlist: $0, kind: kind, scope: scope) }
    }

    /// The live no-admin inventory: user agents + world-readable system
    /// agents/daemons. This is the stable baseline source — the StartupWatcher
    /// diff (#8/#12) reads it, so it deliberately excludes the volatile BTM
    /// layer (`scanLiveIncludingLoginItems` adds that for the UI only).
    static func scanLive() -> [StartupItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var items = scan(directory: home.appendingPathComponent("Library/LaunchAgents"),
                         kind: .launchAgent, scope: .user)
        items += scan(directory: URL(fileURLWithPath: "/Library/LaunchAgents"),
                      kind: .launchAgent, scope: .system)
        items += scan(directory: URL(fileURLWithPath: "/Library/LaunchDaemons"),
                      kind: .launchDaemon, scope: .system)
        return items
    }

    /// Merge modern Login/Background items (BTM, from `sfltool dumpbtm`) into the
    /// plist-derived inventory, adding only those the LaunchAgent/Daemon scan
    /// didn't already surface (PRD §Startup). Pure — the sfltool spawn lives in
    /// `scanLiveIncludingLoginItems`. BTM items are review-only: toggling needs
    /// the owning app or admin, so they never become `controllable`.
    static func merge(plistItems: [StartupItem], login: [LoginItemsReader.Item]) -> [StartupItem] {
        let known = Set(plistItems.map { $0.label.lowercased() })
        // BTM identifiers carry a "<container#>." prefix, e.g.
        // "16.com.henry.studio-route-guard" → "com.henry.studio-route-guard".
        func normalized(_ id: String) -> String {
            id.replacingOccurrences(of: #"^\d+\."#, with: "", options: .regularExpression).lowercased()
        }
        var extras: [StartupItem] = []
        for li in login {
            let norm = normalized(li.identifier)
            // Skip placeholder container records and anything a plist covers.
            if norm.isEmpty || li.identifier.lowercased() == "unknown developer" { continue }
            if known.contains(norm) || known.contains(li.identifier.lowercased()) { continue }
            extras.append(StartupItem(
                label: li.name.isEmpty ? li.identifier : li.name,
                kind: .loginItem, scope: .user,
                plistPath: "btm:\(li.identifier)",   // synthetic, stable id
                executable: nil, problem: nil))
        }
        let sortedExtras = extras.sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
        return plistItems + sortedExtras
    }

    /// The inventory the Startup UI shows: `scanLive` plus modern Login items.
    /// `sfltool dumpbtm` needs root for the full list, so unelevated this just
    /// returns the plist inventory (graceful) rather than failing.
    static func scanLiveIncludingLoginItems() -> [StartupItem] {
        let base = scanLive()
        return merge(plistItems: base, login: LoginItemsReader.parse(loginItemsDump()))
    }

    /// The raw `sfltool dumpbtm` output.
    ///
    /// Prefer the privileged helper. Run as a normal user, `sfltool` raises
    /// its OWN authentication dialog — an unexplained "sfltool wants to make
    /// changes" prompt the user never asked for — and still returns only a
    /// partial list. Through the helper it is one authentication attributable
    /// to Burrow, and the complete BTM database.
    ///
    /// Without the helper this keeps the previous behaviour exactly, including
    /// that prompt, rather than losing the Login Items list altogether.
    private static func loginItemsDump() -> String {
        let client = PrivilegedHelperClient.shared
        if client.isUsable {
            let result = client.capture(operation: .readLoginItems)
            if case .exited(0) = result.outcome { return result.output }
            return ""   // declined or failed: fall back to the plist-only inventory
        }
        return (try? MoEngine.shared.capture(
            MoCommand(target: .executable("/usr/bin/sfltool"), args: ["dumpbtm"], timeout: 10)).stdout) ?? ""
    }
}
