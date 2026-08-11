//
//  WindowMetricsTests.swift
//  BurrowTests
//
//  The window may never be allowed to get shorter than the rail.
//
//  This is a regression test for a silent failure. The minimum window height
//  was a hand-picked 940×640 duplicated in RootView and AppDelegate, while the
//  left rail's height grows with `Tool.navOrder`. Tools were added across
//  several releases, the rail passed 640 points, and Settings was clipped off
//  the bottom of the window. SwiftUI doesn't complain when it clips, so the
//  only signal was someone noticing on a small display.
//
//  These assert the relationship rather than the number, so adding a tool
//  either moves the minimum with it or fails here.
//

import XCTest
@testable import Burrow

final class WindowMetricsTests: XCTestCase {

    /// The whole point: the window's minimum must fit the rail plus the
    /// padding RootView puts around it.
    func testMinimumHeightFitsTheRailAndItsPadding() {
        let needed = RailMetrics.intrinsicHeight + WindowMetrics.railTop + WindowMetrics.railBottom
        XCTAssertGreaterThanOrEqual(
            WindowMetrics.minimumHeight, needed,
            "the window may not be shorter than the rail — Settings would be clipped")
    }

    /// The bug that shipped: with the tools we have today, the old hardcoded
    /// 640 is genuinely too short. If this ever stops holding, the rail shrank
    /// and the minimum could be reconsidered — but it should be a decision,
    /// not a surprise.
    func testTodaysRailWouldNotFitTheOldHardcodedMinimum() {
        XCTAssertGreaterThan(WindowMetrics.minimumHeight, 640,
                             "the rail outgrew the old 640pt minimum; that's why this exists")
    }

    /// Adding a tool must grow the requirement. If this fails, the height
    /// stopped depending on the tool count and the guard above is decorative.
    func testHeightGrowsWithEachTool() {
        let current = RailMetrics.intrinsicHeight(toolCount: Tool.navOrder.count)
        let oneMore = RailMetrics.intrinsicHeight(toolCount: Tool.navOrder.count + 1)
        XCTAssertGreaterThan(oneMore, current)
        XCTAssertEqual(oneMore - current, RailMetrics.buttonSize + RailMetrics.itemSpacing,
                       "one more tool costs exactly one button plus one gap")
    }

    /// The rail height is arithmetic over the layout's own constants, so pin
    /// the composition — a stray edit to the VStack that forgets one of these
    /// would otherwise silently change what "fits" means.
    func testIntrinsicHeightMatchesTheRailComposition() {
        let tools = 4
        let expected =
            RailMetrics.topPadding
            + RailMetrics.buttonSize * CGFloat(tools + 2)                 // tools + Monitor + Settings
            + (RailMetrics.dividerThickness + RailMetrics.dividerPadding * 2)
            + RailMetrics.footGap
            + RailMetrics.itemSpacing * CGFloat(tools + 4 - 1)            // gaps between all children
            + RailMetrics.bottomPadding
        XCTAssertEqual(RailMetrics.intrinsicHeight(toolCount: tools), expected)
    }

    /// Width is a deliberate content judgement, not derived — so it just has
    /// to stay sane. This catches an accidental zero or a wild value.
    func testMinimumWidthStaysReasonable() {
        XCTAssertEqual(WindowMetrics.minimumSize.width, WindowMetrics.minimumWidth)
        XCTAssertGreaterThanOrEqual(WindowMetrics.minimumWidth, 900)
        XCTAssertLessThanOrEqual(WindowMetrics.minimumWidth, 1400,
                                 "a minimum this large stops fitting on small laptops")
    }

    /// The minimum must fit on the smallest display Burrow supports. A
    /// 13-inch MacBook Air is 1440×900 in points, and macOS reserves the menu
    /// bar, so anything approaching 900 tall is unusable there.
    func testMinimumSizeFitsASmallLaptopDisplay() {
        XCTAssertLessThanOrEqual(WindowMetrics.minimumSize.width, 1440)
        XCTAssertLessThanOrEqual(WindowMetrics.minimumSize.height, 820,
                                 "must leave room for the menu bar on a 900pt-tall display")
    }
}
