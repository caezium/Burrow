//
//  RootView.swift
//  Burrow
//
//  The window shell: behind-window vibrancy → per-pane tint scrim → top
//  nav → pane content. One window, one navigation model — the five
//  tools plus Settings and History are all `Pane`s shown right here.
//

import SwiftUI

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
    weak var delegate: AppDelegate?

    @State private var pane: Pane
    /// The window is closed-not-released; SwiftUI never fires onDisappear
    /// for an installed-but-hidden hierarchy, so Home/Settings would keep
    /// polling forever behind a closed window without this flag.
    @State private var windowVisible = true

    init(db: DB, producer: SnapshotProducer, delegate: AppDelegate?, initialPane: Pane = .home) {
        self.db = db
        self.producer = producer
        self.delegate = delegate
        self._pane = State(initialValue: initialPane)
    }

    var body: some View {
        ZStack {
            VisualEffectBackground().ignoresSafeArea()
            pane.scrim.ignoresSafeArea()

            VStack(spacing: 0) {
                TopNav(selected: $pane)
                    .padding(.top, 13)
                    .padding(.bottom, 10)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 940, minHeight: 640)
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.22), value: pane)
        // Sample fast only while a live metrics pane is on screen.
        .onAppear { producer.setForeground(Self.isMetricsPane(pane)) }
        .onChange(of: pane) { _, p in producer.setForeground(Self.isMetricsPane(p)) }
        .onDisappear { producer.setForeground(false) }
        .onReceive(NotificationCenter.default.publisher(for: .burrowSelectPane)) { note in
            if let p = note.object as? Pane { pane = p }
        }
        .onReceive(NotificationCenter.default.publisher(for: .burrowWindowVisibility)) { note in
            if let visible = note.object as? Bool { windowVisible = visible }
            producer.setForeground(windowVisible && Self.isMetricsPane(pane))
        }
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
            SoftwareView(isActive: pane == .tool(.apps)).tabVisible(pane == .tool(.apps))
            CleanView().tabVisible(pane == .tool(.clean))
            MoInteractiveView(.purge, isActive: pane == .tool(.purge)).tabVisible(pane == .tool(.purge))
            MoInteractiveView(.installer, isActive: pane == .tool(.installer)).tabVisible(pane == .tool(.installer))
            OptimizeView().tabVisible(pane == .tool(.optimize))

            // Gated on window visibility too: these two carry live timers
            // (2 s polls, 15 s DB reads) that must stop when the window
            // closes — unmounting fires their onDisappear teardown.
            if pane == .home, windowVisible {
                HomeView(db: db, live: producer.live, onNavigate: { pane = $0 })
            }
            if pane == .settings, windowVisible {
                SettingsView(onRunMaintenance: { [weak delegate] in
                    // Off-main: runNow blocks for the prune (and an opted-in
                    // VACUUM can rewrite the whole DB file).
                    let m = delegate?.maintenance
                    DispatchQueue.global(qos: .utility).async { m?.runNow() }
                })
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
