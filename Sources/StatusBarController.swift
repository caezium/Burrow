//
//  StatusBarController.swift
//  Burrow
//
//  Owns the NSStatusItem and its popover. The popover is created
//  lazily on first click and reused; its NSHostingController holds
//  the SwiftUI `PopupView` bound to the LiveFeed (for live snapshot
//  data) and the AppDelegate (for the History / Cleanup / Settings
//  buttons that open windows).
//
//  Icon: `chart.line.uptrend.xyaxis`. Reads as "this thing tracks
//  something over time" — semantically aligned with what Burrow does.
//  Template image so it adapts to light/dark menu bars.
//

import AppKit
import SwiftUI
import Combine

final class StatusBarController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let popover: NSPopover
    private let db: DB
    private let producer: SnapshotProducer
    private weak var delegate: AppDelegate?
    private var metricsSub: AnyCancellable?

    init(db: DB, producer: SnapshotProducer, delegate: AppDelegate) {
        self.db = db
        self.producer = producer
        self.delegate = delegate
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Build the popover before the button-target line below so all
        // `let` properties are initialized when `self` first leaks via
        // the @objc selector dispatch.
        let popover = NSPopover()
        popover.behavior = .transient
        // Dark to match the app's glass aesthetic (affects the popover
        // chrome + arrow; the HUD content paints its own dark surface).
        popover.appearance = NSAppearance(named: .darkAqua)
        // Initial size hint for the first measurement pass; HUDController
        // then drives the real (screen-capped) size via preferredContentSize.
        popover.contentSize = NSSize(width: 334, height: 560)
        popover.contentViewController = HUDController(
            root: PopupView(db: db, live: producer.live, feeds: delegate.feeds, delegate: delegate))
        self.popover = popover

        super.init()

        if let button = self.item.button {
            // Burrow's own mark as a template glyph (adapts to the menu bar).
            button.image = BurrowIcons.menuBar
            button.action = #selector(self.handleClick(_:))
            button.target = self
            // Right-click gets the quick menu; left-click keeps the HUD.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        applyDisplayMode()
    }

    /// Icon vs Metrics (Settings ▸ Menu Bar): metrics renders live CPU% +
    /// memory next to the mark, refreshed as snapshots arrive.
    func applyDisplayMode() {
        guard let button = item.button else { return }
        if Store.menuBarDisplayMode == .metrics {
            button.imagePosition = .imageLeft
            metricsSub = producer.live.$lastSnapshot
                .receive(on: DispatchQueue.main)
                .sink { [weak self] snapshot in
                    guard let button = self?.item.button, let s = snapshot else { return }
                    let mem = Double(s.memory.used) / 1_073_741_824
                    button.title = String(format: " %.0f%% · %.1fG", s.cpu.usage, mem)
                    button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
                }
        } else {
            metricsSub = nil
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    deinit {
        // Explicitly remove the item so toggling the menu-bar setting off
        // (AppDelegate drops its reference) clears it from the bar at once.
        NSStatusBar.system.removeStatusItem(item)
    }

    @objc private func handleClick(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showQuickMenu()
            return
        }
        guard let button = self.item.button else { return }
        if self.popover.isShown {
            self.popover.performClose(sender)
        } else {
            self.popover.show(relativeTo: button.bounds,
                              of: button,
                              preferredEdge: .minY)
            // Pull focus so the popover's keyboard shortcuts (⌘Q etc.)
            // are reachable without a second click.
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Right-click quick menu

    private func showQuickMenu() {
        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(makeItem(NSLocalizedString("Open Burrow", comment: ""),
                              action: #selector(openBurrow)))
        menu.addItem(makeItem(NSLocalizedString("Settings…", comment: ""),
                              action: #selector(openSettings), key: ","))
        menu.addItem(.separator())

        // Keep Screen On ▸ durations, with a checkmark while active.
        let awakeItem = NSMenuItem(title: NSLocalizedString("Keep Screen On", comment: ""),
                                   action: nil, keyEquivalent: "")
        awakeItem.state = Awake.shared.isActive ? .on : .off
        let awakeMenu = NSMenu()
        for duration in Awake.Duration.allCases {
            let di = NSMenuItem(title: duration.label, action: #selector(startAwake(_:)), keyEquivalent: "")
            di.target = self
            di.representedObject = duration
            awakeMenu.addItem(di)
        }
        if Awake.shared.isActive {
            awakeMenu.addItem(.separator())
            awakeMenu.addItem(makeItem(NSLocalizedString("Turn Off", comment: ""), action: #selector(stopAwake)))
        }
        awakeItem.submenu = awakeMenu
        menu.addItem(awakeItem)

        let cleanItem = makeItem(NSLocalizedString("Clean Screen", comment: ""), action: #selector(cleanScreen))
        cleanItem.state = CleanScreen.shared.isActive ? .on : .off
        menu.addItem(cleanItem)
        menu.addItem(.separator())
        menu.addItem(makeItem(NSLocalizedString("About Burrow", comment: ""), action: #selector(showAbout)))
        menu.addItem(makeItem(NSLocalizedString("Check for Updates…", comment: ""), action: #selector(checkUpdates)))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: NSLocalizedString("Quit Burrow", comment: ""),
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        // Pop the menu without permanently assigning it (which would
        // hijack left-clicks too).
        item.menu = menu
        item.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        item.menu = nil
    }

    private func makeItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func openBurrow() {
        if #available(macOS 14, *) { delegate?.openMainWindow(initial: .home) }
    }
    @objc private func openSettings() {
        if #available(macOS 14, *) { delegate?.openMainWindow(initial: .settings) }
    }
    @objc private func startAwake(_ sender: NSMenuItem) {
        guard let duration = sender.representedObject as? Awake.Duration else { return }
        Awake.shared.start(duration)
    }
    @objc private func stopAwake() { Awake.shared.stop() }
    @objc private func cleanScreen() { CleanScreen.shared.toggle() }
    @objc private func showAbout() { delegate?.showAboutPanel() }
    @objc private func checkUpdates() { UpdateCheck.checkNow() }
}
