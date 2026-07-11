//
//  RootView.swift
//  Burrow
//
//  The window shell: behind-window vibrancy → per-pane tint scrim → top
//  nav → pane content. One window, one navigation model — the five
//  tools plus Settings and History are all `Pane`s shown right here.
//

import SwiftUI
import AppKit

extension Notification.Name {
    /// Posted by AppDelegate when a deep-link (HUD pill, gear, Dock reopen)
    /// wants the LIVE window to switch panes. Routing through the existing
    /// RootView instead of reinstalling the content view is what keeps
    /// in-flight tool state (a running clean's report, scan caches) alive
    /// across reopens.
    static let burrowSelectPane = Notification.Name("dev.caezium.burrow.selectPane")
    /// Posted with object `Bool` when the main window is shown/closed, so
    /// panes with live timers can unmount while the window is invisible.
    static let burrowWindowVisibility = Notification.Name("dev.caezium.burrow.windowVisibility")
}

struct RootView: View {
    let db: DB
    let producer: SnapshotProducer
    let feeds: FeedHub
    weak var delegate: AppDelegate?

    @State private var pane: Pane
    /// The window is closed-not-released; SwiftUI never fires onDisappear
    /// for an installed-but-hidden hierarchy, so Home/Settings would keep
    /// polling forever behind a closed window without this flag.
    @State private var windowVisible = true
    /// The ambient Full Disk Access state (issue #3, demoted from blocking
    /// gates). Probed at mount and on every app activation, so granting
    /// access in System Settings dismisses the banner by itself.
    @State private var fdaGranted = Privacy.hasFullDiskAccess()
    /// Session-only: the FDA banner reappears each launch while access is off,
    /// and dismissing it only hides it for the current run. (It used to read a
    /// PERSISTED flag — `fda_notice_dismissed`, shared with the pre-redesign
    /// notice — so one historical dismiss suppressed it forever even while FDA
    /// stayed off, which is why upgraders never saw it.)
    @State private var fdaBannerDismissed = false
    /// Where Esc in the Settings pane returns to.
    @State private var lastNonSettingsPane: Pane = .home
    /// Burrow's own self-update state — drives the top banner.
    @ObservedObject private var appUpdate = AppUpdate.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(db: DB, producer: SnapshotProducer, feeds: FeedHub, delegate: AppDelegate?, initialPane: Pane = .home) {
        self.db = db
        self.producer = producer
        self.feeds = feeds
        self.delegate = delegate
        self._pane = State(initialValue: Self.normalize(initialPane))
    }

    /// Purge/Installer fold into Clean (CleanHub), so any lingering deep-link
    /// to those panes resolves to the merged Clean pane rather than a blank.
    static func normalize(_ p: Pane) -> Pane {
        (p == .tool(.purge) || p == .tool(.installer)) ? .tool(.clean) : p
    }

    var body: some View {
        ZStack {
            VisualEffectBackground().ignoresSafeArea()
            // One stable charcoal ground on every pane — switching tools no
            // longer re-tints the whole window in that tool's colour.
            Brand.windowVeil.ignoresSafeArea()
            // A single soft warm glow in the corner — the house "gradient",
            // kept ambient rather than a per-tool window wash.
            Brand.ambientGlow.ignoresSafeArea()
            // A faint film grain over the ground — tactile, not flat.
            GrainOverlay()

            ZStack(alignment: .topLeading) {
                // Content sits under the floating rail, inset on the left to
                // clear it. The rail is drawn last so its hover labels fly out
                // above the pane instead of behind it.
                VStack(spacing: 0) {
                    if let release = appUpdate.available {
                        UpdateBanner(release: release,
                                     onDownload: {
                                         if UpdateCheck.installedViaHomebrew() { UpdateCheck.homebrewUpgrade() }
                                         else { NSWorkspace.shared.open(release.url) }
                                     },
                                     onDismiss: { appUpdate.dismiss() })
                            .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 4)
                            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    }
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.leading, 88)
                .padding(.top, 12)

                // Floating left rail — a detached, rounded rail of icon buttons
                // in place of a top tab bar. Padded clear of the traffic lights
                // and drawn over the content.
                FloatingRail(selected: $pane)
                    .padding(.leading, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 14)
            }
        }
        .frame(minWidth: 940, minHeight: 640)
        .animation(.easeInOut(duration: 0.22), value: pane)
        // Sample fast only while a live metrics pane is on screen.
        .onAppear { producer.setForeground(Self.isMetricsPane(pane)) }
        .onChange(of: pane) { _, p in
            producer.setForeground(Self.isMetricsPane(p))
            if p != .settings { lastNonSettingsPane = p }
        }
        .onDisappear { producer.setForeground(false) }
        .onReceive(NotificationCenter.default.publisher(for: .burrowSelectPane)) { note in
            if let p = note.object as? Pane { pane = Self.normalize(p) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .burrowWindowVisibility)) { note in
            if let visible = note.object as? Bool { windowVisible = visible }
            producer.setForeground(windowVisible && Self.isMetricsPane(pane))
        }
        // Re-probe FDA whenever the user comes back from System Settings —
        // the banner auto-dismisses the moment access is granted.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fdaGranted = Privacy.hasFullDiskAccess()
        }
        .overlay(alignment: .bottom) {
            if !fdaGranted, !fdaBannerDismissed {
                AccessBanner(onDismiss: {
                    // Session-only — don't persist, so a future launch with FDA
                    // still off shows it again (a gentle once-per-launch nudge).
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                        fdaBannerDismissed = true
                    }
                })
                .padding(.horizontal, 18).padding(.bottom, 14)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: fdaGranted)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: appUpdate.available?.version)
    }

    /// Panes whose charts want live, high-cadence data. Home's Overview /
    /// History both do.
    static func isMetricsPane(_ p: Pane) -> Bool {
        p == .home
    }

    // Tools stay alive (preserving in-flight `mo` jobs); Home and Settings
    // carry live timers we'd rather not run off-screen, so they're created on
    // demand and torn down when you leave.
    private var content: some View {
        ZStack {
            AnalyzeView(isActive: pane == .tool(.analyze)).tabVisible(pane == .tool(.analyze))
            DupesView().tabVisible(pane == .tool(.dupes))
            SoftwareView(isActive: pane == .tool(.apps)).tabVisible(pane == .tool(.apps))
            CleanHub().tabVisible(pane == .tool(.clean))
            OptimizeView().tabVisible(pane == .tool(.optimize))
            PortsView(isActive: pane == .tool(.ports)).tabVisible(pane == .tool(.ports))
            ConnectivityView(isActive: pane == .tool(.connectivity)).tabVisible(pane == .tool(.connectivity))

            // Gated on window visibility too: these two carry live timers
            // (2 s polls, 15 s DB reads) that must stop when the window
            // closes — unmounting fires their onDisappear teardown.
            if pane == .home, windowVisible {
                HomeView(db: db, live: producer.live, feeds: feeds, onNavigate: { pane = $0 })
            }
            if pane == .settings, windowVisible {
                SettingsView(onRunMaintenance: { [weak delegate] in
                    // Off-main: runNow blocks for the prune (and an opted-in
                    // VACUUM can rewrite the whole DB file).
                    let m = delegate?.maintenance
                    DispatchQueue.global(qos: .utility).async { m?.runNow() }
                }, onClose: { pane = lastNonSettingsPane })
            }
        }
    }
}

private extension View {
    /// Keep a view in the hierarchy (so its @StateObject + work survive)
    /// while hiding it and disabling interaction when not the active pane.
    @ViewBuilder
    func tabVisible(_ visible: Bool) -> some View {
        self.opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
    }
}

/// A slim top strip shown when a newer Burrow release is found (self-update
/// is opt-in, default on). Download opens the release page; dismiss suppresses
/// this version. Never auto-installs.
private struct UpdateBanner: View {
    let release: UpdateCheck.Release
    let onDownload: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 16)).foregroundStyle(Tool.status.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: NSLocalizedString("Burrow %@ is available", comment: ""), release.version))
                    .font(Brand.sans(13, .semibold)).foregroundStyle(Brand.textPrimary)
                Text(UpdateCheck.installedViaHomebrew()
                     ? NSLocalizedString("One-click update + relaunch via Homebrew.", comment: "")
                     : NSLocalizedString("Download it from the release page.", comment: ""))
                    .font(Brand.mono(10)).foregroundStyle(Brand.textSecondary)
            }
            Spacer()
            Button(action: onDownload) {
                Text(UpdateCheck.installedViaHomebrew()
                     ? NSLocalizedString("Update", comment: "")
                     : NSLocalizedString("Download", comment: ""))
                    .font(Brand.sans(12, .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(.white))
            }.buttonStyle(.plain)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.textSecondary)
                    .padding(6)
            }.buttonStyle(.plain).accessibilityLabel(NSLocalizedString("Dismiss", comment: ""))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tool.status.accent.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Tool.status.accent.opacity(0.35), lineWidth: 1))
    }
}
