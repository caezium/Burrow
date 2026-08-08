//
//  TuneUpTests.swift
//  BurrowTests
//
//  Tune-Up safe-set selection (roadmap F / #77).
//

import XCTest
@testable import Burrow

final class TuneUpTests: XCTestCase {
    private let recs: [TuneUp.Recommendation] = [
        .init(kind: .brewCleanup, title: "brew cleanup", bytes: 500_000_000),
        .init(kind: .freeCache, title: "clear caches", bytes: 1_000_000_000),
        .init(kind: .uninstallUnused, title: "remove OldApp", bytes: 2_000_000_000),
        .init(kind: .disableStartupItem, title: "disable Updater", bytes: 0),
    ]

    func testSafeSet_excludesDestructiveActions() {
        let safe = TuneUp.safeSet(recs).map(\.kind)
        XCTAssertEqual(Set(safe), [.brewCleanup, .freeCache])
        XCTAssertFalse(safe.contains(.uninstallUnused), "uninstall is review-only")
        XCTAssertFalse(safe.contains(.disableStartupItem), "startup changes are review-only")
    }

    func testReviewSet_isTheDestructiveRemainder() {
        XCTAssertEqual(Set(TuneUp.reviewSet(recs).map(\.kind)), [.uninstallUnused, .disableStartupItem])
    }

    func testReclaimable_sumsAllBytes() {
        XCTAssertEqual(TuneUp.reclaimable(recs), 3_500_000_000)
    }

    func testConfirmationCopyMatchesPermanentCleanupAndRequiresSeparateConsent() {
        let policy = TuneUp.ConfirmationPolicy(includesClean: true)
        XCTAssertTrue(policy.notice.contains("permanently deletes"))
        XCTAssertTrue(policy.notice.contains("do not go to the Trash"))
        XCTAssertTrue(policy.notice.contains("cannot be recovered"))
        XCTAssertFalse(policy.permitsRun(irreversibleConsent: false))
        XCTAssertTrue(policy.permitsRun(irreversibleConsent: true))
    }

    func testMaintenanceOnlyDoesNotRequireIrreversibleConsent() {
        let policy = TuneUp.ConfirmationPolicy(includesClean: false)
        XCTAssertFalse(policy.requiresIrreversibleConsent)
        XCTAssertTrue(policy.permitsRun(irreversibleConsent: false))
    }
}
