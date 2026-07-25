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
//    4. Start SnapshotProducer (Store-configured cadence).
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
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// Singleton handle so SwiftUI views can reach the live
    /// Maintenance / SnapshotProducer / DB without threading them through every
    /// initializer.
    static private(set) var shared: AppDelegate?

    private(set) var db: DB?
    private(set) var producer: SnapshotProducer?
    private(set) var maintenance: Maintenance?
    private var queryServer: QueryServer?
    private var statusBar: StatusBarController?
    /// Dev/verify only: standalone window hosting the HUD (BURROW_OPEN_ON_LAUNCH=hud).
    private var hudPreview: NSWindow?

    /// The one feed hub (issue #53): shared, demand-counted pumps keyed by
    /// query — views bind to feeds instead of owning timers.
    let feeds = FeedHub()

    /// Single main window. Holds the sidebar + content router.
    private var mainWC: NSWindowController?

    private var installWC: NSWindowController?
    private var onboardingWC: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // Under XCTest this process is only a TEST_HOST shell. Starting the
        // real services would bind the query port, spawn `mo`, fire telemetry,
        // and let the maintenance timer prune the developer's real history DB
        // mid-suite. Stay inert; tests construct exactly what they need.
        if Foundation.ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }

        // Product analytics + crash reporting (PostHog + Sentry). Opt-out, on
        // by default, and inert without release-injected keys. Started before
        // the `mo` gate so a launch with the engine missing still counts.
        Telemetry.start()

        // No engine yet → guided install instead of a dead-end quit. The
        // window's Recheck calls startServices() once `mo` is found.
        //
        // Discovery can shell out to `which mo` (MoleCLI.discover) when mo
        // isn't in a trusted Homebrew path — a blocking Process wait that must
        // never run on the main thread at launch (issue #72 / Sentry BURROW-1:
        // a ~2 s+ app-hang on cold launch). Probe off-main, then gate startup
        // back on the main thread. The brief window with no UI is fine; the
        // status item / install window appear a beat later instead of after a
        // freeze.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = MoleCLI.findExecutable() != nil
            DispatchQueue.main.async {
                guard let self else { return }
                if found {
                    self.startServices()
                } else {
                    Telemetry.capture("engine_missing")
                    self.showInstallWindow()
                }
            }
        }
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
            alert.runModalQuiet()
            NSApp.terminate(nil)
            return
        }
        self.db = db

        if Store.queryServerEnabled {
            let port = UInt16(clamping: Store.queryServerPort)
            self.queryServer = QueryServer(db: db, port: port)
            self.queryServer?.start()
        }

        // One engine for everything metric-shaped: the periodic `mo status`
        // snapshot (patched, persisted, published) AND the 1 s live net/disk
        // feed for tiles and charts. See SnapshotProducer.swift.
        let producer = SnapshotProducer(deps: .live(db: db))
        self.producer = producer
        producer.start()

        let maintenance = Maintenance(db: db)
        self.maintenance = maintenance
        maintenance.start()

        // Completion notices + opt-in smart reminders. The delegate must
        // be set before any notification is delivered or clicked.
        // startReminders() also requests notification permission up front
        // (when a notifying feature is on) so the grant is settled at launch,
        // not mid-notification. (Main-actor hop: the notifier is @MainActor,
        // this delegate callback isn't.)
        Task { @MainActor in
            UNUserNotificationCenter.current().delegate = BurrowNotifier.shared
            BurrowNotifier.shared.startReminders()
        }

        if Store.showMenuBarIcon {
            self.statusBar = StatusBarController(db: db, producer: producer, delegate: self)
        }
        self.setupMainMenu()

        // Background self-update: opt-in (default on), surfaces a found
        // Burrow release as the in-window banner + a menu-bar dot. Never
        // installs; the menu/Settings "Check for Updates" stays the manual path.
        Task { @MainActor in AppUpdate.shared.begin() }

        // Crash safety for the Clean review's whitelist session: a fenced
        // block left by a previous run must never outlive it.
        DispatchQueue.global(qos: .utility).async { try? MoleWhitelist.live.endSession() }

        // Global shortcuts (recorded in Settings ▸ Menu Bar).
        HotKeyCenter.shared.handlers[.openBurrow] = { [weak self] in
            guard #available(macOS 14, *) else { return }
            if let window = self?.mainWC?.window, window.isVisible, NSApp.isActive {
                window.performClose(nil)
            } else {
                self?.openMainWindow(initial: .home)
            }
        }
        HotKeyCenter.shared.handlers[.keepScreenOn] = {
            Awake.shared.isActive ? Awake.shared.stop() : Awake.shared.start(.untilOff)
        }
        HotKeyCenter.shared.handlers[.cleanScreen] = { CleanScreen.shared.toggle() }
        HotKeyCenter.shared.applyAll()

        // First run (after the mo gate — MoleInstallView is slide 0): the
        // two onboarding slides, once. Finishing sets the flag; closing the
        // window without finishing shows it again next launch. The dev
        // open-on-launch affordance below bypasses it (BURROW_OPEN_ON_LAUNCH
        // targets a specific pane; "onboarding" targets these slides).
        let devLaunchTab = Foundation.ProcessInfo.processInfo.environment["BURROW_OPEN_ON_LAUNCH"]
        if (devLaunchTab == nil && !Store.onboardingCompleted) || devLaunchTab == "onboarding",
           #available(macOS 14, *) {
            self.showOnboardingWindow()
            return
        }

        // Without the menu-bar icon there's no agent entry point (the app is
        // LSUIElement, so no Dock icon either). Run as a regular Dock app and
        // open the window on launch so it stays reachable (issue #4).
        if !Store.showMenuBarIcon, #available(macOS 14, *) {
            NSApp.setActivationPolicy(.regular)
            self.openMainWindow(initial: .home)
        }

        // Dev affordance: launch with BURROW_OPEN_ON_LAUNCH=1 to pop the
        // main window straight away (used for screenshot/verify loops).
        if let tab = devLaunchTab,
           #available(macOS 14, *) {
            if tab == "hud" {
                // Dev/verify: render the HUD content in a normal window so it can
                // be screenshotted (the real popover needs a menu-bar click).
                let host = NSHostingView(rootView: PopupView(db: db, live: producer.live,
                                                             feeds: self.feeds, delegate: self))
                let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 334, height: 720),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
                win.title = "HUD Preview (dev)"
                win.contentView = host
                win.setContentSize(host.fittingSize)
                win.center()
                NSApp.setActivationPolicy(.regular)
                win.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                self.hudPreview = win
            } else {
                let pane: Pane
                if tab == "settings" { pane = .settings }
                else if tab == "home" || tab == "status" || tab == "history" || tab == "activity" { pane = .home }
                else if let tool = Tool(rawValue: tab), Tool.navOrder.contains(tool) { pane = .tool(tool) }
                else { pane = .home }
                self.openMainWindow(initial: pane)
            }
        }
    }

    /// Settings ▸ General ▸ "Replay onboarding": clear the seen flag and
    /// present the slides again right away — the same window path as first
    /// run, so finishing them re-sets the flag and lands on Home.
    @available(macOS 14, *)
    func replayOnboarding() {
        Store.onboardingCompleted = false
        if let wc = onboardingWC {
            wc.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        showOnboardingWindow()
    }

    /// First-run onboarding window: plain chrome, traffic lights only.
    /// Finishing marks onboarding complete and opens the main window.
    @available(macOS 14, *)
    private func showOnboardingWindow() {
        // Engine gate, restated at the onboarding door: the launch path
        // already checks `mo` before startServices(), but onboarding can
        // also be forced (BURROW_OPEN_ON_LAUNCH=onboarding) and the engine
        // can vanish between gate and slides. The slides assume a working
        // engine, so route into the guided install instead — its Recheck
        // re-enters startServices() and lands back here.
        guard MoleCLI.findExecutable() != nil else {
            showInstallWindow()
            return
        }
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        let view = OnboardingView(onFinish: { [weak self] in
            Store.onboardingCompleted = true
            Telemetry.capture("onboarding_completed")
            // Settle notification permission now the user has finished setup —
            // up front, before any completion notice or reminder needs it.
            // (Hop to the main actor: the notifier is @MainActor, this
            // SwiftUI callback isn't isolated.)
            Task { @MainActor in BurrowNotifier.shared.requestAuthorizationForEnabledFeatures() }
            self?.onboardingWC?.close()
            self?.onboardingWC = nil
            self?.openMainWindow(initial: .home)
        })
        window.contentViewController = NSHostingController(rootView: view)
        let wc = NSWindowController(window: window)
        self.onboardingWC = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        self.producer?.stop()
        self.queryServer?.stop()
        self.maintenance?.stop()
        Awake.shared.stop()
        CleanScreen.shared.hide()
        Telemetry.capture("app_terminated")
        Telemetry.flush()
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
        // If already open, just switch to the requested pane and bring the
        // window forward. NEVER reinstall the content view here — that
        // would discard live tool state (a running clean's report, scan
        // caches, purge selections) and orphan the old hosting tree's
        // timers; the live RootView switches itself on the notification.
        if let wc = self.mainWC, let window = wc.window {
            NotificationCenter.default.post(name: .burrowSelectPane, object: initial)
            NotificationCenter.default.post(name: .burrowWindowVisibility, object: true)
            NSApp.setActivationPolicy(.regular)   // Dock icon while open
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard self.db != nil, self.producer != nil else { return }
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

    /// Bring Burrow forward without forcing a pane switch — notification
    /// clicks land here so a completion notice doesn't navigate away from
    /// the finished run's receipt. Reopens the main window only when
    /// nothing is visible.
    @available(macOS 14.0, *)
    func bringForward() {
        if mainWC?.window?.isVisible == true {
            NSApp.setActivationPolicy(.regular)
            mainWC?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            openMainWindow(initial: .home)
        }
    }

    @available(macOS 14.0, *)
    private func installMainContent(into window: NSWindow, initial: Pane) {
        guard let db = self.db, let producer = self.producer else { return }
        let root = RootView(db: db, producer: producer, feeds: feeds, delegate: self, initialPane: initial)
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
        // the Dock icon so the app stays reachable (issue #4). "Hide Dock
        // Icon" off (Settings ▸ General) keeps the Dock presence too.
        if statusBar != nil, Store.hideDockIcon {
            NSApp.setActivationPolicy(.accessory)
        }
        // No live chart on screen → drop back to the idle sample cadence,
        // and tell the kept-alive content to park its polling timers.
        self.producer?.setForeground(false)
        NotificationCenter.default.post(name: .burrowWindowVisibility, object: false)
    }

    /// Clicking the Dock icon (menu-bar-disabled mode) reopens the window.
    /// When windows are already visible we return false so AppKit performs
    /// its default raise-windows behaviour rather than us suppressing it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return false }
        // Services never started (mo still missing): the main window can't
        // exist, so bring back the guided installer instead of leaving a
        // Dock icon whose clicks do nothing.
        if self.db == nil {
            if let wc = self.installWC {
                wc.showWindow(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                self.showInstallWindow()
            }
            return true
        }
        if #available(macOS 14, *) { self.openMainWindow(initial: .home) }
        return true
    }

    // MARK: - Menu-bar visibility (live)

    /// Apply the "Show menu bar icon" setting immediately, without a relaunch.
    /// Installs/removes the status item, and when hiding it keeps a Dock
    /// presence + an open window so the app never becomes unreachable.
    func applyMenuBarVisibility(_ show: Bool) {
        guard let db = db, let producer = producer else { return }
        if show {
            if statusBar == nil {
                statusBar = StatusBarController(db: db, producer: producer, delegate: self)
            } else {
                statusBar?.applyDisplayMode()   // Icon ↔ Metrics flip
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
        let about = NSMenuItem(title: NSLocalizedString("About Burrow", comment: ""),
                               action: #selector(showAboutFromMenu), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        let updates = NSMenuItem(title: NSLocalizedString("Check for Updates…", comment: ""),
                                 action: #selector(checkForUpdatesFromMenu), keyEquivalent: "")
        updates.target = self
        appMenu.addItem(updates)
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

    @objc private func showAboutFromMenu() { showAboutPanel() }
    @objc private func checkForUpdatesFromMenu() { UpdateCheck.checkNow() }

    // MARK: - About

    /// Standard About panel, with the engine version and the links that
    /// matter (repo, releases, telemetry disclosure) in the credits.
    func showAboutPanel() {
        // `mo --version` spawns a subprocess — fetch it off-main, then build
        // and present the panel on main (was a main-thread subprocess block).
        DispatchQueue.global(qos: .userInitiated).async {
            let version = MoleCLI.version().map { "v\($0)" } ?? NSLocalizedString("not found", comment: "")
            DispatchQueue.main.async { self.presentAboutPanel(moleVersion: version) }
        }
    }

    private func presentAboutPanel(moleVersion: String) {
        let credits = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        func line(_ text: String, link: String? = nil) {
            let attrs: [NSAttributedString.Key: Any] = link.map {
                [.link: URL(string: $0)!,
                 .font: NSFont.systemFont(ofSize: 11), .paragraphStyle: para]
            } ?? [.font: NSFont.systemFont(ofSize: 11),
                  .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para]
            credits.append(NSAttributedString(string: text + "\n", attributes: attrs))
        }
        line(String(format: NSLocalizedString("Mole engine %@", comment: ""), moleVersion))
        line(NSLocalizedString("Source on GitHub", comment: ""), link: "https://github.com/caezium/Burrow")
        line(NSLocalizedString("Releases", comment: ""), link: "https://github.com/caezium/Burrow/releases")
        line(NSLocalizedString("What telemetry is collected", comment: ""),
             link: "https://github.com/caezium/Burrow/blob/main/TELEMETRY.md")
        line(NSLocalizedString("Licenses", comment: ""),
             link: "https://github.com/caezium/Burrow/blob/main/LICENSE")
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
