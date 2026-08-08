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

final class StatusBarController: NSObject, NSMenuDelegate, NSPopoverDelegate {
    private let item: NSStatusItem
    private let popover: NSPopover
    /// Invisible helper window pinned at the status button's screen position,
    /// used to anchor the popover instead of the button itself. With an
    /// auto-hiding / auto-collapsing menu bar, macOS shoves the status item's
    /// own window to the screen's left edge when the bar hides, and a popover
    /// anchored to that button rides along with it (issue #223). Anchoring to a
    /// window we place and own keeps the popover put. Alive only while shown.
    private var anchorWindow: NSWindow?
    /// The screen-space frame the anchor was pinned to at show time, so it can be
    /// re-asserted if the menu bar later collapses (see `screenParamsObserver`).
    private var anchorFrame: NSRect = .zero
    /// Fires while the popover is open: an auto-hiding menu bar collapsing
    /// changes the screen's visibleFrame (a screen-parameters change) and
    /// reshuffles status-bar-level windows, dragging the anchor — and the popover
    /// — to the corner. We re-pin and re-position on that event (issue #223).
    private var screenParamsObserver: NSObjectProtocol?
    private let db: DB
    private let producer: SnapshotProducer
    private weak var delegate: AppDelegate?
    private var metricsSub: AnyCancellable?
    /// 1 Hz net/disk-rate updates for the metrics row (separate from the
    /// snapshot sink so live throughput animates between snapshots).
    private var samplesSub: AnyCancellable?
    /// Rolling per-metric history for the menu-bar sparkline style, appended
    /// at the snapshot cadence (net/disk sparklines read straight off the
    /// live ring instead).
    private var menuBarHistory: [MenuBarMetric: [Double]] = [:]
    /// The animated runner (RunCat-style). A one-shot timer on main advances
    /// frames and re-arms at an interval that tracks the chosen metric, so the
    /// animation literally speeds up under load.
    private let runner = RunnerEngine()
    private var runnerTimer: DispatchSourceTimer?
    /// Latest metric-row image, cached so the runner timer can composite
    /// `frame + row` without re-rendering the row every frame (prepend mode).
    private var cachedRowImage: NSImage?
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

        // Tear down the anchor window once the (transient) popover closes.
        self.popover.delegate = self

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

    /// Icon vs Metrics (Settings ▸ Menu Bar). Metrics renders the user's
    /// configured `Store.menuBarItems` row (issue #82); icon shows the mark.
    /// Safe to call again to apply a settings change live.
    func applyDisplayMode() {
        guard let button = item.button else { return }
        metricsSub = nil
        samplesSub = nil
        switch Store.menuBarDisplayMode {
        case .icon:
            stopRunner()
            menuBarHistory.removeAll()
            button.image = BurrowIcons.menuBar
            button.imagePosition = .imageOnly
            button.title = ""
        case .metrics:
            // Snapshot sink: CPU/RAM/GPU/disk/fan/temp/battery + sparkline history.
            metricsSub = producer.live.$lastSnapshot
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.onSnapshot() }
            // 1 Hz sink: live net/disk rates + their sparklines.
            samplesSub = producer.live.$samples
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.renderMetrics() }
            if Store.runnerConfig.prependToRow { startRunner() } else { stopRunner() }
            renderMetrics()
        case .runner:
            // Standalone: the frame timer reads currentValues() each tick for
            // both the animation speed and the optional value — no sinks needed.
            menuBarHistory.removeAll()
            startRunner()
        }
    }

    /// Snapshot tick: extend the cpu/mem/gpu sparkline rings (only the snapshot
    /// carries those series), then redraw.
    private func onSnapshot() {
        guard Store.menuBarDisplayMode == .metrics, let s = producer.live.lastSnapshot else { return }
        appendHistory(.cpu, s.cpu.usage)
        appendHistory(.memory, s.memory.usedPercent)
        if let g = s.gpu?.first, g.usage >= 0 { appendHistory(.gpu, g.usage) }
        if let p = s.thermal?.systemPower, p > 0 { appendHistory(.power, p) }
        renderMetrics()
    }

    private func appendHistory(_ m: MenuBarMetric, _ v: Double) {
        var ring = menuBarHistory[m] ?? []
        ring.append(v)
        // Keep up to 120 — the largest sparkline history-points option.
        if ring.count > 120 { ring.removeFirst(ring.count - 120) }
        menuBarHistory[m] = ring
    }

    /// Assemble the current values and draw the row into the status button.
    /// Deliberately cheap (a few strings + shapes) and reads only already-
    /// published live values — never the running-app list or other blocking
    /// work, so the menu bar can't add to the main-thread budget.
    private func renderMetrics() {
        guard let button = item.button, Store.menuBarDisplayMode == .metrics else { return }
        let row = MenuBarRenderer.image(items: Store.menuBarItems, values: currentValues())
        cachedRowImage = row
        // When the runner is prepended, the frame timer owns button.image (it
        // composites frame + cachedRowImage); only draw the bare row otherwise.
        if !Store.runnerConfig.prependToRow {
            button.image = row ?? BurrowIcons.menuBar
            button.imagePosition = .imageOnly
            button.title = ""
        }
    }

    /// Snapshot of every metric the row might draw, read on the main thread
    /// from the live feed (which is itself main-thread-confined).
    private func currentValues() -> MenuBarMetricValues {
        var v = MenuBarMetricValues()
        let live = producer.live
        if let s = live.lastSnapshot {
            v.primary[.cpu] = s.cpu.usage
            v.primary[.memory] = s.memory.usedPercent
            if let g = s.gpu?.first, g.usage >= 0 { v.primary[.gpu] = g.usage }
            if let d = s.disks.first { v.primary[.diskUsage] = d.usedPercent }
            if let t = s.thermal {
                if t.fanSpeed > 0 || (t.fanCount ?? 0) > 0 { v.primary[.fan] = Double(t.fanSpeed) }
                if let temp = t.bestTemp { v.primary[.temperature] = temp }
                if t.systemPower > 0 { v.primary[.power] = t.systemPower }
            }
            if let b = s.batteries?.first {
                v.primary[.battery] = b.percent
                v.batteryCharging = b.status.lowercased().contains("charg")
            }
        }
        v.primary[.network] = live.rxMBs;   v.secondary[.network] = live.txMBs
        v.primary[.diskIO]  = live.readMBs;  v.secondary[.diskIO]  = live.writeMBs
        let recent = live.samples.suffix(120)
        v.histories[.network] = recent.map { $0.rxMBs + $0.txMBs }
        v.histories[.diskIO]  = recent.map { $0.readMBs + $0.writeMBs }
        v.histories[.cpu]    = menuBarHistory[.cpu]
        v.histories[.memory] = menuBarHistory[.memory]
        v.histories[.gpu]    = menuBarHistory[.gpu]
        v.histories[.power]  = menuBarHistory[.power]
        // Memory-pressure percentage (compressor share) for the "By pressure"
        // colour — the same signal the dashboard/popover memory tiles read.
        v.memoryPressurePercent = MemoryPressure.percent()
        return v
    }

    // MARK: - Animated runner

    /// (Re)load frames for the current config and start the frame timer.
    private func startRunner() {
        runner.reload(Store.runnerConfig, height: MenuBarRenderer.height) { [weak self] in
            self?.ensureRunnerTimer()
            self?.runnerTick()   // draw frame 0 immediately so there's no gap
        }
    }

    private func stopRunner() {
        runnerTimer?.cancel()
        runnerTimer = nil
    }

    private func ensureRunnerTimer() {
        guard runnerTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.setEventHandler { [weak self] in self?.runnerTick() }
        t.schedule(deadline: .now() + runner.interval(forUsage: runnerUsage()))
        runnerTimer = t
        t.resume()
    }

    private func armRunnerTimer() {
        runnerTimer?.schedule(deadline: .now() + runner.interval(forUsage: runnerUsage()))
    }

    /// Advance one frame, draw it (standalone or composited with the row), and
    /// re-arm at the latest speed. Cheap: a blit plus maybe one short string.
    private func runnerTick() {
        guard let button = item.button else { return }
        let mode = Store.menuBarDisplayMode
        let prepend = (mode == .metrics && Store.runnerConfig.prependToRow)
        guard mode == .runner || prepend else { stopRunner(); return }
        if let frame = runner.nextFrame() {
            if prepend {
                button.image = composite(frame: frame, trailing: cachedRowImage)
            } else if Store.runnerConfig.showValue {
                button.image = composite(frame: frame, trailing: runnerValueImage())
            } else {
                button.image = frame
            }
            button.imagePosition = .imageOnly
            button.title = ""
        }
        armRunnerTimer()
    }

    /// Normalize the driving metric into a rough 0…100 for the speed mapping.
    private func runnerUsage() -> Double {
        let v = currentValues()
        let m = Store.runnerConfig.metric
        guard let p = v.primary[m] else { return 0 }
        if m.isPercentage { return p }
        switch m {
        case .network, .diskIO: return min(100, (p + (v.secondary[m] ?? 0)) * 4)
        case .fan:              return min(100, p / 60)
        case .temperature:      return min(100, p)
        default:                return p
        }
    }

    /// The driving metric's value as a small image (standalone + "show value").
    /// Reserves a stable field for the metric and right-aligns the number into
    /// it, with the shared cap-centering — so the runner's readout tracks the
    /// user's text-size setting and doesn't jiggle as the value changes, exactly
    /// like the metric row (issue #245).
    private func runnerValueImage() -> NSImage? {
        let metric = Store.runnerConfig.metric
        let text = MenuBarRenderer.valueText(metric, currentValues())
        let font = MenuBarRenderer.valueFont(.medium)
        let fieldW = MenuBarRenderer.valueFieldWidth(metric, font: font)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let w = (text as NSString).size(withAttributes: attrs).width
        let h = MenuBarRenderer.height
        return NSImage(size: NSSize(width: max(1, fieldW), height: h), flipped: false) { _ in
            (text as NSString).draw(at: NSPoint(x: max(0, fieldW - w), y: MenuBarRenderer.centeredY(font, h)),
                                    withAttributes: attrs)
            return true
        }
    }

    /// Lay a runner `frame` and an optional `trailing` image side by side.
    private func composite(frame: NSImage, trailing: NSImage?) -> NSImage {
        let h = MenuBarRenderer.height
        let gap: CGFloat = trailing == nil ? 0 : 4
        let tw = trailing?.size.width ?? 0
        let w = frame.size.width + gap + tw
        return NSImage(size: NSSize(width: max(1, w), height: h), flipped: false) { _ in
            frame.draw(in: NSRect(x: 0, y: 0, width: frame.size.width, height: h))
            trailing?.draw(at: NSPoint(x: frame.size.width + gap, y: 0),
                           from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }

    deinit {
        if let o = screenParamsObserver { NotificationCenter.default.removeObserver(o) }
        anchorWindow?.orderOut(nil)
        runnerTimer?.cancel()
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
            self.showPopover(from: button)
            // Pull focus so the popover's keyboard shortcuts (⌘Q etc.)
            // are reachable without a second click.
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Present the HUD popover anchored to a fixed, invisible helper window
    /// pinned at the status button's *screen* position — not the button
    /// itself. See `anchorWindow`: this is what stops the popover from flying
    /// to the left edge when an auto-hiding/collapsing menu bar hides the
    /// status item's own window (issue #223).
    private func showPopover(from button: NSStatusBarButton) {
        producer.setPopoverOpen(true)   // keep live metrics flowing while shown (#235)
        guard let buttonWindow = button.window else {
            // No window to convert from — fall back to the direct anchor.
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            return
        }
        // Capture the button's frame in screen coordinates while the menu bar
        // is still up, then hold a window there that the menu bar can't move.
        let screenFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))

        let anchor = NSWindow(contentRect: screenFrame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false
        anchor.backgroundColor = .clear
        anchor.isOpaque = false
        anchor.hasShadow = false
        anchor.ignoresMouseEvents = true
        anchor.level = .statusBar
        anchor.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        anchor.contentView = NSView(frame: NSRect(origin: .zero, size: screenFrame.size))
        anchor.orderFrontRegardless()
        self.anchorWindow = anchor
        self.anchorFrame = screenFrame

        if let content = anchor.contentView {
            popover.show(relativeTo: content.bounds, of: content, preferredEdge: .minY)
        }

        // The show-time pin isn't enough: when the menu bar auto-hides *after*
        // the popover is up, the resulting screen-parameters change moves/hides
        // the anchor and NSPopover re-homes to the screen corner. Re-assert the
        // anchor's frame and re-show (which repositions a visible popover) each
        // time that fires, so it stays put through reveal/collapse. (#223)
        if screenParamsObserver == nil {
            screenParamsObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main) { [weak self] _ in
                guard let self, self.popover.isShown,
                      let anchor = self.anchorWindow, let content = anchor.contentView else { return }
                anchor.setFrame(self.anchorFrame, display: false)
                anchor.orderFrontRegardless()
                self.popover.show(relativeTo: content.bounds, of: content, preferredEdge: .minY)
            }
        }
    }

    /// Drop the anchor window once the popover is gone (transient dismiss or a
    /// second icon click), so it doesn't leak or linger over the menu bar.
    func popoverDidClose(_ notification: Notification) {
        producer.setPopoverOpen(false)   // stop live work if nothing else is watching (#235)
        if let o = screenParamsObserver { NotificationCenter.default.removeObserver(o); screenParamsObserver = nil }
        anchorWindow?.orderOut(nil)
        anchorWindow = nil
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
    @MainActor @objc private func checkUpdates() { UpdateCheck.checkNow() }
}
