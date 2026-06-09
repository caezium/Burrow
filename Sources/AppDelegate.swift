//
//  AppDelegate.swift
//  Burrow
//
//  Launch order (matters):
//
//    1. Verify `mo` is on PATH. Hard requirement — if missing, modal
//       alert with the install command, then quit.
//    2. Open the SQLite history DB.
//    3. Start QueryServer (Store-gated).
//    4. Start Sampler (Store-configured cadence).
//    5. Start Maintenance (hourly prune).
//    6. Install the NSStatusItem.
//
//  Windows: v0.3 collapsed the four separate windows (History,
//  DiskMap, Cleanup, Settings) into one main window with a sidebar.
//  `openMainWindow(initial:)` is the one entry point — the popover's
//  action buttons just deep-link by passing the section they want
//  selected.
//

import Cocoa
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// Singleton handle so SwiftUI views can reach the live
    /// Maintenance / Sampler / DB without threading them through every
    /// initializer.
    static private(set) var shared: AppDelegate?

    private(set) var db: DB?
    private(set) var sampler: Sampler?
    private(set) var maintenance: Maintenance?
    private var queryServer: QueryServer?
    private var statusBar: StatusBarController?

    /// Single main window. Holds the sidebar + content router. The
    /// `pendingInitialSection` is only used to pass the chosen tab
    /// across the window-creation boundary; cleared once the window's
    /// content view reads it.
    private var mainWC: NSWindowController?
    fileprivate var pendingInitialPane: Pane = .home

    private var installWC: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // Anonymous, opt-out, once-per-day. Fired before the `mo` gate so a
        // launch with the engine missing still counts (a useful signal).
        Telemetry.ping()

        // No engine yet → guided install instead of a dead-end quit. The
        // window's Recheck calls startServices() once `mo` is found.
        guard MoleCLI.findExecutable() != nil else {
            showInstallWindow()
            return
        }
        startServices()
    }

    /// Guided onboarding window when `mo` is missing. Stays a regular Dock
    /// app so the window is reachable; we never run an installer ourselves.
    private func showInstallWindow() {
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()
        let view = MoleInstallView(onReady: { [weak self] in
            self?.installWC?.close()
            self?.installWC = nil
            self?.startServices()
        })
        window.contentViewController = NSHostingController(rootView: view)
        let wc = NSWindowController(window: window)
        self.installWC = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The `mo`-dependent startup: open the DB, start the server/sampler/
    /// maintenance, and install the status item. Called either directly at
    /// launch or after the guided install finds `mo`.
    private func startServices() {
        let db: DB
        do {
            db = try DB.openDefault()
        } catch {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Couldn't open Burrow's history database", comment: "")
            alert.informativeText = String(format: NSLocalizedString("%@\n\nThe app will quit.", comment: ""),
                                           error.localizedDescription)
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        self.db = db

        if Store.queryServerEnabled {
            let port = UInt16(clamping: Store.queryServerPort)
            self.queryServer = QueryServer(db: db, port: port)
            self.queryServer?.start()
        }

        let sampler = Sampler(db: db,
                              intervalSeconds: TimeInterval(Store.sampleIntervalSeconds))
        self.sampler = sampler
        sampler.start()

        // Always-on 1 s network + disk reader: feeds the live Home tiles AND the
        // History charts so both update at the same (fast) cadence. (We're on the
        // main thread at launch; assumeIsolated satisfies the @MainActor reader.)
        MainActor.assumeIsolated { IOMonitor.shared.start() }

        let maintenance = Maintenance(db: db)
        self.maintenance = maintenance
        maintenance.start()

        if Store.showMenuBarIcon {
            self.statusBar = StatusBarController(db: db, sampler: sampler, delegate: self)
        }
        self.setupMainMenu()

        // Without the menu-bar icon there's no agent entry point (the app is
        // LSUIElement, so no Dock icon either). Run as a regular Dock app and
        // open the window on launch so it stays reachable (issue #4).
        if !Store.showMenuBarIcon, #available(macOS 14, *) {
            NSApp.setActivationPolicy(.regular)
            self.openMainWindow(initial: .home)
        }

        // Dev affordance: launch with BURROW_OPEN_ON_LAUNCH=1 to pop the
        // main window straight away (used for screenshot/verify loops).
        if let tab = Foundation.ProcessInfo.processInfo.environment["BURROW_OPEN_ON_LAUNCH"],
           #available(macOS 14, *) {
            let pane: Pane
            if tab == "settings" { pane = .settings }
            else if tab == "home" || tab == "status" || tab == "history" || tab == "activity" { pane = .home }
            else if let tool = Tool(rawValue: tab), Tool.navOrder.contains(tool) { pane = .tool(tool) }
            else { pane = .home }
            self.openMainWindow(initial: pane)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        self.sampler?.stop()
        self.queryServer?.stop()
        self.maintenance?.stop()
        // Final flush so any just-changed setting survives an app replacement
        // during an update.
        UserDefaults.standard.synchronize()
    }

    // MARK: - Window

    /// Open the main window, focusing the requested section. If the
    /// window already exists, just selects the section and brings the
    /// window forward. Used by every popover action button —
    /// `openMainWindow(initial: .cleanup)` etc.
    @available(macOS 14.0, *)
    func openMainWindow(initial: Pane = .home) {
        // If already open, just switch to the requested pane and bring
        // the window forward.
        if let wc = self.mainWC, let window = wc.window {
            self.pendingInitialPane = initial
            self.installMainContent(into: window, initial: initial)
            NSApp.setActivationPolicy(.regular)   // Dock icon while open
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard self.db != nil, self.sampler != nil else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        // Frameless-feeling translucent shell: transparent titlebar with
        // the traffic lights floating over content, a clear non-opaque
        // window so the behind-window vibrancy can sample the wallpaper,
        // and drag-anywhere so there's no visible chrome bar.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = NSLocalizedString("Burrow", comment: "")
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 940, height: 640)
        window.delegate = self

        // Show a Dock icon (and Cmd-Tab presence) while the dashboard is
        // open; we drop back to a pure menu-bar agent when it closes. The
        // icon itself comes from Assets.xcassets/AppIcon.
        NSApp.setActivationPolicy(.regular)

        let wc = NSWindowController(window: window)
        self.mainWC = wc
        self.installMainContent(into: window, initial: initial)
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @available(macOS 14.0, *)
    private func installMainContent(into window: NSWindow, initial: Pane) {
        guard let db = self.db, let sampler = self.sampler else { return }
        let root = RootView(db: db, sampler: sampler, delegate: self, initialPane: initial)
        let host = NSHostingController(rootView: root)
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = .clear
        window.contentViewController = host
    }

    // MARK: - Window delegate

    func windowWillClose(_ notification: Notification) {
        // Retreat to a pure menu-bar agent only when the menu-bar icon is
        // the actual entry point — keyed off what we installed at launch,
        // not the live Store value (which a mid-session toggle could change
        // before a relaunch, stranding the app). With no status item, keep
        // the Dock icon so the app stays reachable (issue #4).
        if statusBar != nil {
            NSApp.setActivationPolicy(.accessory)
        }
        // No live chart on screen → drop back to the idle sample cadence.
        self.sampler?.setForeground(false)
    }

    /// Clicking the Dock icon (menu-bar-disabled mode) reopens the window.
    /// When windows are already visible we return false so AppKit performs
    /// its default raise-windows behaviour rather than us suppressing it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return false }
        if #available(macOS 14, *) { self.openMainWindow(initial: .home) }
        return true
    }

    // MARK: - Menu-bar visibility (live)

    /// Apply the "Show menu bar icon" setting immediately, without a relaunch.
    /// Installs/removes the status item, and when hiding it keeps a Dock
    /// presence + an open window so the app never becomes unreachable.
    func applyMenuBarVisibility(_ show: Bool) {
        guard let db = db, let sampler = sampler else { return }
        if show {
            if statusBar == nil {
                statusBar = StatusBarController(db: db, sampler: sampler, delegate: self)
            }
        } else {
            statusBar = nil   // StatusBarController.deinit removes the item
            if #available(macOS 14, *) {
                NSApp.setActivationPolicy(.regular)
                // mainWC is retained (isReleasedWhenClosed = false), so its
                // window is non-nil even when closed — check visibility, not nil,
                // so hiding the menu bar always leaves a visible window.
                if mainWC?.window?.isVisible != true { openMainWindow(initial: .home) }
            }
        }
    }

    // MARK: - Main menu

    /// Minimal AppKit main menu — shows when the app is active (.regular,
    /// i.e. a window open). Gives a real ⌘, (Settings pane), proper Quit,
    /// and an Edit menu so text fields get cut/copy/paste/select-all.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: NSLocalizedString("About Burrow", comment: ""),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: NSLocalizedString("Settings…", comment: ""),
                                  action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: NSLocalizedString("Hide Burrow", comment: ""), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: NSLocalizedString("Quit Burrow", comment: ""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu (text editing in search fields etc.)
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: NSLocalizedString("Edit", comment: ""))
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: NSLocalizedString("Undo", comment: ""), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: NSLocalizedString("Redo", comment: ""), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: NSLocalizedString("Cut", comment: ""), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: NSLocalizedString("Copy", comment: ""), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: NSLocalizedString("Paste", comment: ""), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: NSLocalizedString("Select All", comment: ""), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // Window menu
        let winItem = NSMenuItem()
        mainMenu.addItem(winItem)
        let winMenu = NSMenu(title: NSLocalizedString("Window", comment: ""))
        winItem.submenu = winMenu
        winMenu.addItem(withTitle: NSLocalizedString("Minimize", comment: ""), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: NSLocalizedString("Close", comment: ""), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = winMenu
    }

    @objc private func openSettingsFromMenu() {
        if #available(macOS 14, *) { openMainWindow(initial: .settings) }
    }
}
