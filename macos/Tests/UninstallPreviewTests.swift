//
//  UninstallPreviewTests.swift
//  BurrowTests
//
//  `mo uninstall --dry-run <app>` enumerates every path the engine
//  would remove. The expandable leftover review (design 2.2) parses
//  that enumeration and classifies each path by shape: Application /
//  App Support / Preferences / containers / helpers / login items are
//  auto-selected; caches, logs, group containers and anything ambiguous
//  land in "Needs review", unchecked. Fixture captured from mole 1.41
//  (2026-06-11); parsing fails soft to the classic whole-app flow.
//

import XCTest
@testable import Burrow

final class UninstallPreviewTests: XCTestCase {
    /// Real transcript shape (ANSI stripped), Maccy on this machine.
    static let fixture = """
    → DRY RUN MODE, No app files or settings will be modified

    ◎ Matched 1 app(s):
    1. Maccy  7.4MB  |  Last: 6d ago

    Proceed with uninstallation? [y/N]\u{0020}
    Files to be removed:

    ◎ Maccy , 239.6MB
      ✓ /Applications/Maccy.app
      ✓ ~/Library/Containers/org.p0deje.Maccy
      ✓ ~/Library/Application Scripts/org.p0deje.Maccy
      ✓ ~/Library/Preferences/org.p0deje.Maccy.plist
      ✓ ~/Library/Caches/org.p0deje.Maccy

    ➤ Remove 1 app, 239.6MB [Running]  Enter confirm, ESC cancel:\u{0020}

    ======================================================================
    Uninstall dry run complete
    Would remove 1 app, would free 239.6MB: Maccy
    ======================================================================
    """

    func testParse_readsAppTotalAndPaths() {
        let preview = UninstallPreview.parse(Self.fixture.components(separatedBy: "\n"))
        XCTAssertEqual(preview.appName, "Maccy")
        XCTAssertEqual(preview.totalText, "239.6MB")
        XCTAssertEqual(preview.entries.count, 5)
        XCTAssertEqual(preview.entries.first?.path, "/Applications/Maccy.app")
    }

    func testParse_garbageFailsSoftToEmpty() {
        let preview = UninstallPreview.parse(["no enumeration here"])
        XCTAssertTrue(preview.entries.isEmpty)
        XCTAssertNil(preview.appName)
    }

    func testClassify_byPathShape() {
        XCTAssertEqual(UninstallPreview.classify("/Applications/Maccy.app"), .application)
        XCTAssertEqual(UninstallPreview.classify("~/Library/Application Support/Maccy"), .appSupport)
        XCTAssertEqual(UninstallPreview.classify("~/Library/Preferences/org.p0deje.Maccy.plist"), .preferences)
        XCTAssertEqual(UninstallPreview.classify("~/Library/Containers/org.p0deje.Maccy"), .container)
        XCTAssertEqual(UninstallPreview.classify("~/Library/Group Containers/group.com.x"), .groupContainer)
        XCTAssertEqual(UninstallPreview.classify("~/Library/Application Scripts/org.p0deje.Maccy"), .helper)
        XCTAssertEqual(UninstallPreview.classify("~/Library/LaunchAgents/com.x.plist"), .loginItem)
        XCTAssertEqual(UninstallPreview.classify("~/Library/Caches/org.p0deje.Maccy"), .cache)
        XCTAssertEqual(UninstallPreview.classify("/private/var/folders/ab/x/T/com.x"), .cache)
        XCTAssertEqual(UninstallPreview.classify("~/Library/Logs/Maccy"), .log)
        XCTAssertEqual(UninstallPreview.classify("/opt/weird/location"), .other)
    }

    /// Auto vs Needs review: removal essentials auto-tick; caches, logs,
    /// group containers and unknowns wait for a human.
    func testAutoSelection_split() {
        let auto: [UninstallPreview.Kind] = [.application, .appSupport, .preferences,
                                             .container, .helper, .loginItem]
        let review: [UninstallPreview.Kind] = [.cache, .log, .groupContainer, .other]
        for kind in auto { XCTAssertTrue(kind.autoSelected, "\(kind) should auto-select") }
        for kind in review { XCTAssertFalse(kind.autoSelected, "\(kind) should need review") }
    }

    func testParse_assignsKindsToEntries() {
        let preview = UninstallPreview.parse(Self.fixture.components(separatedBy: "\n"))
        XCTAssertEqual(preview.entries.map(\.kind),
                       [.application, .container, .helper, .preferences, .cache])
        let auto = preview.entries.filter(\.kind.autoSelected)
        XCTAssertEqual(auto.count, 4, "the cache row needs review")
    }
}

/// `UninstallPreview.fromEngineEnvelope` — the JSON side of the per-app leftover preview fix
/// (the bundled engine never emits the ANSI text `parse(_:)` above understands; it only ever
/// speaks its JSON envelope). Primary fixture captured VERBATIM from
/// `burrow-engine uninstall --dry-run com.tinyspeck.slackmacgap` (0.1.0) against a real Slack
/// install on this machine.
final class UninstallPreviewEngineEnvelopeTests: XCTestCase {
    private static let realEnvelope = #"{"ok":true,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"uninstall","data":{"dry_run":true,"bundle_id":"com.tinyspeck.slackmacgap","total_bytes":803812,"total_human":"804KB","items":[{"path":"/Users/henry/Library/Caches/com.tinyspeck.slackmacgap","label":"Cache","size":683472,"size_human":"683KB"},{"path":"/Users/henry/Library/Preferences/com.tinyspeck.slackmacgap.plist","label":"Preferences","size":1044,"size_human":"1KB"},{"path":"/Users/henry/Library/HTTPStorages/com.tinyspeck.slackmacgap","label":"HTTP storage","size":119296,"size_human":"119KB"}]}}"#

    func testFromEngineEnvelope_realCapture_readsAllEntriesAndTotal() throws {
        let preview = try XCTUnwrap(UninstallPreview.fromEngineEnvelope(Self.realEnvelope))
        XCTAssertEqual(preview.totalText, "804KB")
        XCTAssertEqual(preview.entries.map(\.path), [
            "/Users/henry/Library/Caches/com.tinyspeck.slackmacgap",
            "/Users/henry/Library/Preferences/com.tinyspeck.slackmacgap.plist",
            "/Users/henry/Library/HTTPStorages/com.tinyspeck.slackmacgap",
        ])
    }

    /// `classify(_:)` is shared with the ANSI-text parser above, so a JSON-derived entry sorts
    /// into Auto-selected / Needs-review exactly as a text-derived one would — HTTPStorages
    /// matches none of `classify`'s specific branches and falls to `.other` (needs review, same
    /// as an unrecognized path from the legacy parser).
    func testFromEngineEnvelope_classifiesEntriesByPathShape() throws {
        let preview = try XCTUnwrap(UninstallPreview.fromEngineEnvelope(Self.realEnvelope))
        XCTAssertEqual(preview.entries.map(\.kind), [.cache, .preferences, .other])
    }

    func testFromEngineEnvelope_errorEnvelope_yieldsEmptyNotNil() {
        let error = #"{"ok":false,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"uninstall","error":{"kind":"error","message":"boom","platform":"macos"}}"#
        let preview = UninstallPreview.fromEngineEnvelope(error)
        XCTAssertNotNil(preview, "an error envelope IS a recognized shape — empty, not nil")
        XCTAssertTrue(preview?.isEmpty ?? false)
    }

    func testFromEngineEnvelope_malformedData_yieldsEmptyNotNil() {
        let malformed = #"{"ok":true,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"uninstall","data":{"dry_run":true}}"#
        let preview = UninstallPreview.fromEngineEnvelope(malformed)
        XCTAssertNotNil(preview)
        XCTAssertTrue(preview?.isEmpty ?? false)
    }

    func testFromEngineEnvelope_notEnvelopeShaped_returnsNilSoCallerFallsBackToLegacyParser() {
        XCTAssertNil(UninstallPreview.fromEngineEnvelope("garbage, not json"))
        XCTAssertNil(UninstallPreview.fromEngineEnvelope(""))
        // Bare JSON with no envelope marker field (`burrow_cli`) must not be mistaken for a real
        // envelope just because it happens to parse as a JSON object.
        XCTAssertNil(UninstallPreview.fromEngineEnvelope(#"{"items":[{"path":"/x"}]}"#))
    }
}
