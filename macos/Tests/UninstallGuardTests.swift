//
//  UninstallGuardTests.swift
//  BurrowTests
//
//  The uninstall pre-flight is the safety interlock between the user's confirm sheet and the
//  resolved binary's own matching (audit H4). Now that `uninstall --apply` removes APPLICATIONS and
//  not merely their `~/Library` leftovers, what it interlocks is worth more, so these tests are
//  written against real captures rather than against a shape someone believed the engine had.
//
//  Every engine fixture below is the verbatim stdout of a real `burrow-engine` @ df9ea3f run,
//  captured 2026-08-08 and archived beside the recipe that produced it in
//  `plans/repoint-redo-groundtruth/engine-uninstall-*.golden.json` +
//  `engine-uninstall.golden.provenance.txt`. The applies were run against purpose-built scratch
//  bundles under `dev.caezium.*` that this session created and then removed — no installed
//  application was ever passed to `--apply`.
//

import XCTest
@testable import Burrow

final class UninstallGuardTests: XCTestCase {

    // MARK: - Engine captures (see the header for provenance)

    /// `uninstall --dry-run org.localsend.localsendApp` — a hand-deleted bundle.
    private let dryRunPlain = #"{"ok":true,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"uninstall","data":{"dry_run":true,"total_bytes":58727750,"total_human":"58.7MB","items":[{"path":"/Applications/LocalSend.app","label":"Application","size":58686554,"size_human":"58.7MB","bundle_id":"org.localsend.localsendApp","kind":"application"},{"path":"/Users/henry/Library/Containers/org.localsend.localsendApp","label":"Container","size":41196,"size_human":"41KB","bundle_id":"org.localsend.localsendApp","kind":"leftover"}],"apps":[{"query":"org.localsend.localsendApp","name":"LocalSend","bundle_id":"org.localsend.localsendApp","path":"/Applications/LocalSend.app","item_count":1,"leftover_bytes":41196,"total_bytes":58727750,"total_human":"58.7MB","application":{"path":"/Applications/LocalSend.app","present":true,"size":58686554,"size_human":"58.7MB","needs_admin":false,"action":"delete","cask":null,"refusal":null}}],"unmatched":[],"matched_count":1,"requires_confirmation":false,"ambiguous":[],"removes_applications":1,"requires_admin":false,"external_commands":[],"warnings":[]}}"#

    /// `uninstall --dry-run eu.exelban.Stats` — a Homebrew cask.
    private let dryRunBrew = #"{"ok":true,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"uninstall","data":{"dry_run":true,"total_bytes":57386539,"total_human":"57.4MB","items":[{"path":"/Applications/Stats.app","label":"Application","size":56047466,"size_human":"56.0MB","bundle_id":"eu.exelban.Stats","kind":"application"},{"path":"/Users/henry/Library/Caches/eu.exelban.Stats","label":"Cache","size":320920,"size_human":"321KB","bundle_id":"eu.exelban.Stats","kind":"leftover"},{"path":"/Users/henry/Library/Preferences/eu.exelban.Stats.plist","label":"Preferences","size":2281,"size_human":"2KB","bundle_id":"eu.exelban.Stats","kind":"leftover"},{"path":"/Users/henry/Library/HTTPStorages/eu.exelban.Stats","label":"HTTP storage","size":729056,"size_human":"729KB","bundle_id":"eu.exelban.Stats","kind":"leftover"},{"path":"/Users/henry/Library/WebKit/eu.exelban.Stats","label":"WebKit data","size":286816,"size_human":"287KB","bundle_id":"eu.exelban.Stats","kind":"leftover"}],"apps":[{"query":"eu.exelban.Stats","name":"Stats","bundle_id":"eu.exelban.Stats","path":"/Applications/Stats.app","item_count":4,"leftover_bytes":1339073,"total_bytes":57386539,"total_human":"57.4MB","application":{"path":"/Applications/Stats.app","present":true,"size":56047466,"size_human":"56.0MB","needs_admin":false,"action":"brew_zap","cask":"stats","refusal":null}}],"unmatched":[],"matched_count":1,"requires_confirmation":false,"ambiguous":[],"removes_applications":1,"requires_admin":false,"external_commands":[{"bundle_id":"eu.exelban.Stats","name":"Stats","command":"brew uninstall --cask --zap stats","note":"Homebrew removes this app; --zap also deletes configuration and data the cask declares, which are not enumerated above."}],"warnings":[]}}"#

    /// `uninstall --dry-run pdate` — one term, two apps, both called "Updater".
    private let dryRunAmbiguous = #"{"ok":true,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"uninstall","data":{"dry_run":true,"total_bytes":377374,"total_human":"377KB","items":[{"path":"/Users/henry/Applications/Trader Workstation/.install4j/Updater.app","label":"Application","size":188695,"size_human":"189KB","bundle_id":"com.install4j.5889-6375-8446-2021.443","kind":"application"},{"path":"/Users/henry/Applications/IBKR Desktop/.install4j/Updater.app","label":"Application","size":188679,"size_human":"189KB","bundle_id":"com.install4j.5557-0173-2810-0000.443","kind":"application"}],"apps":[{"query":"pdate","name":"Updater","bundle_id":"com.install4j.5889-6375-8446-2021.443","path":"/Users/henry/Applications/Trader Workstation/.install4j/Updater.app","item_count":0,"leftover_bytes":0,"total_bytes":188695,"total_human":"189KB","application":{"path":"/Users/henry/Applications/Trader Workstation/.install4j/Updater.app","present":true,"size":188695,"size_human":"189KB","needs_admin":false,"action":"delete","cask":null,"refusal":null}},{"query":"pdate","name":"Updater","bundle_id":"com.install4j.5557-0173-2810-0000.443","path":"/Users/henry/Applications/IBKR Desktop/.install4j/Updater.app","item_count":0,"leftover_bytes":0,"total_bytes":188679,"total_human":"189KB","application":{"path":"/Users/henry/Applications/IBKR Desktop/.install4j/Updater.app","present":true,"size":188679,"size_human":"189KB","needs_admin":false,"action":"delete","cask":null,"refusal":null}}],"unmatched":[],"matched_count":2,"requires_confirmation":true,"ambiguous":[{"query":"pdate","matched":2,"names":["Updater","Updater"]}],"removes_applications":2,"requires_admin":false,"external_commands":[],"warnings":[]}}"#

    /// `uninstall --dry-run dev.caezium.BurrowScratchRefused` — a scratch bundle whose name embeds
    /// a newline, which `validate_path_for_deletion` refuses on its control-character rule.
    private let dryRunRefusedBundle = #"{"ok":true,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"uninstall","data":{"dry_run":true,"total_bytes":5,"total_human":"5B","items":[{"path":"/Users/henry/Applications/Burrow\nScratchRefused.app","label":"Application","size":384,"size_human":"384B","bundle_id":"dev.caezium.BurrowScratchRefused","kind":"application"},{"path":"/Users/henry/Library/Caches/dev.caezium.BurrowScratchRefused","label":"Cache","size":5,"size_human":"5B","bundle_id":"dev.caezium.BurrowScratchRefused","kind":"leftover"}],"apps":[{"query":"dev.caezium.BurrowScratchRefused","name":"Burrow?ScratchRefused","bundle_id":"dev.caezium.BurrowScratchRefused","path":"/Users/henry/Applications/Burrow\nScratchRefused.app","item_count":1,"leftover_bytes":5,"total_bytes":5,"total_human":"5B","application":{"path":"/Users/henry/Applications/Burrow\nScratchRefused.app","present":true,"size":384,"size_human":"384B","needs_admin":false,"action":"delete","cask":null,"refusal":"path validation failed: contains control characters: /Users/henry/Applications/Burrow\nScratchRefused.app"}}],"unmatched":[],"matched_count":1,"requires_confirmation":false,"ambiguous":[],"removes_applications":0,"requires_admin":false,"external_commands":[],"warnings":[]}}"#

    /// `uninstall --apply dev.caezium.BurrowUninstallScratch` — the clean case, exit 0.
    private let applyRemoved = #"{"ok":true,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"uninstall","data":{"dry_run":false,"freed_bytes":917987,"freed_human":"918KB","applications_removed":1,"applications_refused":0,"warnings":[],"removed":[{"path":"/Users/henry/Applications/BurrowUninstallScratch.app","size":819674,"bundle_id":"dev.caezium.BurrowUninstallScratch","kind":"application"},{"path":"/Users/henry/Library/Application Support/dev.caezium.BurrowUninstallScratch","size":32768,"bundle_id":"dev.caezium.BurrowUninstallScratch","kind":"leftover"},{"path":"/Users/henry/Library/Caches/dev.caezium.BurrowUninstallScratch","size":65536,"bundle_id":"dev.caezium.BurrowUninstallScratch","kind":"leftover"},{"path":"/Users/henry/Library/Preferences/dev.caezium.BurrowUninstallScratch.plist","size":5,"bundle_id":"dev.caezium.BurrowUninstallScratch","kind":"leftover"},{"path":"/Users/henry/Library/Logs/dev.caezium.BurrowUninstallScratch","size":4,"bundle_id":"dev.caezium.BurrowUninstallScratch","kind":"leftover"}],"errors":[],"protected":[],"apps":[{"query":"dev.caezium.BurrowUninstallScratch","name":"BurrowUninstallScratch","bundle_id":"dev.caezium.BurrowUninstallScratch","path":"/Users/henry/Applications/BurrowUninstallScratch.app","status":"removed","application":{"path":"/Users/henry/Applications/BurrowUninstallScratch.app","state":"removed","via":"trash","bytes":819674,"reason":null,"suggestion":null},"removed_count":4,"leftover_freed_bytes":98313,"error_count":0,"protected_count":0,"freed_bytes":917987,"freed_human":"918KB","leftovers_attempted":true}],"unmatched":[]}}"#

    /// `uninstall --apply --permanent dev.caezium.BurrowScratchPartial` — bundle gone, one
    /// `chflags uchg` leftover not. **Exit 1 with an `ok:true` envelope.**
    private let applyPartial = #"{"ok":true,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"uninstall","data":{"dry_run":false,"freed_bytes":388,"freed_human":"388B","applications_removed":1,"applications_refused":0,"warnings":[],"removed":[{"path":"/Users/henry/Applications/BurrowScratchPartial.app","size":384,"bundle_id":"dev.caezium.BurrowScratchPartial","kind":"application"},{"path":"/Users/henry/Library/Logs/dev.caezium.BurrowScratchPartial","size":4,"bundle_id":"dev.caezium.BurrowScratchPartial","kind":"leftover"}],"errors":[{"path":"/Users/henry/Library/Caches/dev.caezium.BurrowScratchPartial","error":"Operation not permitted (os error 1)","bundle_id":"dev.caezium.BurrowScratchPartial","kind":"leftover"}],"protected":[],"apps":[{"query":"dev.caezium.BurrowScratchPartial","name":"BurrowScratchPartial","bundle_id":"dev.caezium.BurrowScratchPartial","path":"/Users/henry/Applications/BurrowScratchPartial.app","status":"partial","application":{"path":"/Users/henry/Applications/BurrowScratchPartial.app","state":"removed","via":"permanent","bytes":384,"reason":null,"suggestion":null},"removed_count":1,"leftover_freed_bytes":4,"error_count":1,"protected_count":0,"freed_bytes":388,"freed_human":"388B","leftovers_attempted":true}],"unmatched":[]}}"#

    /// `uninstall --apply dev.caezium.BurrowScratchRefused` — the bundle refused, and the leftover
    /// sweep therefore never attempted. Exit 1, `ok:true`.
    private let applyRefused = #"{"ok":true,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"uninstall","data":{"dry_run":false,"freed_bytes":0,"freed_human":"0B","applications_removed":0,"applications_refused":1,"warnings":[],"removed":[],"errors":[{"path":"/Users/henry/Applications/Burrow\nScratchRefused.app","error":"path validation failed: contains control characters: /Users/henry/Applications/Burrow\nScratchRefused.app","bundle_id":"dev.caezium.BurrowScratchRefused","kind":"application"}],"protected":["/Users/henry/Applications/Burrow\nScratchRefused.app"],"apps":[{"query":"dev.caezium.BurrowScratchRefused","name":"Burrow?ScratchRefused","bundle_id":"dev.caezium.BurrowScratchRefused","path":"/Users/henry/Applications/Burrow\nScratchRefused.app","status":"refused","application":{"path":"/Users/henry/Applications/Burrow\nScratchRefused.app","state":"refused","via":null,"bytes":0,"reason":"path validation failed: contains control characters: /Users/henry/Applications/Burrow\nScratchRefused.app","suggestion":null},"removed_count":0,"leftover_freed_bytes":0,"error_count":0,"protected_count":0,"freed_bytes":0,"freed_human":"0B","leftovers_attempted":false}],"unmatched":[]}}"#

    /// `uninstall --dry-run com.nonexistent.zzz`. THE HAZARD FIXTURE — see `matchedApps`.
    private let errorNoMatch = #"{"ok":false,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"uninstall","error":{"kind":"error","message":"No matching applications found. (com.nonexistent.zzz)","platform":"macos"}}"#

    /// `uninstall --dry-run com.apple.Safari` — `should_protect_from_uninstall`.
    private let errorProtected = #"{"ok":false,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"uninstall","error":{"kind":"error","message":"com.apple.Safari is a protected system component and cannot be uninstalled","platform":"macos"}}"#

    // MARK: - Legacy captures (a real `mo` / MIT fork; mole 1.x)

    private let legacySingle = """
    \u{1B}[0;33m→ DRY RUN MODE\u{1B}[0m, No app files or settings will be modified

    \u{1B}[2J\u{1B}[H\u{1B}[1;34m◎\u{1B}[0m Matched 1 app(s):
    1. IDLE  187KB  |  Last: 1y ago

    Proceed with uninstallation? [y/N]
    """

    private let legacyMulti = """
    \u{1B}[2J\u{1B}[H\u{1B}[1;34m◎\u{1B}[0m Matched 3 app(s):
    1. Slack  120MB  |  Last: 2d ago
    2. Python Launcher  315KB  |  Last: 1y ago
    3. Zoom  80MB  |  Last: 5d ago

    Proceed with uninstallation? [y/N]
    """

    private let legacyNone = """
    \u{1B}[0;33mWarning:\u{1B}[0m No application found matching 'Nope'
    No matching applications found.
    """

    // MARK: - Engine and legacy are told apart structurally, not by luck

    /// The defect this replaces. The engine's no-match message carries the oracle's exact
    /// "No matching applications found." sentence — kept verbatim on purpose — which is the one
    /// string the legacy text parser reads as "matched nothing", i.e. `[]`. Handing it engine JSON
    /// therefore produced a confident empty answer about a binary the parser cannot read, and the
    /// run only failed closed because `[]` then disagreed with a non-empty confirmed set.
    func testMatchedApps_refusesEngineJSONOutrightRatherThanReadingItsNoMatchWordingAsEmpty() {
        XCTAssertTrue(errorNoMatch.contains("No matching applications found."),
                      "the fixture must still carry the sentence, or this test proves nothing")
        XCTAssertNil(UninstallGuard.matchedApps(inDryRunOutput: errorNoMatch),
                     "an envelope is not a matched set — nil, never []")
        XCTAssertNil(UninstallGuard.matchedApps(inDryRunOutput: dryRunPlain))
        XCTAssertNil(UninstallGuard.matchedApps(inDryRunOutput: applyRemoved))
    }

    func testReadDryRun_routesEachShapeToItsOwnCase() {
        guard case .engine = UninstallGuard.readDryRun(stdout: dryRunPlain, stderr: "") else {
            return XCTFail("an ok:true envelope is the engine case")
        }
        guard case .engineRefused = UninstallGuard.readDryRun(stdout: errorNoMatch, stderr: "") else {
            return XCTFail("an ok:false envelope is a refusal, NOT an empty legacy match")
        }
        guard case .legacy(let names) = UninstallGuard.readDryRun(stdout: legacyMulti, stderr: "") else {
            return XCTFail("mo's text is the legacy case")
        }
        XCTAssertEqual(names, ["Slack", "Python Launcher", "Zoom"])
        guard case .unreadable = UninstallGuard.readDryRun(stdout: "Segmentation fault", stderr: "") else {
            return XCTFail("neither shape must fail closed")
        }
        guard case .unreadable = UninstallGuard.readDryRun(stdout: "", stderr: "") else {
            return XCTFail("no output at all must fail closed")
        }
    }

    func testReadDryRun_legacyStillParsesItsOwnFormats() {
        XCTAssertEqual(UninstallGuard.matchedApps(inDryRunOutput: legacySingle), ["IDLE"])
        XCTAssertEqual(UninstallGuard.matchedApps(inDryRunOutput: legacyNone), [],
                       "a real mo saying it matched nothing is [], and only a real mo can say it")
    }

    // MARK: - What the plan decodes to

    func testPlan_readsTheBundleItselfAndNotJustTheLeftovers() throws {
        guard case .engine(let plan) = UninstallGuard.readDryRun(stdout: dryRunPlain, stderr: "") else {
            return XCTFail("expected the engine case")
        }
        let app = try XCTUnwrap(plan.apps.first)
        XCTAssertEqual(app.query, "org.localsend.localsendApp",
                       "query echoes the argument verbatim — that is what makes the check exact")
        XCTAssertEqual(app.application.path, "/Applications/LocalSend.app")
        XCTAssertTrue(app.application.present)
        XCTAssertFalse(app.application.isHomebrewCask)
        XCTAssertNil(app.application.refusal)
        XCTAssertEqual(plan.removesApplications, 1)
        XCTAssertFalse(plan.requiresAdmin)
        XCTAssertTrue(plan.externalCommands.isEmpty)
    }

    func testPlan_readsTheBrewZapCommandAsAnExternalCommand() throws {
        guard case .engine(let plan) = UninstallGuard.readDryRun(stdout: dryRunBrew, stderr: "") else {
            return XCTFail("expected the engine case")
        }
        let app = try XCTUnwrap(plan.apps.first)
        XCTAssertTrue(app.application.isHomebrewCask)
        XCTAssertEqual(app.application.cask, "stats")
        XCTAssertEqual(plan.homebrewRemovals.map(\.name), ["Stats"])
        XCTAssertTrue(plan.directRemovals.isEmpty)
        XCTAssertEqual(plan.externalCommands.first?.command, "brew uninstall --cask --zap stats")
    }

    /// `--zap` removes bytes the enumeration cannot list, so the advisory has to name the command
    /// rather than gesture at "Homebrew will handle it".
    func testAdvisories_nameTheZapCommandVerbatim() throws {
        guard case .engine(let plan) = UninstallGuard.readDryRun(stdout: dryRunBrew, stderr: "") else {
            return XCTFail("expected the engine case")
        }
        let advisories = UninstallGuard.advisories(for: plan)
        XCTAssertTrue(advisories.contains { $0.contains("brew uninstall --cask --zap stats") },
                      "\(advisories)")
    }

    // MARK: - The verdict

    func testAbort_nilWhenTheEngineResolvedExactlyWhatWasConfirmed() {
        let reading = UninstallGuard.readDryRun(stdout: dryRunPlain, stderr: "")
        XCTAssertNil(UninstallGuard.abortReason(confirmed: ["org.localsend.localsendApp"],
                                                dryRun: reading))
    }

    /// Compared as bundle ids — display names are the ambiguity this path exists to remove — but
    /// the app the engine WOULD have removed is named as well as identified, because a bare
    /// `org.localsend.localsendApp` tells a user who picked Steam nothing.
    func testAbort_whenTheEngineResolvedADifferentAppThanTheOneConfirmed() throws {
        let reading = UninstallGuard.readDryRun(stdout: dryRunPlain, stderr: "")
        let reason = try XCTUnwrap(UninstallGuard.abortReason(confirmed: ["com.valvesoftware.steam"],
                                                              dryRun: reading))
        XCTAssertTrue(reason.contains("LocalSend (org.localsend.localsendApp)"), reason)
        XCTAssertTrue(reason.contains("com.valvesoftware.steam"), reason)
    }

    /// The label is presentation only — it must never decide the comparison.
    func testMismatch_labelsDoNotAffectTheVerdict() {
        XCTAssertNil(UninstallGuard.mismatchDescription(confirmed: ["com.foo.Bar"],
                                                        matched: ["com.foo.Bar"],
                                                        labels: ["com.foo.bar": "Something Else"]))
    }

    /// The ambiguity refusal, met BEFORE the apply rather than bounced off it. `uninstall --apply
    /// pdate` is refused outright by the engine; aborting here shows the user which term was
    /// over-broad instead of turning a refusal into a mystery.
    func testAbort_onTheEnginesOwnAmbiguityVerdict() throws {
        let reading = UninstallGuard.readDryRun(stdout: dryRunAmbiguous, stderr: "")
        let reason = try XCTUnwrap(UninstallGuard.abortReason(confirmed: ["pdate"], dryRun: reading))
        XCTAssertTrue(reason.contains("pdate"), reason)
        XCTAssertTrue(reason.contains("Updater"), reason)
    }

    /// A rail already declines this bundle, and the dry run says so. Running anyway would spend a
    /// destructive `--apply` to be told the same thing.
    func testAbort_whenTheDryRunAlreadyCarriesARefusalForTheBundle() throws {
        let reading = UninstallGuard.readDryRun(stdout: dryRunRefusedBundle, stderr: "")
        let reason = try XCTUnwrap(
            UninstallGuard.abortReason(confirmed: ["dev.caezium.BurrowScratchRefused"],
                                       dryRun: reading))
        XCTAssertTrue(reason.contains("path validation failed"), reason)
    }

    func testAbort_showsTheEnginesOwnRefusalRatherThanInventingOne() throws {
        for fixture in [errorNoMatch, errorProtected] {
            let reading = UninstallGuard.readDryRun(stdout: fixture, stderr: "")
            let reason = try XCTUnwrap(UninstallGuard.abortReason(confirmed: ["com.foo.Bar"],
                                                                  dryRun: reading))
            XCTAssertTrue(reason.contains("No matching applications found.")
                          || reason.contains("protected system component"), reason)
        }
    }

    func testAbort_unreadableOutputFailsClosed() {
        XCTAssertNotNil(UninstallGuard.abortReason(confirmed: ["com.foo.Bar"],
                                                   dryRun: .unreadable))
        XCTAssertNotNil(UninstallGuard.abortReason(
            confirmed: ["com.foo.Bar"],
            dryRun: UninstallGuard.readDryRun(stdout: "Segmentation fault", stderr: "")))
    }

    /// `requires_admin` is deliberately NOT an abort: the engine's `needs_admin` is an `access(2)`
    /// approximation that skips ACLs, so refusing on it would block removals that would work. It
    /// rides in the advisories, and the engine's own suggestion carries the remedy afterwards.
    func testAdminIsAnAdvisoryNotAnAbort() throws {
        let elevated = dryRunPlain
            .replacingOccurrences(of: "\"needs_admin\":false", with: "\"needs_admin\":true")
            .replacingOccurrences(of: "\"requires_admin\":false", with: "\"requires_admin\":true")
        guard case .engine(let plan) = UninstallGuard.readDryRun(stdout: elevated, stderr: "") else {
            return XCTFail("expected the engine case")
        }
        XCTAssertTrue(plan.requiresAdmin)
        XCTAssertNil(UninstallGuard.abortReason(confirmed: ["org.localsend.localsendApp"],
                                                dryRun: .engine(plan)))
        XCTAssertTrue(UninstallGuard.advisories(for: plan).contains { $0.contains("LocalSend") },
                      "the advisory must name the app that needs elevation")
    }

    // MARK: - Outcomes

    func testOutcome_cleanRunReportsTrashAndNoProblems() throws {
        let outcome = try XCTUnwrap(UninstallGuard.readOutcome(stdout: applyRemoved))
        XCTAssertTrue(outcome.allRemoved)
        XCTAssertEqual(outcome.applicationsRemoved, 1)
        XCTAssertEqual(outcome.apps.first?.application.via, "trash",
                       "the DEFAULT run routes the .app to the real Trash — this is the evidence")
        XCTAssertNil(UninstallGuard.problemReport(outcome))
    }

    /// The shape that used to be reported as a plain failure with the whole JSON document pasted
    /// into the alert: exit 1, envelope `ok:true`, one app partly done.
    func testOutcome_partialIsAPerAppVerdictNotAGenericFailure() throws {
        let outcome = try XCTUnwrap(UninstallGuard.readOutcome(stdout: applyPartial))
        XCTAssertFalse(outcome.allRemoved)
        XCTAssertEqual(outcome.applicationsRemoved, 1)
        XCTAssertEqual(outcome.problems.map(\.status), ["partial"])
        XCTAssertEqual(outcome.apps.first?.application.via, "permanent",
                       "--permanent does not use the Trash, and the report must not say it did")
        let report = try XCTUnwrap(UninstallGuard.problemReport(outcome))
        XCTAssertTrue(report.contains("BurrowScratchPartial"), report)
    }

    /// A refused bundle means the leftovers were never attempted (`batch.sh:840`'s gate), so the
    /// app is still installed rather than half-removed — which the user has to be told, or an
    /// empty-looking result reads as "it worked".
    func testOutcome_refusedSaysTheSupportFilesWereLeftAloneToo() throws {
        let outcome = try XCTUnwrap(UninstallGuard.readOutcome(stdout: applyRefused))
        XCTAssertEqual(outcome.applicationsRemoved, 0)
        XCTAssertEqual(outcome.applicationsRefused, 1)
        let app = try XCTUnwrap(outcome.apps.first)
        XCTAssertEqual(app.status, "refused")
        XCTAssertFalse(app.leftoversAttempted)
        let report = try XCTUnwrap(UninstallGuard.problemReport(outcome))
        XCTAssertTrue(report.contains("path validation failed"),
                      "the engine's own reason, verbatim: \(report)")
        XCTAssertTrue(report.contains(NSLocalizedString("Its support files were left alone, so the app is still installed rather than half-removed.", comment: "uninstall outcome")),
                      report)
    }

    /// The engine's `suggestion` is the user's next action. A report that drops it leaves them with
    /// a failure and no move.
    func testOutcome_surfacesTheEnginesSuggestion() throws {
        let needsAdmin = applyRefused
            .replacingOccurrences(of: "\"suggestion\":null",
                                  with: "\"suggestion\":\"Re-run with administrator privileges\"")
        let outcome = try XCTUnwrap(UninstallGuard.readOutcome(stdout: needsAdmin))
        let report = try XCTUnwrap(UninstallGuard.problemReport(outcome))
        XCTAssertTrue(report.contains("Re-run with administrator privileges"), report)
    }

    func testOutcome_nilForAnythingThatIsNotASuccessEnvelope() {
        XCTAssertNil(UninstallGuard.readOutcome(stdout: errorNoMatch))
        XCTAssertNil(UninstallGuard.readOutcome(stdout: legacyMulti))
        XCTAssertNil(UninstallGuard.readOutcome(stdout: ""))
    }

    // MARK: - Mismatch description

    func testMismatch_nilWhenSetsAgree() {
        XCTAssertNil(UninstallGuard.mismatchDescription(confirmed: ["IDLE"], matched: ["IDLE"]))
        XCTAssertNil(UninstallGuard.mismatchDescription(confirmed: ["Slack", "Zoom"],
                                                        matched: ["Zoom", "Slack"]),
                     "order must not matter")
        XCTAssertNil(UninstallGuard.mismatchDescription(confirmed: ["idle"], matched: ["IDLE"]),
                     "case must not matter — names echo mo's own canonical list")
    }

    func testMismatch_reportsExtraApps() throws {
        let desc = try XCTUnwrap(UninstallGuard.mismatchDescription(confirmed: ["Slack"],
                                                                    matched: ["Slack", "Zoom"]))
        XCTAssertTrue(desc.contains("Zoom"),
                      "the app the binary would remove beyond the confirmation must be named")
    }

    func testMismatch_reportsMissingApps() throws {
        let desc = try XCTUnwrap(UninstallGuard.mismatchDescription(confirmed: ["Slack", "Zoom"],
                                                                    matched: ["Slack"]))
        XCTAssertTrue(desc.contains("Zoom"))
    }

    func testMismatch_countDivergenceAlwaysMismatches() {
        XCTAssertNotNil(UninstallGuard.mismatchDescription(confirmed: ["Slack"], matched: []))
        XCTAssertNotNil(UninstallGuard.mismatchDescription(confirmed: [], matched: ["Slack"]))
    }
}
