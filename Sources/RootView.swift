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

    init(db: DB, sampler: Sampler, delegate: AppDelegate?, initialPane: Pane = .tool(.status)) {
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
    }

    // Tools stay alive (preserving in-flight `mo` jobs); the two utility
    // panes carry no session, so they're created on demand and torn down
    // when you leave — same lightweight pattern, fewer live timers.
    private var content: some View {
        ZStack {
            StatusView(db: db, sampler: sampler).tabVisible(pane == .tool(.status))
            AnalyzeView(isActive: pane == .tool(.analyze)).tabVisible(pane == .tool(.analyze))
            SoftwareView(isActive: pane == .tool(.apps)).tabVisible(pane == .tool(.apps))
            CleanView().tabVisible(pane == .tool(.clean))
            StreamingToolView(action: .purge).tabVisible(pane == .tool(.purge))
            InstallerView(isActive: pane == .tool(.installer)).tabVisible(pane == .tool(.installer))
            OptimizeView().tabVisible(pane == .tool(.optimize))

            if pane == .settings {
                SettingsView(onRunMaintenance: { [weak delegate] in delegate?.maintenance?.runNow() })
            }
            if pane == .history {
                HistoryView(db: db)
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
