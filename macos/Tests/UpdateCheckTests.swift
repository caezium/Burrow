//
//  UpdateCheckTests.swift
//  BurrowTests
//
//  Version comparison remains shared by the Updates inventory for apps that
//  publish version strings. Burrow's own updates are selected and verified by
//  Sparkle, whose native updater replaces the old GitHub/Homebrew path.
//

import XCTest
@testable import Burrow

final class UpdateCheckTests: XCTestCase {
    func testIsNewer_numericPerComponent() {
        XCTAssertTrue(UpdateCheck.isNewer("0.7.0", than: "0.6.7"))
        XCTAssertTrue(UpdateCheck.isNewer("0.6.10", than: "0.6.9"))
        XCTAssertFalse(UpdateCheck.isNewer("0.6.7", than: "0.6.7"))
        XCTAssertFalse(UpdateCheck.isNewer("0.6.7", than: "0.7.0"))
        XCTAssertTrue(UpdateCheck.isNewer("1.0", than: "0.9.9"))   // shorter remote
        XCTAssertTrue(UpdateCheck.isNewer("0.6.7.1", than: "0.6.7")) // greenlight:ignore hardcoded-ipv4 — version fixture
    }

    func testIsNewer_toleratesLeadingV() {
        XCTAssertTrue(UpdateCheck.isNewer("v0.7.0", than: "0.6.7"))
        XCTAssertFalse(UpdateCheck.isNewer("v0.6.7", than: "v0.6.7"))
    }

    func testAutomaticCheckToggleStartsUpdaterOnlyWhenEnabled() {
        XCTAssertFalse(UpdateStartPolicy.shouldStartForAutomaticChecks(enabled: false))
        XCTAssertTrue(UpdateStartPolicy.shouldStartForAutomaticChecks(enabled: true))
    }

}
