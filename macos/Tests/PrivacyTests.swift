//
//  PrivacyTests.swift
//  BurrowTests
//
//  The permission-flood fix (issue #3) hinges on one decision: should
//  Burrow surface the Full Disk Access notice before a scan that walks
//  TCC-protected directories? The probe for whether we *have* access is
//  environment-dependent and not unit-testable, so the decision is split
//  into a pure function that these tests pin down.
//

import XCTest
@testable import Burrow

final class PrivacyTests: XCTestCase {
    // The rule: only nag when access is missing AND the user hasn't
    // already dismissed the notice. Granting access or dismissing both
    // silence it — we never want to flood the user with our own banner
    // any more than with the OS prompts.
    func testOffersAccessOnlyWhenMissingAndNotDismissed() {
        XCTAssertTrue(Privacy.shouldOfferFullDiskAccess(hasAccess: false, dismissed: false))
        XCTAssertFalse(Privacy.shouldOfferFullDiskAccess(hasAccess: true, dismissed: false),
                       "no notice when we already have access")
        XCTAssertFalse(Privacy.shouldOfferFullDiskAccess(hasAccess: false, dismissed: true),
                       "respect a prior dismissal")
        XCTAssertFalse(Privacy.shouldOfferFullDiskAccess(hasAccess: true, dismissed: true))
    }

    // The errno mapping is the part most likely to need revisiting on a
    // future macOS, so pin what each class of failure means. A refusal is
    // evidence the grant is missing; a missing file is evidence of nothing.
    func testClassifiesProbeOutcomesFromErrno() {
        XCTAssertEqual(Privacy.classify(openSucceeded: true, errnoValue: 0), .granted)
        XCTAssertEqual(Privacy.classify(openSucceeded: false, errnoValue: EPERM), .denied)
        XCTAssertEqual(Privacy.classify(openSucceeded: false, errnoValue: EACCES), .denied)
        XCTAssertEqual(Privacy.classify(openSucceeded: false, errnoValue: ENOENT), .unavailable)
        XCTAssertEqual(Privacy.classify(openSucceeded: false, errnoValue: ENOTDIR), .unavailable)
        XCTAssertEqual(Privacy.classify(openSucceeded: false, errnoValue: EIO), .inconclusive)
    }

    private static let probes = [
        Privacy.Probe(id: "user_tcc_db", path: "/user", authoritative: true),
        Privacy.Probe(id: "safari_bookmarks", path: "/safari", authoritative: false),
    ]

    func testAnyGrantedProbeMeansAccess() {
        let d = Privacy.summarize(["user_tcc_db": .denied, "safari_bookmarks": .granted],
                                  probes: Self.probes)
        XCTAssertTrue(d.hasAccess, "one open is enough — the grant is live")
        XCTAssertTrue(d.conclusive)
    }

    func testAuthoritativeRefusalIsConclusiveOff() {
        let d = Privacy.summarize(["user_tcc_db": .denied, "safari_bookmarks": .unavailable],
                                  probes: Self.probes)
        XCTAssertFalse(d.hasAccess)
        XCTAssertTrue(d.conclusive, "TCC.db exists and was refused — access really is off")
    }

    // The #177/#181/#319 regression: every probe location absent used to be
    // reported as "off", sending users round the grant/relaunch loop forever.
    func testMissingProbeLocationsAreNotReportedAsDenied() {
        let d = Privacy.summarize(["user_tcc_db": .unavailable, "safari_bookmarks": .unavailable],
                                  probes: Self.probes)
        XCTAssertFalse(d.hasAccess)
        XCTAssertFalse(d.conclusive, "nothing was refused, so Burrow has learned nothing")
    }

    // A non-authoritative refusal can mean a different TCC service, not FDA.
    func testNonAuthoritativeRefusalAloneIsInconclusive() {
        let d = Privacy.summarize(["user_tcc_db": .unavailable, "safari_bookmarks": .denied],
                                  probes: Self.probes)
        XCTAssertFalse(d.hasAccess)
        XCTAssertFalse(d.conclusive)
    }

    // The real probe set must keep at least one location that exists on every
    // Mac, or the diagnosis can never be conclusive in the field.
    func testShippedProbeSetHasAuthoritativeLocations() {
        XCTAssertTrue(Privacy.fullDiskAccessProbes.contains { $0.authoritative },
                      "at least one always-present, FDA-gated probe is required")
        XCTAssertEqual(Set(Privacy.fullDiskAccessProbes.map(\.id)).count,
                       Privacy.fullDiskAccessProbes.count,
                       "probe ids key the outcome map, so they must be unique")
    }
}
