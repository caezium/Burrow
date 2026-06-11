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

final class StatusBarController {
    private let item: NSStatusItem
    private let popover: NSPopover
    private let db: DB
    private let producer: SnapshotProducer

    init(db: DB, producer: SnapshotProducer, delegate: AppDelegate) {
        self.db = db
        self.producer = producer
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
            root: PopupView(db: db, live: producer.live, delegate: delegate))
        self.popover = popover

        if let button = self.item.button {
            // Burrow's own mark as a template glyph (adapts to the menu bar).
            button.image = BurrowIcons.menuBar
            button.action = #selector(self.handleClick(_:))
            button.target = self
        }
    }

    deinit {
        // Explicitly remove the item so toggling the menu-bar setting off
        // (AppDelegate drops its reference) clears it from the bar at once.
        NSStatusBar.system.removeStatusItem(item)
    }

    @objc private func handleClick(_ sender: Any?) {
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
}
