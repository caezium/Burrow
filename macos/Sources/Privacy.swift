//
//  Privacy.swift
//  Burrow
//
//  Full Disk Access detection and the macOS settings deep-link.
//
//  Burrow shells out to `mo`, which walks system and other-apps' cache
//  directories. On macOS 14+ those reads are TCC-gated ("Burrow would
//  like to access data from other apps") and the prompt is attributed to
//  Burrow — once per protected location, so a single `mo clean --dry-run`
//  or `mo analyze` over the home folder produces a *flood* of dialogs
//  (issue #3).
//
//  The OS-sanctioned remedy is Full Disk Access: once granted, macOS
//  stops gating per-folder reads for this app. We never bypass TCC — we
//  only detect whether we already have access and, if not, point the user
//  at the single switch that grants informed, one-time consent.
//

import Foundation
import AppKit
import SwiftUI

enum Privacy {
    /// Whether to surface the Full Disk Access notice before a scan that
    /// walks protected directories. Pure so it's unit-testable: nag only
    /// when access is missing and the user hasn't already dismissed it.
    static func shouldOfferFullDiskAccess(hasAccess: Bool, dismissed: Bool) -> Bool {
        return !hasAccess && !dismissed
    }

    /// What one probe location told us. The distinction that matters is
    /// `denied` vs `unavailable`: the old two-path probe collapsed both into
    /// "no access", so a Mac where neither path existed reported Full Disk
    /// Access as off however many times the user granted it (#177, #181, #319).
    enum ProbeOutcome: String, Equatable {
        /// Opened — the grant is live for this process.
        case granted
        /// The file is there and the kernel refused the read: access is off.
        case denied
        /// Nothing at this path on this Mac, so it says nothing either way.
        case unavailable
        /// Some other errno. Treated like `unavailable` — never as proof.
        case inconclusive
    }

    /// An FDA-gated location to try. `authoritative` marks the paths that
    /// exist on every Mac and are gated by Full Disk Access *specifically*,
    /// so a refusal there really does mean the grant is missing. The rest
    /// are positive-only: Safari and Messages data can be absent or gated
    /// under a different service, so their refusal proves nothing.
    struct Probe: Equatable {
        let id: String
        let path: String
        let authoritative: Bool
    }

    static let fullDiskAccessProbes: [Probe] = {
        let home = NSHomeDirectory() as NSString
        return [
            Probe(id: "user_tcc_db",
                  path: home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db"),
                  authoritative: true),
            Probe(id: "system_tcc_db",
                  path: "/Library/Application Support/com.apple.TCC/TCC.db",
                  authoritative: true),
            Probe(id: "safari_bookmarks",
                  path: home.appendingPathComponent("Library/Safari/Bookmarks.plist"),
                  authoritative: false),
            Probe(id: "messages_db",
                  path: home.appendingPathComponent("Library/Messages/chat.db"),
                  authoritative: false),
        ]
    }()

    /// The full picture behind `hasFullDiskAccess()`. `conclusive` is the
    /// point of it: when nothing opened *and* no authoritative probe was
    /// refused, Burrow has learned nothing and must not tell the user the
    /// permission is off.
    struct Diagnosis: Equatable {
        var outcomes: [String: ProbeOutcome]
        var hasAccess: Bool
        var conclusive: Bool
    }

    /// Classify a single probe from the errno an `open(2)` left behind.
    /// Pure and separately testable — the errno mapping is the part most
    /// likely to need revisiting on a future macOS.
    static func classify(openSucceeded: Bool, errnoValue: Int32) -> ProbeOutcome {
        if openSucceeded { return .granted }
        switch errnoValue {
        case EPERM, EACCES: return .denied
        case ENOENT, ENOTDIR: return .unavailable
        default: return .inconclusive
        }
    }

    /// Fold per-probe outcomes into a verdict. Any single `granted` wins;
    /// otherwise only an authoritative `denied` earns the right to say "off".
    static func summarize(_ outcomes: [String: ProbeOutcome], probes: [Probe]) -> Diagnosis {
        let hasAccess = outcomes.values.contains(.granted)
        let authoritativeDenial = probes.contains {
            $0.authoritative && outcomes[$0.id] == .denied
        }
        return Diagnosis(outcomes: outcomes,
                         hasAccess: hasAccess,
                         conclusive: hasAccess || authoritativeDenial)
    }

    /// Run every probe. We open and immediately close — the bytes are never
    /// read; this is a capability probe, not data access. A read that lacks
    /// access fails silently (no prompt), so probing can't itself flood the
    /// user with consent dialogs.
    static func diagnoseFullDiskAccess(probes: [Probe] = fullDiskAccessProbes) -> Diagnosis {
        var outcomes: [String: ProbeOutcome] = [:]
        for probe in probes {
            let fd = open(probe.path, O_RDONLY)
            let outcome = classify(openSucceeded: fd >= 0, errnoValue: errno)
            if fd >= 0 { close(fd) }
            outcomes[probe.id] = outcome
        }
        return summarize(outcomes, probes: probes)
    }

    /// Whether Burrow can reach FDA-gated files right now.
    static func hasFullDiskAccess() -> Bool {
        diagnoseFullDiskAccess().hasAccess
    }

    /// Deep-link to System Settings ▸ Privacy & Security ▸ Full Disk Access.
    static let fullDiskAccessSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    static func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(fullDiskAccessSettingsURL)
    }

    /// Relaunch Burrow. macOS binds a Full Disk Access grant to the app at
    /// process launch, so a grant flipped on while the app is running often
    /// isn't visible to the live process — quitting and reopening is the
    /// reliable way to pick it up. Spawns a fresh instance, then terminates
    /// this one once the new one is on its way.
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// Blocking gate shown when a flood-prone scan is requested without Full
/// Disk Access. Unlike the soft banner, this STOPS the run — otherwise
/// macOS prompts once per protected folder. Grant FDA once and the
/// prompts stop entirely; "Scan anyway" is the escape hatch (and warns).
struct FullDiskAccessRequired: View {
    var accent: Color
    var onOpenSettings: () -> Void = { Privacy.openFullDiskAccessSettings() }
    /// Re-probe access. Returns `true` when access is now visible (the
    /// parent proceeds with the scan and navigates away); `false` keeps us
    /// on the gate and reveals the relaunch hint — macOS frequently only
    /// applies a freshly-flipped grant at the app's next launch.
    var onRecheck: () -> Bool
    /// "Scan with admin" — only meaningful where running elevated actually
    /// dodges the prompts (e.g. cache scans). For Downloads/Desktop/Documents,
    /// TCC is keyed on the APP, not the uid, so root doesn't help — pass nil
    /// there and only Full Disk Access is offered.
    var onRunAnyway: (() -> Void)? = nil
    var onCancel: () -> Void
    var onRelaunch: () -> Void = { Privacy.relaunch() }

    @State private var stillBlocked = false

    private var blurb: String {
        onRunAnyway != nil
            ? "This reads system and app caches through Mole. Without Full Disk Access, macOS makes you approve every protected folder — one prompt after another. Grant it once in System Settings and the prompts stop for good. Or run the scan with administrator rights instead: one password, no per-folder asks. Burrow only reads sizes; it never opens that data itself."
            : "Mole scans your Downloads, Desktop and project folders. Without Full Disk Access, macOS makes you approve every protected folder — one prompt after another. Grant it once in System Settings and the prompts stop for good. Burrow only reads sizes; it never opens that data itself."
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle().fill(accent.opacity(0.15)).frame(width: 64, height: 64)
                Image(systemName: "lock.shield").font(.system(size: Brand.scaled(28))).foregroundStyle(accent)
            }
            VStack(spacing: 8) {
                Text("Grant Full Disk Access to scan")
                    .font(Brand.serif(20, .medium)).foregroundStyle(Brand.textPrimary)
                Text(blurb)
                    .font(Brand.sans(12)).foregroundStyle(Brand.textSecondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            }
            VStack(spacing: 12) {
                PillButton(title: "Open Full Disk Access settings") { onOpenSettings() }
                HStack(spacing: 18) {
                    Button("I've granted it — scan") { stillBlocked = !onRecheck() }
                        .buttonStyle(.plain).font(Brand.sans(12, .semibold)).foregroundStyle(accent)
                    if let onRunAnyway {
                        Button("Scan with admin") { onRunAnyway() }
                            .buttonStyle(.plain).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                    }
                    Button("Cancel") { onCancel() }
                        .buttonStyle(.plain).font(Brand.mono(11)).foregroundStyle(Brand.textTertiary)
                }
                if stillBlocked {
                    VStack(spacing: 6) {
                        Text("Still blocked? macOS only applies Full Disk Access the next time Burrow launches. Quit and reopen, then scan.")
                            .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 420)
                        Button("Quit & Reopen Burrow") { onRelaunch() }
                            .buttonStyle(.plain).font(Brand.sans(11, .semibold)).foregroundStyle(accent)
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(); Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }
}
