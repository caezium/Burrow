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

    // MARK: - `items[]` is scope, not permission
    //
    // Since burrow-engine @ df9ea3f the `.app` is `items[0]`, emitted on `bundle.present` ALONE
    // with no refusal check (`bundle.rs:584-591`) — deliberately, so a preview can show that the
    // application is in scope even when it will not come away. The verdict is one field over, in
    // `apps[].application`, which this parser used to drop. Both fixtures below are verbatim real
    // captures from the bundled binary.

    /// `uninstall --dry-run` over a scratch bundle whose path a protection rail declines: `ok:true`,
    /// the `.app` present in `items[]`, and `application.refusal` set. Captured against a scratch
    /// bundle under a temporary `$HOME` — no installed application was involved.
    private static let refusedBundle = #"{"ok":true,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"uninstall","data":{"dry_run":true,"total_bytes":11,"total_human":"11B","items":[{"path":"/private/tmp/claude-501/-Users-henry-Desktop-Burrow/447eac01-68b0-4709-9b47-4353173bbf3b/scratchpad/fh/Applications/BurrowScratchControlCenter.app","label":"Application","size":404,"size_human":"404B","bundle_id":"dev.caezium.burrow.scratch.refused","kind":"application"},{"path":"/private/tmp/claude-501/-Users-henry-Desktop-Burrow/447eac01-68b0-4709-9b47-4353173bbf3b/scratchpad/fh/Library/Application Support/dev.caezium.burrow.scratch.refused","label":"Application support","size":5,"size_human":"5B","bundle_id":"dev.caezium.burrow.scratch.refused","kind":"leftover"},{"path":"/private/tmp/claude-501/-Users-henry-Desktop-Burrow/447eac01-68b0-4709-9b47-4353173bbf3b/scratchpad/fh/Library/Caches/dev.caezium.burrow.scratch.refused","label":"Cache","size":6,"size_human":"6B","bundle_id":"dev.caezium.burrow.scratch.refused","kind":"leftover"}],"apps":[{"query":"dev.caezium.burrow.scratch.refused","name":"BurrowScratchControlCenter","bundle_id":"dev.caezium.burrow.scratch.refused","path":"/private/tmp/claude-501/-Users-henry-Desktop-Burrow/447eac01-68b0-4709-9b47-4353173bbf3b/scratchpad/fh/Applications/BurrowScratchControlCenter.app","item_count":2,"leftover_bytes":11,"total_bytes":11,"total_human":"11B","application":{"path":"/private/tmp/claude-501/-Users-henry-Desktop-Burrow/447eac01-68b0-4709-9b47-4353173bbf3b/scratchpad/fh/Applications/BurrowScratchControlCenter.app","present":true,"size":404,"size_human":"404B","needs_admin":false,"action":"delete","cask":null,"refusal":"protected path skipped: /private/tmp/claude-501/-Users-henry-Desktop-Burrow/447eac01-68b0-4709-9b47-4353173bbf3b/scratchpad/fh/Applications/BurrowScratchControlCenter.app"}}],"unmatched":[],"matched_count":1,"requires_confirmation":false,"ambiguous":[],"removes_applications":0,"requires_admin":false,"external_commands":[],"warnings":[]}}"#

    /// `uninstall --dry-run eu.exelban.Stats` — a real Homebrew cask on this machine. The `.app` is
    /// in `items[]` and `action` is `brew_zap`: the engine's rule for it is
    /// `brew uninstall --cask --zap` or nothing at all.
    private static let brewCask = #"{"ok":true,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"uninstall","data":{"dry_run":true,"total_bytes":57386539,"total_human":"57.4MB","items":[{"path":"/Applications/Stats.app","label":"Application","size":56047466,"size_human":"56.0MB","bundle_id":"eu.exelban.Stats","kind":"application"},{"path":"/Users/henry/Library/Caches/eu.exelban.Stats","label":"Cache","size":320920,"size_human":"321KB","bundle_id":"eu.exelban.Stats","kind":"leftover"},{"path":"/Users/henry/Library/Preferences/eu.exelban.Stats.plist","label":"Preferences","size":2281,"size_human":"2KB","bundle_id":"eu.exelban.Stats","kind":"leftover"},{"path":"/Users/henry/Library/HTTPStorages/eu.exelban.Stats","label":"HTTP storage","size":729056,"size_human":"729KB","bundle_id":"eu.exelban.Stats","kind":"leftover"},{"path":"/Users/henry/Library/WebKit/eu.exelban.Stats","label":"WebKit data","size":286816,"size_human":"287KB","bundle_id":"eu.exelban.Stats","kind":"leftover"}],"apps":[{"query":"eu.exelban.Stats","name":"Stats","bundle_id":"eu.exelban.Stats","path":"/Applications/Stats.app","item_count":4,"leftover_bytes":1339073,"total_bytes":57386539,"total_human":"57.4MB","application":{"path":"/Applications/Stats.app","present":true,"size":56047466,"size_human":"56.0MB","needs_admin":false,"action":"brew_zap","cask":"stats","refusal":null}}],"unmatched":[],"matched_count":1,"requires_confirmation":false,"ambiguous":[],"removes_applications":1,"requires_admin":false,"external_commands":[{"bundle_id":"eu.exelban.Stats","name":"Stats","command":"brew uninstall --cask --zap stats","note":"Homebrew removes this app; --zap also deletes configuration and data the cask declares, which are not enumerated above."}],"warnings":[]}}"#

    /// Paths are READ OUT OF THE FIXTURE rather than retyped beside it, so a re-capture on another
    /// machine (different `$HOME`, different scratch directory) moves the assertions with it
    /// instead of quietly asserting about a path the capture no longer contains.
    private func bundlePath(in fixture: String) throws -> String {
        let data = try XCTUnwrap(BurrowEnvelope.inOutput(fixture)?.data)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(UninstallGuard.decodePlan(payload).apps.first?.application.path)
    }

    /// The `.app` must still be LISTED — hiding it would be the opposite lie, authorising a
    /// removal the user was never shown — but it must not be tickable, and it must not be in the
    /// default selection, which `Kind.application.autoSelected` alone would have put it in.
    func testFromEngineEnvelope_aRefusedBundleIsListedButNotRemovableByHand() throws {
        let preview = try XCTUnwrap(UninstallPreview.fromEngineEnvelope(Self.refusedBundle))
        let bundle = try bundlePath(in: Self.refusedBundle)
        XCTAssertTrue(bundle.hasSuffix(".app"), bundle)
        XCTAssertTrue(preview.entries.contains { $0.path == bundle && $0.kind == .application },
                      "the bundle stays visible — it IS in scope for the run")
        XCTAssertTrue(UninstallPreview.Kind.application.autoSelected,
                      "and its kind still auto-selects, which is exactly why the refusal has to win")
        XCTAssertEqual(preview.handRemovalRefusals[bundle], "protected path skipped: \(bundle)")
        XCTAssertFalse(preview.defaultTicked.contains(bundle))
        XCTAssertEqual(preview.refusedAmong([bundle]).map(\.path), [bundle],
                       "and if it is ticked anyway, the hand-trash rail sees it")
        let leftovers = preview.entries.filter { $0.kind != .application }.map(\.path)
        XCTAssertFalse(leftovers.isEmpty)
        XCTAssertTrue(preview.refusedAmong(Set(leftovers)).isEmpty,
                      "ordinary leftovers are unaffected — this rail is about the bundle")
    }

    /// Trashing a cask's `.app` directly leaves Homebrew's Caskroom believing it is installed, so
    /// it is refused by hand for a different reason and the message says which.
    func testFromEngineEnvelope_aHomebrewCasksBundleIsNotBurrowsToTrash() throws {
        let preview = try XCTUnwrap(UninstallPreview.fromEngineEnvelope(Self.brewCask))
        let bundle = try bundlePath(in: Self.brewCask)
        let reason = try XCTUnwrap(preview.handRemovalRefusals[bundle])
        XCTAssertTrue(reason.contains("brew uninstall --cask --zap stats"), reason)
        XCTAssertFalse(preview.defaultTicked.contains(bundle))
    }

    /// An ordinary app is untouched by any of this — the rail only fires on the engine's own
    /// verdict, so a normal removal still ticks its bundle by default.
    func testFromEngineEnvelope_anOrdinaryBundleIsStillTickedByDefault() throws {
        let plain = Self.brewCask
            .replacingOccurrences(of: #""action":"brew_zap","cask":"stats""#,
                                  with: #""action":"delete","cask":null"#)
        let preview = try XCTUnwrap(UninstallPreview.fromEngineEnvelope(plain))
        XCTAssertTrue(preview.handRemovalRefusals.isEmpty)
        XCTAssertTrue(preview.defaultTicked.contains(try bundlePath(in: plain)))
    }
}
