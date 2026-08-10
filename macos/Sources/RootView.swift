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

struct ScreenTelemetryDeduper {
    private var isVisible = true
    private var presentation = 0
    private var lastEmittedPresentation = -1
    private var lastEmittedPane: Pane?

    mutating func appeared(on pane: Pane) -> Bool {
        isVisible = true
        return shouldEmit(pane)
    }

    mutating func paneChanged(to pane: Pane) -> Bool {
        guard isVisible else { return false }
        return shouldEmit(pane)
    }

    mutating func visibilityChanged(to visible: Bool, pane: Pane) -> Bool {
        let wasVisible = isVisible
        isVisible = visible
        guard visible, !wasVisible else { return false }
        presentation += 1
        return shouldEmit(pane)
    }

    private mutating func shouldEmit(_ pane: Pane) -> Bool {
        guard lastEmittedPresentation != presentation || lastEmittedPane != pane else {
            return false
        }
        lastEmittedPresentation = presentation
        lastEmittedPane = pane
        return true
    }
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
    @State private var screenTelemetry = ScreenTelemetryDeduper()
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
    /// Whether the privileged helper is registered. Starts optimistic so the
    /// banner never flashes before the first probe answers, and is read off
    /// the main thread — `SMAppService.status` is a synchronous XPC call.
    @State private var helperInstalled = true
    /// Persisted, unlike the FDA dismiss: the helper is a convenience (Touch
    /// ID instead of a password), so once someone says no we stop asking.
    @State private var helperBannerDismissed = Store.helperNoticeDismissed
    /// Where Esc in the Settings pane returns to.
    @State private var lastNonSettingsPane: Pane = .home
    /// Set by a banner deep-link so Settings opens on the right tab, scrolled
    /// to the section that was being offered. Cleared on leaving Settings.
    @State private var settingsTab: SettingsView.Tab = .general
    @State private var settingsScrollTarget: String?
    /// Tools that have been opened this session. Panes mount on FIRST visit and stay alive
    /// after (preserving in-flight work) — but never before: a hidden pane still runs full
    /// layout + material backdrops on every display flush, and mounting all ten at launch
    /// made window layout passes take 2s+ on memory-pressed Macs (BURROW-8T).
    @State private var visitedTools: Set<Tool>

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(db: DB, producer: SnapshotProducer, feeds: FeedHub, delegate: AppDelegate?, initialPane: Pane = .home) {
        self.db = db
        self.producer = producer
        self.feeds = feeds
        self.delegate = delegate
        let start = Self.normalize(initialPane)
        self._pane = State(initialValue: start)
        if case .tool(let t) = start {
            self._visitedTools = State(initialValue: [t])
        } else {
            self._visitedTools = State(initialValue: [])
        }
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
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.leading, 88)
                    .padding(.top, 12)

                // Floating left rail — a detached, rounded rail of icon buttons
                // in place of a top tab bar. Padded clear of the traffic lights
                // and drawn over the content.
                FloatingRail(selected: $pane)
                    .padding(.leading, WindowMetrics.railLeading)
                    .padding(.top, WindowMetrics.railTop)
                    .padding(.bottom, WindowMetrics.railBottom)
            }
        }
        .frame(minWidth: WindowMetrics.minimumSize.width,
               minHeight: WindowMetrics.minimumSize.height)
        .animation(.easeInOut(duration: 0.22), value: pane)
        // Sample fast only while a live metrics pane is on screen.
        .onAppear {
            producer.setForeground(Self.isMetricsPane(pane))
            if screenTelemetry.appeared(on: pane) { Telemetry.screen(pane) }
            refreshHelperStatus()
        }
        .onChange(of: pane) { _, p in
            producer.setForeground(windowVisible && Self.isMetricsPane(p))
            if screenTelemetry.paneChanged(to: p) { Telemetry.screen(p) }
            if p != .settings {
                lastNonSettingsPane = p
                // A deep-link is a one-shot: reaching Settings any other way
                // should land on General, at the top.
                settingsTab = .general
                settingsScrollTarget = nil
            }
            if case .tool(let t) = p { visitedTools.insert(t) }
        }
        .onDisappear { producer.setForeground(false) }
        .onReceive(NotificationCenter.default.publisher(for: .burrowSelectPane)) { note in
            if let p = note.object as? Pane { pane = Self.normalize(p) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .burrowWindowVisibility)) { note in
            guard let visible = note.object as? Bool else { return }
            windowVisible = visible
            producer.setForeground(windowVisible && Self.isMetricsPane(pane))
            if screenTelemetry.visibilityChanged(to: visible, pane: pane) {
                Telemetry.screen(pane)
            }
        }
        // Re-probe FDA whenever the user comes back from System Settings —
        // the banner auto-dismisses the moment access is granted.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fdaGranted = Privacy.hasFullDiskAccess()
            // Approving the helper happens in System Settings, in another
            // process, with nothing notifying us — so re-read on return.
            refreshHelperStatus()
        }
        // At most one banner at a time. FDA outranks the helper: without it
        // scans can't read the caches the helper would elevate over anyway.
        .overlay(alignment: .bottom) {
            if !fdaGranted, !fdaBannerDismissed {
                AccessBanner(
                    title: NSLocalizedString("Full Disk Access is off", comment: ""),
                    detail: NSLocalizedString("Without it, Burrow can't reach most system caches.", comment: ""),
                    onDismiss: {
                        // Session-only — don't persist, so a future launch with FDA
                        // still off shows it again (a gentle once-per-launch nudge).
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            fdaBannerDismissed = true
                        }
                    })
                .padding(.horizontal, 18).padding(.bottom, 14)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            } else if !helperInstalled, !helperBannerDismissed {
                AccessBanner(
                    glyph: "touchid",
                    title: NSLocalizedString("Use Touch ID for admin operations", comment: ""),
                    detail: NSLocalizedString("Install the signed helper and scan, clean, and optimize authenticate with a fingerprint instead of a password.", comment: ""),
                    actionTitle: NSLocalizedString("Set up", comment: ""),
                    onAction: {
                        settingsTab = .advanced
                        settingsScrollTarget = SettingsView.helperAnchor
                        pane = .settings
                    },
                    onDismiss: {
                        Store.helperNoticeDismissed = true
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            helperBannerDismissed = true
                        }
                    })
                .padding(.horizontal, 18).padding(.bottom, 14)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: fdaGranted)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: helperInstalled)
    }

    /// `SMAppService.status` is a synchronous XPC round-trip — reading it on
    /// the main thread hung the window in Settings (BURROW app-hang reports),
    /// so the banner's probe stays off-main too.
    private func refreshHelperStatus() {
        DispatchQueue.global(qos: .utility).async {
            let installed = PrivilegedHelperClient.shared.registrationStatus != .notRegistered
            DispatchQueue.main.async { helperInstalled = installed }
        }
    }

    /// Panes whose charts want live, high-cadence data. Home's Overview /
    /// History both do.
    static func isMetricsPane(_ p: Pane) -> Bool {
        p == .home
    }

    // Tools mount on FIRST visit and stay alive after (preserving in-flight `mo` jobs
    // across tab switches) — never up front: a hidden pane still runs its full layout and
    // material backdrops on every display-cycle flush, and mounting all ten at launch made
    // whole-window layout take 2s+ on memory-pressed Macs (BURROW-8T, 12 users, macOS
    // 15…27). Home and Settings stay create-on-demand/teardown (they carry live timers).
    private var content: some View {
        ZStack {
            if visitedTools.contains(.analyze) {
                AnalyzeView(isActive: pane == .tool(.analyze)).tabVisible(pane == .tool(.analyze))
            }
            if visitedTools.contains(.dupes) {
                DupesView().tabVisible(pane == .tool(.dupes))
            }
            if visitedTools.contains(.orphans) {
                OrphansView().tabVisible(pane == .tool(.orphans))
            }
            if visitedTools.contains(.photos) {
                PhotosView().tabVisible(pane == .tool(.photos))
            }
            if visitedTools.contains(.net) {
                NetView(isActive: pane == .tool(.net)).tabVisible(pane == .tool(.net))
            }
            if visitedTools.contains(.apps) {
                SoftwareView(isActive: pane == .tool(.apps)).tabVisible(pane == .tool(.apps))
            }
            if visitedTools.contains(.clean) {
                CleanHub().tabVisible(pane == .tool(.clean))
            }
            if visitedTools.contains(.optimize) {
                OptimizeView().tabVisible(pane == .tool(.optimize))
            }
            if visitedTools.contains(.ports) {
                PortsView(isActive: pane == .tool(.ports)).tabVisible(pane == .tool(.ports))
            }
            if visitedTools.contains(.connectivity) {
                ConnectivityView(isActive: pane == .tool(.connectivity)).tabVisible(pane == .tool(.connectivity))
            }

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
                }, onClose: { pane = lastNonSettingsPane },
                   initialTab: settingsTab,
                   scrollTarget: settingsScrollTarget)
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
