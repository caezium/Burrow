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

/// `TuneUpModel.scanCleanable`/`scanOptimize` used to hand `res.stdout` to `parseTaskReport`,
/// a text-marker parser built for legacy mo/streamed output. Post-repoint, `res.stdout` is the
/// engine's one-line JSON envelope — there is no human-text mode at all — so that parse always
/// matched nothing and the Tune-Up dashboard silently reported "nothing to clean" / "nothing to
/// optimize" on every real machine. These fixtures are captured VERBATIM from
/// `burrow-engine clean --dry-run` / `burrow-engine optimize --dry-run` (0.1.0) rather than
/// hand-typed, so a regression back to text-parsing (or any other envelope-shape drift) shows up
/// against real engine output, not a guess at its shape.
final class TuneUpModelEnvelopeParsingTests: XCTestCase {
    // `burrow-engine clean --dry-run`, captured verbatim.
    private let cleanEnvelope = #"{"ok":true,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"clean","data":{"dry_run":true,"total_bytes":12291106881,"total_human":"12.29GB","items":[{"path":"/Users/henry/Library/Caches","label":"User caches","size":2948714768,"size_human":"2.95GB"},{"path":"/Users/henry/Library/Logs","label":"User logs","size":9354316,"size_human":"9.4MB"},{"path":"/Users/henry/Library/Application Support/CrashReporter","label":"Crash reports","size":178127,"size_human":"178KB"},{"path":"/Users/henry/Library/Saved Application State","label":"Saved application state","size":0,"size_human":"0B"},{"path":"/Users/henry/.cache","label":"Unix cache","size":9332859670,"size_human":"9.33GB"}],"text":"Clean Your Mac\n\nDry Run Mode, Preview only, no deletions\n\n➤ Cleanup\n  → User caches, 2.95GB dry\n  → User logs, 9.4MB dry\n  → Crash reports, 178KB dry\n  → Saved application state, 0B dry\n  → Unix cache, 9.33GB dry\n\n======================================================================\nDry run complete - no changes made\nPotential space: 12.29GB | Items: 5 | Categories: 5\nUse mo clean --whitelist to add protection rules\n======================================================================"}}"#

    // `burrow-engine optimize --dry-run`, captured verbatim.
    private let optimizeEnvelope = #"{"ok":true,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"optimize","data":{"dry_run":true,"tasks":[{"name":"flush_dns","description":"Flush the DNS resolver cache"},{"name":"restart_dock","description":"Restart the Dock"},{"name":"restart_finder","description":"Restart Finder"},{"name":"rebuild_launch_services","description":"Rebuild the Launch Services database (fixes duplicate/stale 'Open With' entries)"}],"text":"Optimize\nDRY RUN MODE, No files will be modified\n\n➤ Maintenance Tasks\n  → Flush the DNS resolver cache\n  → Restart the Dock\n  → Restart Finder\n  → Rebuild the Launch Services database (fixes duplicate/stale 'Open With' entries)\n\n======================================================================\nDry Run Complete, No Changes Made\nWould apply 4 optimizations\nRun without --dry-run to apply these changes\n======================================================================"}}"#

    // MARK: cleanableSpace

    func testCleanableSpace_readsTotalHumanFromRealEnvelope() {
        XCTAssertEqual(TuneUpModel.cleanableSpace(fromCaptureStdout: cleanEnvelope), "12.29GB")
    }

    func testCleanableSpace_emptyWhenTotalBytesIsZero() {
        let zero = #"{"ok":true,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"clean","data":{"dry_run":true,"total_bytes":0,"total_human":"0B","items":[]}}"#
        XCTAssertEqual(TuneUpModel.cleanableSpace(fromCaptureStdout: zero), "",
                       "zero bytes to clean must read as nothing to do, not \"0B\"")
    }

    func testCleanableSpace_emptyOnErrorEnvelope() {
        let error = #"{"ok":false,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"clean","error":{"kind":"error","message":"boom","platform":"macos"}}"#
        XCTAssertEqual(TuneUpModel.cleanableSpace(fromCaptureStdout: error), "")
    }

    func testCleanableSpace_emptyOnGarbage() {
        XCTAssertEqual(TuneUpModel.cleanableSpace(fromCaptureStdout: "not json at all"), "")
        XCTAssertEqual(TuneUpModel.cleanableSpace(fromCaptureStdout: ""), "")
    }

    // Guards against the exact pre-fix bug: the one-line JSON blob never starts with "➤", so no
    // groups form. Its embedded (escaped) "Potential space: …" text DOES make `line.contains`
    // match once inside `mergeSummaryFields` — but only after `|`-splitting the whole one-line
    // blob, which puts the "Potential space" key together with the JSON's opening brace instead
    // of its own value, so `space` never actually gets extracted (confirmed empirically: the
    // pre-fix `summary` here is `space: ""`, not nil — a half-parsed non-answer, not a clean
    // failure). Either way `cleanableSpace`'s "" is correct; this test pins WHY.
    func testCleanableSpace_rawEnvelopeIsNotLegacyMarkerText() {
        let (groups, summary) = parseTaskReport(cleanEnvelope.components(separatedBy: "\n"))
        XCTAssertTrue(groups.isEmpty, "sanity check: the marker parser must not form any groups from the envelope")
        XCTAssertEqual(summary?.space ?? "", "",
                       "sanity check: whatever the marker parser half-extracts, it must not be a usable space value")
    }

    // A capture that isn't envelope-shaped at all (the bundled engine is missing and `.mo`
    // resolved to a real legacy `mo`/MIT-fork binary instead) must still fall back to the
    // marker-based parser that binary's output actually matches — this is the one case
    // `parseTaskReport` still owns after Fix 1. Hand-authored, matching TaskReportTests' own
    // dry-run fixture shape (there's no legacy binary left to capture this from).
    func testCleanableSpace_fallsBackToMarkerTextWhenNotEnvelopeShaped() {
        let legacyText = [
            "➤ Developer tools",
            "  → npm cache, 191.8MB",
            "Potential space: 383.8MB | Items: 372 | Categories: 20",
        ].joined(separator: "\n")
        XCTAssertEqual(TuneUpModel.cleanableSpace(fromCaptureStdout: legacyText), "383.8MB")
    }

    // MARK: optimizeAreas

    func testOptimizeAreas_readsOneEntryPerTaskFromRealEnvelope() {
        let areas = TuneUpModel.optimizeAreas(fromCaptureStdout: optimizeEnvelope)
        XCTAssertEqual(areas, [
            "Flush the DNS resolver cache",
            "Restart the Dock",
            "Restart Finder",
            "Rebuild the Launch Services database (fixes duplicate/stale 'Open With' entries)",
        ])
    }

    func testOptimizeAreas_emptyOnErrorEnvelope() {
        let error = #"{"ok":false,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"optimize","error":{"kind":"error","message":"boom","platform":"macos"}}"#
        XCTAssertEqual(TuneUpModel.optimizeAreas(fromCaptureStdout: error), [])
    }

    func testOptimizeAreas_emptyOnGarbage() {
        XCTAssertEqual(TuneUpModel.optimizeAreas(fromCaptureStdout: "not json at all"), [])
        XCTAssertEqual(TuneUpModel.optimizeAreas(fromCaptureStdout: ""), [])
    }

    // Same fallback as cleanableSpace: not envelope-shaped at all means a legacy binary
    // answered, so fall back to the marker parser rather than going blank. The legacy shape
    // groups items under one `➤` heading, so this (like the pre-fix behavior it preserves)
    // returns one string per GROUP, not per item.
    func testOptimizeAreas_fallsBackToMarkerTextWhenNotEnvelopeShaped() {
        let legacyText = [
            "➤ Maintenance Tasks",
            "  → Flush the DNS resolver cache",
            "  → Restart the Dock",
            "Potential space: 0B | Items: 2 | Categories: 1",
        ].joined(separator: "\n")
        XCTAssertEqual(TuneUpModel.optimizeAreas(fromCaptureStdout: legacyText), ["Maintenance Tasks"])
    }
}
