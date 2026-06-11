//
//  SelectionSessionTests.swift
//  BurrowTests
//
//  Boundary tests for the interactive selection driver, modeled as a pure
//  reducer: feed it events (a terminal frame arrived, a logical tick, the user
//  pressed Remove) and assert the state it reaches and the effects (keystrokes /
//  quit) it emits. No pseudo-terminal, no wall-clock — the scenarios that were
//  previously only validatable by driving real `mo --dry-run` out of process
//  now run in-suite.
//

import XCTest
@testable import Burrow

final class SelectionSessionTests: XCTestCase {

    // A real `mo installer` scan frame: header + three unchecked rows + footer.
    private let scanFrame = """
    Select Installers to Remove , 0B, 0 selected
    \u{27A4} \u{25CB} a.dmg   771KB | Desktop
      \u{25CB} b.dmg   760KB | Desktop
      \u{25CB} c.dmg   1.26GB | Desktop
    \u{2191}\u{2193}  |  Space Select  |  Enter Confirm  |  A All  |  I Invert  |  Q Quit
    """

    // MARK: - Phase 1: scan path

    func testScan_reachesChoosingWithParsedItems() {
        let (s, _) = SelectionSession.reduce(SelectionSession.State(), .output(scanFrame))
        XCTAssertEqual(s.phase, .choosing)
        XCTAssertEqual(s.items.map(\.name), ["a.dmg", "b.dmg", "c.dmg"])
        XCTAssertEqual(s.totalCount, 3)
    }

    func testScan_processExitsBeforeAnyList_isDone() {
        // Mole exits before rendering a list — usually "nothing to remove".
        let (s, effects) = SelectionSession.reduce(SelectionSession.State(), .processExited(0))
        XCTAssertEqual(s.phase, .done(0))
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - Phase 2: confirm path

    /// Drive a fresh session to `choosing` over the scan frame.
    private func choosing() -> SelectionSession.State {
        SelectionSession.reduce(SelectionSession.State(), .output(scanFrame)).0
    }

    func testConfirm_emitsSelectionKeystrokesAndEntersApplying() {
        let (s, effects) = SelectionSession.reduce(choosing(), .confirmRequested([1]))
        XCTAssertEqual(s.phase, .applyingViewport)
        XCTAssertEqual(effects, [.send(MoTUI.keystrokesToSelect([1], count: 3, confirm: false))])
    }

    func testConfirm_emptySelection_doesNothing() {
        let (s, effects) = SelectionSession.reduce(choosing(), .confirmRequested([]))
        XCTAssertEqual(s.phase, .choosing)
        XCTAssertTrue(effects.isEmpty)
    }

    // b.dmg (index 1) now checked (●), cursor on it.
    private let selectedFrame = """
    Select Installers to Remove , 760KB, 1 selected
      \u{25CB} a.dmg   771KB | Desktop
    \u{27A4} \u{25CF} b.dmg   760KB | Desktop
      \u{25CB} c.dmg   1.26GB | Desktop
    \u{2191}\u{2193}  |  Space Select  |  Enter Confirm  |  A All  |  I Invert  |  Q Quit
    """

    func testApplyingViewport_settledAndSafe_proceedsToConfirm() {
        var s = SelectionSession.reduce(choosing(), .confirmRequested([1])).0
        s = SelectionSession.reduce(s, .output(selectedFrame)).0   // Mole redrew with b checked
        s = SelectionSession.reduce(s, .tick).0                    // 1st read: records selection
        XCTAssertEqual(s.phase, .applyingViewport, "not settled after one read")
        let (s2, effects) = SelectionSession.reduce(s, .tick)      // 2nd read: stable + safe
        XCTAssertEqual(s2.phase, .awaitingConfirm)
        XCTAssertEqual(effects, [.send([0x0d])])                   // Enter → proceed
    }

    /// Drive a 1-item selection all the way to `awaitingConfirm`.
    private func awaitingConfirm() -> SelectionSession.State {
        var s = SelectionSession.reduce(choosing(), .confirmRequested([1])).0
        s = SelectionSession.reduce(s, .output(selectedFrame)).0
        s = SelectionSession.reduce(s, .tick).0
        s = SelectionSession.reduce(s, .tick).0
        // XCTFail, not precondition: a reducer regression must fail the
        // calling case, not crash the whole hosted suite.
        if s.phase != .awaitingConfirm { XCTFail("fixture expected .awaitingConfirm, got \(s.phase)") }
        return s
    }

    func testAwaitingConfirm_countMatchesDeleteWording_sendsFinalConfirm() {
        // Regression guard: installer says "Delete N installers", not "Remove N".
        var s = awaitingConfirm()
        s = SelectionSession.reduce(s, .output("➤ Delete 1 installers, 760KB  Enter confirm, ESC cancel: ")).0
        let (s2, effects) = SelectionSession.reduce(s, .tick)
        XCTAssertEqual(s2.phase, .confirming)
        XCTAssertEqual(effects, [.send([0x0d])])     // final Enter → Mole deletes
    }

    func testAwaitingConfirm_countMismatch_abortsWithoutDeleting() {
        var s = awaitingConfirm()                    // user picked 1
        s = SelectionSession.reduce(s, .output("➤ Remove 3 artifacts, 4GB  Enter confirm, ESC cancel: ")).0
        let (s2, effects) = SelectionSession.reduce(s, .tick)
        if case .failed = s2.phase {} else { XCTFail("must abort on count mismatch") }
        XCTAssertEqual(effects, [.send([0x1b]), .send(MoTUI.quit)])  // ESC + quit, never Enter
        XCTAssertFalse(effects.contains(.send([0x0d])), "must not send the confirming Enter")
    }

    func testAwaitingConfirm_neverReachesConfirmScreen_timesOut() {
        var s = awaitingConfirm()
        // No confirm screen ever arrives; ticks should eventually give up safely.
        for _ in 0..<80 { s = SelectionSession.reduce(s, .tick).0 }
        if case .failed = s.phase {} else { XCTFail("must time out into failed, not hang") }
    }

    private func confirming() -> SelectionSession.State {
        var s = awaitingConfirm()
        s = SelectionSession.reduce(s, .output("➤ Delete 1 installers, 760KB  Enter confirm, ESC cancel: ")).0
        s = SelectionSession.reduce(s, .tick).0
        if s.phase != .confirming { XCTFail("fixture expected .confirming, got \(s.phase)") }
        return s
    }

    func testConfirming_collectsResultAndFinishesOnExit() {
        var s = confirming()
        s = SelectionSession.reduce(s, .output("\nRemoved 1 installer, freed 760KB\n")).0
        let (s2, _) = SelectionSession.reduce(s, .processExited(0))
        XCTAssertEqual(s2.phase, .done(0))
        XCTAssertTrue(s2.resultText.contains("Removed 1 installer"))
    }

    // MARK: - Phase 3: scroll-capture ("Show all")

    // A purge-style scan: header "[1/4]" reports 4 total, viewport shows 3.
    private let scan4 = """
    Select Categories to Clean [1/4], 0B, 0 selected
    \u{27A4} \u{25CB} ~/p/a   3GB | node_modules | 1d
      \u{25CB} ~/p/b   2GB | node_modules | 1d
      \u{25CB} ~/p/c   1GB | node_modules | 1d
    \u{2191}\u{2193} | Space Select | Enter Confirm | A All | I Invert | Q Quit
    """
    // After one Down, Mole scrolls: rows b,c,d (d newly revealed).
    private let scrolled4 = """
    Select Categories to Clean [2/4], 0B, 0 selected
      \u{25CB} ~/p/b   2GB | node_modules | 1d
      \u{25CB} ~/p/c   1GB | node_modules | 1d
    \u{27A4} \u{25CB} ~/p/d   0.5GB | node_modules | 1d
    \u{2191}\u{2193} | Space Select | Enter Confirm | A All | I Invert | Q Quit
    """

    // Verify-scroll frames: a (●) on top, then d (●) after scrolling.
    private let topChecked = """
    Select Categories to Clean [1/4], 3GB, 1 selected
    \u{27A4} \u{25CF} ~/p/a   3GB | node_modules | 1d
      \u{25CB} ~/p/b   2GB | node_modules | 1d
      \u{25CB} ~/p/c   1GB | node_modules | 1d
    \u{2191}\u{2193} | Space Select | Enter Confirm | A All | I Invert | Q Quit
    """
    private let scrolledChecked = """
    Select Categories to Clean [2/4], 3.5GB, 2 selected
      \u{25CB} ~/p/b   2GB | node_modules | 1d
      \u{25CB} ~/p/c   1GB | node_modules | 1d
    \u{27A4} \u{25CF} ~/p/d   0.5GB | node_modules | 1d
    \u{2191}\u{2193} | Space Select | Enter Confirm | A All | I Invert | Q Quit
    """
    // Wrong: c is checked instead of d.
    private let scrolledWrong = """
    Select Categories to Clean [2/4], 4GB, 2 selected
      \u{25CB} ~/p/b   2GB | node_modules | 1d
    \u{27A4} \u{25CF} ~/p/c   1GB | node_modules | 1d
      \u{25CB} ~/p/d   0.5GB | node_modules | 1d
    \u{2191}\u{2193} | Space Select | Enter Confirm | A All | I Invert | Q Quit
    """

    private func loadedAll4() -> SelectionSession.State {
        var s = SelectionSession.reduce(SelectionSession.State(), .output(scan4)).0
        s = SelectionSession.reduce(s, .showAllRequested).0
        s = SelectionSession.reduce(s, .tick).0
        s = SelectionSession.reduce(s, .output(scrolled4)).0
        s = SelectionSession.reduce(s, .tick).0
        if !(s.items.count == 4 && s.viewportCount == 3 && s.fullyLoaded) {
            XCTFail("fixture expected 4 items / viewport 3 / fully loaded, got \(s.items.count)/\(s.viewportCount)/\(s.fullyLoaded)")
        }
        return s
    }

    func testFullSelection_verifies_proceedsWhenCheckedMatches() {
        var s = loadedAll4()
        let (s0, e0) = SelectionSession.reduce(s, .confirmRequested([0, 3]))  // a + d, spans boundary
        XCTAssertEqual(s0.phase, .applyingFull)
        XCTAssertEqual(e0.count, 2, "selection walk + return-to-top")
        s = s0
        s = SelectionSession.reduce(s, .output(topChecked)).0
        let (s1, _) = SelectionSession.reduce(s, .tick)        // sees a checked; not all rows yet → scroll
        XCTAssertEqual(s1.phase, .applyingFull)
        s = s1
        s = SelectionSession.reduce(s, .output(scrolledChecked)).0
        let (s2, e2) = SelectionSession.reduce(s, .tick)       // all rows seen; checked == {a,d}
        XCTAssertEqual(s2.phase, .awaitingConfirm)
        XCTAssertEqual(e2, [.send([0x0d])])
    }

    func testFullSelection_verifyMismatch_abortsWithoutDeleting() {
        var s = loadedAll4()
        s = SelectionSession.reduce(s, .confirmRequested([0, 3])).0   // wanted a + d
        s = SelectionSession.reduce(s, .output(topChecked)).0         // a checked
        s = SelectionSession.reduce(s, .tick).0
        s = SelectionSession.reduce(s, .output(scrolledWrong)).0      // c checked, NOT d
        let (s2, e2) = SelectionSession.reduce(s, .tick)
        if case .failed = s2.phase {} else { XCTFail("must abort when checked rows disagree with the selection") }
        XCTAssertEqual(e2, [.send(MoTUI.quit)])
        XCTAssertFalse(e2.contains(.send([0x0d])))
    }

    func testShowAll_scrollCaptureStitchesAllItemsInOrder() {
        var s = SelectionSession.reduce(SelectionSession.State(), .output(scan4)).0
        XCTAssertEqual(s.items.count, 3)
        XCTAssertEqual(s.totalCount, 4)

        s = SelectionSession.reduce(s, .showAllRequested).0
        XCTAssertEqual(s.phase, .loadingAll)

        // First tick: nothing new on screen yet → scroll down one row.
        let (s1, e1) = SelectionSession.reduce(s, .tick)
        XCTAssertEqual(e1, [.send(MoTUI.down)])
        s = s1

        // Host scrolled; Mole redrew revealing the 4th item.
        s = SelectionSession.reduce(s, .output(scrolled4)).0

        // Next tick: merges the 4th item → total reached → return to top, done loading.
        let (s2, e2) = SelectionSession.reduce(s, .tick)
        XCTAssertEqual(s2.phase, .choosing)
        XCTAssertTrue(s2.fullyLoaded)
        XCTAssertEqual(s2.items.map(\.name), ["~/p/a", "~/p/b", "~/p/c", "~/p/d"])
        let expectedUps = Array(repeating: MoTUI.up, count: s2.items.count + 5).flatMap { $0 }
        XCTAssertEqual(e2, [.send(expectedUps)], "returns the cursor to the top")
    }
}
