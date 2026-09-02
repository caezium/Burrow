//
//  LocationAccessTests.swift
//  BurrowTests
//
//  The pure status → action mapping behind the nearby-Wi-Fi scan (#416). The
//  prompt itself is a TCC dialog and can't run in CI — hand-test it.
//

import XCTest
import CoreLocation
@testable import Burrow

final class LocationAccessTests: XCTestCase {
    func testAuthorizedStatusScans() {
        // macOS grants are always-tier; there is no when-in-use case here.
        XCTAssertEqual(LocationAccess.verdict(for: .authorizedAlways), .ready)
    }

    func testUndecidedStatusAsksFirst() {
        // The whole bug: scanning without asking never produces the prompt.
        XCTAssertEqual(LocationAccess.verdict(for: .notDetermined), .ask)
    }

    func testRefusedStatusesExplainInsteadOfScanning() {
        XCTAssertEqual(LocationAccess.verdict(for: .denied), .denied)
        XCTAssertEqual(LocationAccess.verdict(for: .restricted), .denied)
    }

    func testSettingsLinkTargetsLocationServicesPane() {
        XCTAssertEqual(LocationAccess.settingsURL.scheme, "x-apple.systempreferences")
        XCTAssertTrue(LocationAccess.settingsURL.absoluteString.hasSuffix("Privacy_LocationServices"))
    }
}
