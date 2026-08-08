//
//  DiskScannerTests.swift
//  BurrowTests
//
//  The old-mole classifier behind #35: a pre-1.29 `mo` has no
//  `analyze --json`, so from a GUI parent it either rejects the flag or
//  launches its TUI and dies opening /dev/tty. Burrow must turn both
//  stderr shapes into the actionable "upgrade mole" error instead of
//  surfacing the raw TTY message.
//

import XCTest
@testable import Burrow

final class DiskScannerTests: XCTestCase {
    func testClassifier_matchesDevTTYFailure() {
        // Verbatim stderr from the #35 report.
        let stderr = "analyzer error: could not open a new TTY: open /dev/tty: device not configured"
        XCTAssertTrue(DiskScanner.indicatesMissingJSONSupport(stderr: stderr))
    }

    func testClassifier_matchesUnknownFlagFailure() {
        // Go's flag package, for vintages that reject rather than ignore.
        let stderr = "flag provided but not defined: -json\nUsage of analyze:"
        XCTAssertTrue(DiskScanner.indicatesMissingJSONSupport(stderr: stderr))
    }

    func testClassifier_ignoresOrdinaryFailures() {
        XCTAssertFalse(DiskScanner.indicatesMissingJSONSupport(stderr: "permission denied"))
        XCTAssertFalse(DiskScanner.indicatesMissingJSONSupport(stderr: ""))
    }

    func testTooOldError_namesFloorAndFix() throws {
        let msg = try XCTUnwrap(DiskScanError.moTooOld(
            found: "1.28.1",
            updatePolicy: .external
        ).errorDescription)
        XCTAssertTrue(msg.contains(MoleCLI.minimumAnalyzeJSONVersion))
        XCTAssertTrue(msg.contains("1.28.1"))
        XCTAssertTrue(msg.contains("Update external engine"))
    }

    func testTooOldError_readableWithUnknownVersion() throws {
        let msg = try XCTUnwrap(DiskScanError.moTooOld(
            found: nil,
            updatePolicy: .bundledWithApp
        ).errorDescription)
        XCTAssertTrue(msg.contains(MoleCLI.minimumAnalyzeJSONVersion))
        XCTAssertFalse(msg.contains("%@"), "format placeholders must be resolved")
    }
}
