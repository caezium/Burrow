//
//  WindowMetrics.swift
//  Burrow
//
//  One definition of how small the main window may get.
//
//  This exists because the number drifted. The minimum was a hand-picked
//  940×640 written in two places — RootView's `.frame(minHeight:)` and
//  AppDelegate's `window.minSize` — while the left rail's height is a
//  function of how many tools are in `Tool.navOrder`. Tools were added over
//  several releases, the rail grew past 640, and Settings fell off the bottom
//  of the window. Nothing failed: SwiftUI just clipped it.
//
//  So the height is derived from the rail rather than chosen. Add a tool and
//  the minimum moves with it, and `WindowMetricsTests` fails if the two ever
//  come apart again.
//

import CoreGraphics

enum WindowMetrics {
    // Rail placement inside RootView's ZStack.
    static let railLeading: CGFloat = 14
    static let railTop: CGFloat = 10
    static let railBottom: CGFloat = 14

    /// The narrowest the window may be.
    ///
    /// Width is a content judgement, not a derived one — the widest panes
    /// (Analyze's treemap, the process tables) stop being readable below
    /// this — so it stays a deliberate constant.
    static let minimumWidth: CGFloat = 940

    /// The shortest the window may be: exactly enough for the rail, which is
    /// the tallest fixed-height thing in the window. Everything else scrolls.
    static var minimumHeight: CGFloat {
        RailMetrics.intrinsicHeight + railTop + railBottom
    }

    static var minimumSize: CGSize {
        CGSize(width: minimumWidth, height: minimumHeight)
    }
}
