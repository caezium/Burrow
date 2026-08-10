//
//  CleanSelectionTests.swift
//  BurrowTests
//
//  Selection model behind the Clean review screen (design 1.4):
//  per-item ticks, tri-state categories, live totals for the
//  "Permanently clean · N GB" pill, and the whitelist-session exclusion
//  list. Locked items (app open / system busy) start unticked and stay
//  untickable — the engine must not delete a cache out from under a
//  running app the UI just promised to skip.
//

import XCTest
@testable import Burrow

final class CleanSelectionTests: XCTestCase {
    func makeList() -> CleanList {
        CleanList.parse("""
        === App caches ===
        /u/Library/Caches/safe-one  # 100MB, 3 items
        /u/Library/Caches/net.imput.helium  # 400MB
        === Developer tools ===
        /u/.npm/_cacache  # 1.23GB, 3 items
        """)
    }

    func testDefaults_unlockedTickedLockedNot() {
        let sel = CleanSelection(list: makeList(),
                                 locked: ["/u/Library/Caches/net.imput.helium": .appOpen(appName: "Helium")])
        XCTAssertTrue(sel.isTicked("/u/Library/Caches/safe-one"))
        XCTAssertTrue(sel.isTicked("/u/.npm/_cacache"))
        XCTAssertFalse(sel.isTicked("/u/Library/Caches/net.imput.helium"))
        XCTAssertEqual(sel.selectedCount, 2)
        XCTAssertEqual(sel.totalCount, 3)
    }

    func testLockedItems_cannotBeTicked() {
        var sel = CleanSelection(list: makeList(),
                                 locked: ["/u/Library/Caches/net.imput.helium": .appOpen(appName: "Helium")])
        sel.toggle("/u/Library/Caches/net.imput.helium")
        XCTAssertFalse(sel.isTicked("/u/Library/Caches/net.imput.helium"))
        sel.selectAll()
        XCTAssertFalse(sel.isTicked("/u/Library/Caches/net.imput.helium"))
    }

    func testCategoryTriState() {
        var sel = CleanSelection(list: makeList(), locked: [:])
        XCTAssertEqual(sel.categoryState("App caches"), .all)
        sel.toggle("/u/Library/Caches/safe-one")
        XCTAssertEqual(sel.categoryState("App caches"), .mixed)
        sel.toggle("/u/Library/Caches/net.imput.helium")
        XCTAssertEqual(sel.categoryState("App caches"), .none)
    }

    func testCategoryToggle_ticksAllThenNone() {
        var sel = CleanSelection(list: makeList(), locked: [:])
        sel.toggleCategory("App caches")   // from .all → none
        XCTAssertEqual(sel.categoryState("App caches"), .none)
        sel.toggleCategory("App caches")   // from .none → all
        XCTAssertEqual(sel.categoryState("App caches"), .all)
        sel.toggle("/u/Library/Caches/safe-one")
        sel.toggleCategory("App caches")   // mixed → all
        XCTAssertEqual(sel.categoryState("App caches"), .all)
    }

    func testSelectedBytes_drivesThePill() {
        var sel = CleanSelection(list: makeList(), locked: [:])
        let all = CleanList.parseSize("100MB") + CleanList.parseSize("400MB") + CleanList.parseSize("1.23GB")
        XCTAssertEqual(sel.selectedBytes, all)
        sel.toggle("/u/.npm/_cacache")
        XCTAssertEqual(sel.selectedBytes, CleanList.parseSize("100MB") + CleanList.parseSize("400MB"))
    }

    /// Unticked paths — including locked ones — are exactly what the
    /// whitelist session protects during the real run.
    func testExcludedPaths_areTheUnticked() {
        var sel = CleanSelection(list: makeList(),
                                 locked: ["/u/Library/Caches/net.imput.helium": .appOpen(appName: "Helium")])
        sel.toggle("/u/.npm/_cacache")
        XCTAssertEqual(Set(sel.excludedPaths),
                       ["/u/Library/Caches/net.imput.helium", "/u/.npm/_cacache"])
    }

    /// The subtitle intelligence line: locked apps by name + the upside.
    func testLockedSummary_namesAndSizes() {
        let sel = CleanSelection(list: makeList(),
                                 locked: ["/u/Library/Caches/net.imput.helium": .appOpen(appName: "Helium")])
        let summary = sel.lockedSummary
        XCTAssertEqual(summary?.appNames, ["Helium"])
        XCTAssertEqual(summary?.bytes, CleanList.parseSize("400MB"))
        XCTAssertEqual(summary?.itemCount, 1)
    }

    func testLockedSummary_nilWhenNothingLocked() {
        XCTAssertNil(CleanSelection(list: makeList(), locked: [:]).lockedSummary)
    }

    /// The line says "Close X to clean another N". An entry the snapshot refused
    /// is not something closing an app recovers, so it must not appear in the
    /// count OR the byte total — and when it is the only locked entry there is
    /// no advice to give, so the header falls back to the neutral message
    /// instead of naming no app at all.
    func testLockedSummary_ignoresEntriesNoAppIsHolding() {
        let refused = CleanSelection(
            list: makeList(),
            locked: ["/u/Library/Caches/net.imput.helium": .notCleanable(reason: "outside the approved roots")])
        XCTAssertNil(refused.lockedSummary)

        let mixed = CleanSelection(
            list: makeList(),
            locked: ["/u/Library/Caches/net.imput.helium": .appOpen(appName: "Helium"),
                     "/u/.npm/_cacache": .notCleanable(reason: "outside the approved roots")])
        let summary = mixed.lockedSummary
        XCTAssertEqual(summary?.appNames, ["Helium"])
        XCTAssertEqual(summary?.itemCount, 1, "the refused entry must not inflate the count")
        XCTAssertEqual(summary?.bytes, CleanList.parseSize("400MB"),
                       "nor the bytes closing Helium would actually free")
    }
}
