//
//  MoInteractiveTests.swift
//  BurrowTests
//
//  The safety-critical core of driving Mole's selection TUI: parsing a
//  rendered frame and planning the toggle keystrokes. Both are pure. The
//  fixture is a real captured frame from `mo installer` (cursor on the
//  last row, two items checked).
//

import XCTest
@testable import Burrow

final class MoInteractiveTests: XCTestCase {
    // A real `mo installer` frame: row 0 unchecked, rows 1 & 2 checked,
    // cursor (➤) on row 2, header reports "2 selected".
    private let frame = """
    Select Installers to Remove , 1.26GB, 2 selected
      \u{25CB} Inkling-0.0.1.dmg                           771KB | Desktop
      \u{25CF} Inkling-0.1.0.dmg                           760KB | Desktop
    \u{27A4} \u{25CF} marvis_1.0.10034_arm64_4000000002.dmg      1.26GB | Desktop
    \u{2191}\u{2193}  |  Space Select  |  Enter Confirm  |  A All  |  I Invert  |  Q Quit
    """

    func testParse_extractsItemsSelectionCursorAndCount() {
        let screen = MoTUI.parse(frame)
        XCTAssertEqual(screen.items.count, 3)
        XCTAssertEqual(screen.items.map { $0.name },
                       ["Inkling-0.0.1.dmg", "Inkling-0.1.0.dmg", "marvis_1.0.10034_arm64_4000000002.dmg"])
        XCTAssertEqual(screen.items.map { $0.selected }, [false, true, true])
        XCTAssertEqual(screen.items[2].size, "1.26GB")
        XCTAssertEqual(screen.items[0].location, "Desktop")
        XCTAssertEqual(screen.cursor, 2, "the ➤ row")
        XCTAssertEqual(screen.selectedCount, 2)
        XCTAssertEqual(MoTUI.selectedIndices(screen), [1, 2])
    }

    func testParse_keepsOnlyTheLastFrame() {
        // Two frames concatenated (as the PTY accumulates redraws). The
        // second frame (1 selected) must win.
        let twoFrames = """
        Select Installers to Remove , 0B, 0 selected
        \u{27A4} \u{25CB} a.dmg   1KB | Downloads
          \u{25CB} b.pkg   2KB | Downloads
        Select Installers to Remove , 1KB, 1 selected
          \u{25CB} a.dmg   1KB | Downloads
        \u{27A4} \u{25CF} b.pkg   2KB | Downloads
        """
        let screen = MoTUI.parse(twoFrames)
        XCTAssertEqual(screen.items.count, 2)
        XCTAssertEqual(MoTUI.selectedIndices(screen), [1])
        XCTAssertEqual(screen.cursor, 1)
        XCTAssertEqual(screen.selectedCount, 1)
    }

    func testKeystrokes_walkOnceTogglingWantedThenEnter() {
        // Select only index 1 of 3, then confirm. From a fresh list the
        // cursor is at 0, so: Down (→1), Space (toggle 1), Down (→2), Enter.
        let down: [UInt8] = [0x1b, 0x5b, 0x42]
        let expected = down + [0x20] + down + [0x0d]
        XCTAssertEqual(MoTUI.keystrokesToSelect([1], count: 3, confirm: true), expected)
    }

    func testKeystrokes_emptySelectionNeverConfirms() {
        // No items wanted → never press Enter (don't let Mole act on nothing).
        let keys = MoTUI.keystrokesToSelect([], count: 3, confirm: true)
        XCTAssertFalse(keys.contains(0x0d), "must not send Enter for an empty selection")
    }

    func testKeystrokes_selectAll() {
        let down: [UInt8] = [0x1b, 0x5b, 0x42]
        let space: [UInt8] = [0x20]
        let enter: [UInt8] = [0x0d]
        let expected = space + down + space + down + space + enter
        XCTAssertEqual(MoTUI.keystrokesToSelect([0, 1, 2], count: 3, confirm: true), expected)
    }

    // A real `mo purge` frame: rows are "<project path>  <size> | <category> | <age>",
    // the header carries "[1/53]" (53 total, but Mole renders far fewer).
    private let purgeFrame = """
    Select Categories to Clean [1/53], 0B, 0 selected
    \u{27A4} \u{25CB} ~/Desktop/Wisp                           2.67GB | .build            | 2d
      \u{25CF} ~/Desktop/the-ripples                    1.20GB | node_modules      | <1d
      \u{25CB} ~/Desktop/devport                        1.05GB | node_modules      | 2d
    \u{2191}\u{2193} | Space Select | Enter Confirm | A All | I Invert | Q Quit
    """

    func testParse_handlesPurgeRowShape() {
        let screen = MoTUI.parse(purgeFrame)
        XCTAssertEqual(screen.items.count, 3)
        XCTAssertEqual(screen.items.map { $0.name },
                       ["~/Desktop/Wisp", "~/Desktop/the-ripples", "~/Desktop/devport"])
        XCTAssertEqual(screen.items[0].size, "2.67GB")
        XCTAssertEqual(screen.items[0].location, ".build", "the category between the first pair of pipes")
        XCTAssertEqual(MoTUI.selectedIndices(screen), [1])
        XCTAssertEqual(screen.cursor, 0)
    }

    func testTotalCount_readsHeaderBracket() {
        XCTAssertEqual(MoTUI.totalCount(purgeFrame), 53, "the M in [n/M]")
        XCTAssertNil(MoTUI.totalCount(frame), "installer frame has no [n/M] header")
    }

    func testMergeItems_stitchesOverlappingScrolledFrames() {
        // Two overlapping viewports as the list scrolls down by one row: the
        // first shows rows 0–2, the second rows 1–3. Merged in order, only the
        // genuinely-new row 3 is appended.
        let a = MoTUI.parse(purgeFrame).items
        let scrolled = """
        Select Categories to Clean [2/53], 0B, 0 selected
          \u{25CB} ~/Desktop/the-ripples                    1.20GB | node_modules      | <1d
          \u{25CB} ~/Desktop/devport                        1.05GB | node_modules      | 2d
        \u{27A4} \u{25CB} ~/Desktop/newproj                        900MB | .build            | 3d
        \u{2191}\u{2193} | Space Select | Enter Confirm | A All | I Invert | Q Quit
        """
        let b = MoTUI.parse(scrolled).items
        let merged = MoTUI.mergeItems(a, b)
        XCTAssertEqual(merged.map { $0.name },
                       ["~/Desktop/Wisp", "~/Desktop/the-ripples", "~/Desktop/devport", "~/Desktop/newproj"])
    }

    func testMergeItems_dedupesByFullIdentityNotJustName() {
        // Same basename, different size/location → two distinct rows, both kept.
        let one = [MoTUIItem(name: "receipts", size: "10MB", location: "node_modules", selected: false)]
        let two = [MoTUIItem(name: "receipts", size: "20MB", location: ".venv", selected: false),
                   MoTUIItem(name: "receipts", size: "10MB", location: "node_modules", selected: false)]
        let merged = MoTUI.mergeItems(one, two)
        XCTAssertEqual(merged.count, 2, "the 20MB/.venv 'receipts' is a different row; the duplicate is dropped")
    }

    // Mole's SECOND (final) confirm screen, captured from a real `mo purge`.
    private let confirmScreen = """
    Selected paths:
      ~/Desktop/Wisp/.build
    \u{27A4} Remove 1 artifact, 2.67GB  Enter confirm, ESC cancel:
    """

    func testRemovalCount_parsesFinalConfirm() {
        XCTAssertEqual(MoTUI.removalCount(confirmScreen), 1)
        XCTAssertEqual(MoTUI.removalCount("➤ Remove 12 artifacts, 4.1GB  Enter confirm, ESC cancel:"), 12)
        XCTAssertNil(MoTUI.removalCount(frame), "the selection list is not a final-confirm screen")
    }

    // Regression: `mo installer` confirms with "Delete N installers", not
    // "Remove N". Matching only "Remove" meant the count never parsed and the
    // installer flow always failed with "didn't reach its confirm screen in time".
    func testRemovalCount_parsesInstallerDeleteWording() {
        XCTAssertEqual(MoTUI.removalCount("➤ Delete 1 installers, 771KB  Enter confirm, ESC cancel:"), 1)
        XCTAssertEqual(MoTUI.removalCount("➤ Delete 23 installers, 4.1GB  Enter confirm, ESC cancel:"), 23)
        // The installer SELECTION header also contains the word "Remove" ("Select
        // Installers to Remove …") but no count after it — must stay nil.
        XCTAssertNil(MoTUI.removalCount("Select Installers to Remove , 1.26GB, 2 selected"))
    }
}
