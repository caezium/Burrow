//
//  HUDController.swift
//  Burrow
//
//  Hosts the menu-bar HUD (PopupView) so it can NEVER run off the bottom
//  of the screen, without a width-stealing scrollbar:
//
//    * The popover is capped to the visible screen height
//      (preferredContentSize), so however tall the content gets, the
//      dropdown stops at the screen edge.
//    * The content lives in a scroll view with FORCED overlay scrollers
//      (`scrollerStyle = .overlay`, auto-hiding). Overlay scrollers float
//      over the content and take no layout width — even when the system
//      "Show scroll bars" preference is set to "Always" (which is what
//      pushed the content left before). When the content fits, nothing
//      scrolls and no scroller shows at all.
//

import AppKit
import SwiftUI

final class HUDController: NSViewController {
    private let hosting: NSHostingView<PopupView>

    init(root: PopupView) {
        self.hosting = NSHostingView(rootView: root)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var maxHeight: CGFloat {
        // Cap to the display the popover is ACTUALLY on, not `NSScreen.main`
        // (the key-window screen — for a menu-bar app clicking a status item
        // on a secondary display there's often no key window, so `.main`
        // returns the primary). On a shorter secondary display that would size
        // the HUD taller than the screen and run it off the bottom edge — the
        // exact overflow this cap exists to prevent. `view.window` is the
        // popover's own window once shown; fall back to `.main` on the first
        // layout pass before it's attached (a later pass corrects it).
        let screen = view.window?.screen ?? NSScreen.main
        return max(360, (screen?.visibleFrame.height ?? 800) - 28)
    }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        // No scroller object at all → no scrollbar can ever appear (not
        // even with "Show scroll bars: Always"). Overflow still scrolls via
        // trackpad/wheel; in practice the panel is capped to the screen so
        // it rarely needs to.
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        // No rubber-band bounce: when the content fits (the common case) the scroll view must not
        // elastic-scroll into empty space and spring back (the reported popover-scroll bug).
        // Content past the screen-height cap still scrolls — elasticity only governs the bounce.
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false

        hosting.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = hosting
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            hosting.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            // Width == the CLIP view (not a 334 constant): if any row's intrinsic width ever
            // exceeded the popover width, a constant let the document grow wider than the
            // clip — horizontal scrolling became possible, and with elasticity .none an
            // accidental trackpad drag STUCK there, clipping the left column and showing
            // blank space on the right. Equal widths make horizontal overflow impossible;
            // SwiftUI lays out at popover width and truncates internally.
            hosting.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        self.view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The hosting view's height floats on its SwiftUI intrinsic size
        // (only top/leading/width are pinned). A document-view frame change
        // does NOT relayout the enclosing scroll view, so viewDidLayout
        // alone misses content growing or shrinking while the popover is
        // open — Activity cards appearing, the battery card mounting after
        // the first sample. Watch the frame directly and resize the popover
        // to match, so its height always tracks the content.
        hosting.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(contentFrameChanged(_:)),
                                               name: NSView.frameDidChangeNotification,
                                               object: hosting)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func contentFrameChanged(_ note: Notification) {
        syncPopoverHeight()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        syncPopoverHeight()
    }

    /// Popover height = content height, capped to the visible screen;
    /// beyond the cap the internal scroll view takes over.
    private func syncPopoverHeight() {
        // Self-heal any stuck horizontal offset (sessions that scrolled sideways before the
        // equal-width constraint landed): the HUD never scrolls horizontally, so x is 0.
        if let scroll = view as? NSScrollView, scroll.contentView.bounds.origin.x != 0 {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.origin.y))
        }
        var contentH = hosting.intrinsicContentSize.height
        if contentH <= 0 { contentH = hosting.fittingSize.height }
        let target = NSSize(width: 334, height: min(max(contentH, 1), maxHeight))
        if abs(preferredContentSize.height - target.height) > 0.5 || preferredContentSize.width != target.width {
            preferredContentSize = target
        }
    }
}
