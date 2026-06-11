//
//  StoreTests.swift
//  BurrowTests
//
//  Verifies the Store wrapper clamps malformed values and falls back
//  to defaults when UserDefaults is empty. Run sequentially in a
//  scratch suite so cases can't pollute each other; the @testable
//  import reaches the otherwise-internal property surface.
//

import XCTest
@testable import Burrow

final class StoreTests: XCTestCase {
    static let scratchSuite = "dev.caezium.BurrowTests.scratch"

    override func setUp() {
        // The test bundle is hosted inside the real app, so
        // UserDefaults.standard is the developer's live Burrow domain.
        // Point Store at an empty scratch suite instead; tearDown removes
        // it and restores the real domain untouched.
        Store.d = UserDefaults(suiteName: Self.scratchSuite)!
        Store.d.removePersistentDomain(forName: Self.scratchSuite)
    }

    override func tearDown() {
        Store.d.removePersistentDomain(forName: Self.scratchSuite)
        Store.d = .standard
    }

    // Audit H6: a test run must never leak writes into the developer's
    // real preferences.
    func testWrites_doNotTouchStandardDefaults() {
        let key = "retention_days"
        let before = UserDefaults.standard.object(forKey: key) as? Int
        Store.retentionDays = 12_345
        XCTAssertEqual(Store.retentionDays, 12_345)
        let after = UserDefaults.standard.object(forKey: key) as? Int
        XCTAssertEqual(after, before, "Store writes leaked into UserDefaults.standard")
    }

    // The two defaults users and security reviewers care most about:
    // anonymous telemetry is opt-out (on until disabled), and agents may
    // NOT run destructive cleanups until a human flips the switch.
    func testTelemetryEnabled_defaultsTrue() {
        XCTAssertTrue(Store.telemetryEnabled)
    }

    func testMCPActions_defaultFalse() {
        XCTAssertFalse(Store.mcpActionsEnabled)
    }

    func testMCPIrreversible_defaultFalseAndPersists() {
        XCTAssertFalse(Store.mcpIrreversibleEnabled)
        Store.mcpIrreversibleEnabled = true
        XCTAssertTrue(Store.mcpIrreversibleEnabled)
    }

    // The first-launch consent notice must show exactly once: not yet
    // acknowledged on a fresh install, sticky once answered.
    func testTelemetryNotice_defaultsUnacknowledgedAndPersists() {
        XCTAssertFalse(Store.telemetryNoticeAcknowledged)
        Store.telemetryNoticeAcknowledged = true
        XCTAssertTrue(Store.telemetryNoticeAcknowledged)
    }

    // Issue #4: the menu-bar icon is on by default; the off-switch must
    // persist (it's read once at launch to decide menu-bar vs Dock mode).
    func testShowMenuBarIcon_defaultsTrueAndPersists() {
        XCTAssertTrue(Store.showMenuBarIcon)
        Store.showMenuBarIcon = false
        XCTAssertFalse(Store.showMenuBarIcon)
    }

    func testSampleInterval_defaultsTo60() {
        XCTAssertEqual(Store.sampleIntervalSeconds, 60)
    }

    func testSampleInterval_clampsLowAndHigh() {
        Store.sampleIntervalSeconds = 1
        XCTAssertEqual(Store.sampleIntervalSeconds, 5, "should clamp to floor of 5s")
        Store.sampleIntervalSeconds = 99_999
        XCTAssertEqual(Store.sampleIntervalSeconds, 3_600, "should clamp to ceiling of 1h")
    }

    func testRetention_defaultsTo30Days() {
        XCTAssertEqual(Store.retentionDays, 30)
    }

    func testRetention_clampsOnWrite() {
        // The setter clamps to ≥1 before hitting UserDefaults. That's
        // deliberate so a user can't poison the store with a 0 or
        // negative value through the Settings UI. The "unset = default"
        // path is a separate concern, exercised by
        // testRetention_defaultsTo30Days above (which runs after
        // setUp() clears the key).
        Store.retentionDays = 0
        XCTAssertEqual(Store.retentionDays, 1)
        Store.retentionDays = -5
        XCTAssertEqual(Store.retentionDays, 1)
        Store.retentionDays = 90
        XCTAssertEqual(Store.retentionDays, 90)
    }

    func testAutoVacuum_defaultsFalse() {
        XCTAssertFalse(Store.autoVacuum)
    }

    func testQueryServerEnabled_defaultsTrue() {
        XCTAssertTrue(Store.queryServerEnabled)
    }

    func testQueryServerPort_defaultsTo9277() {
        XCTAssertEqual(Store.queryServerPort, Int(QueryServer.defaultPort))
    }

    func testLastHistoryRangeMinutes_defaultsToOneHour() {
        XCTAssertEqual(Store.lastHistoryRangeMinutes, 60)
    }

    // The Full Disk Access notice (issue #3) must default to "not
    // dismissed" so first-run users see it, and stick once dismissed so
    // we don't nag.
    func testFullDiskAccessNoticeDismissed_defaultsFalseAndPersists() {
        XCTAssertFalse(Store.fullDiskAccessNoticeDismissed)
        Store.fullDiskAccessNoticeDismissed = true
        XCTAssertTrue(Store.fullDiskAccessNoticeDismissed)
    }

    func testRoundtripBoolAndInt() {
        Store.autoVacuum = true
        XCTAssertTrue(Store.autoVacuum)
        Store.queryServerPort = 9999
        XCTAssertEqual(Store.queryServerPort, 9999)
    }
}
