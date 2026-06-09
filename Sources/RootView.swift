//
//  RootView.swift
//  Burrow
//
//  The window shell: behind-window vibrancy → per-pane tint scrim → top
//  nav → pane content. One window, one navigation model — the five
//  tools plus Settings and History are all `Pane`s shown right here.
//

import SwiftUI

struct RootView: View {
    let db: DB
    let sampler: Sampler
    weak var delegate: AppDelegate?

    @State private var pane: Pane

    init(db: DB, sampler: Sampler, delegate: AppDelegate?, initialPane: Pane = .home) {
        self.db = db
        self.sampler = sampler
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
        .onAppear { sampler.setForeground(Self.isMetricsPane(pane)) }
        .onChange(of: pane) { _, p in sampler.setForeground(Self.isMetricsPane(p)) }
        .onDisappear { sampler.setForeground(false) }
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

            if pane == .home {
                HomeView(db: db, sampler: sampler, onNavigate: { pane = $0 })
            }
            if pane == .settings {
                SettingsView(onRunMaintenance: { [weak delegate] in delegate?.maintenance?.runNow() })
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
