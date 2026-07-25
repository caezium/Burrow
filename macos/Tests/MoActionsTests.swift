//
//  MoActionsTests.swift
//  BurrowTests
//
//  The gated-actions core (issue #51): one pure gate shared by the GUI
//  and the MCP server, one catalog of per-action facts (argv / stdin /
//  timeouts / elevation), and one owner for the MCP wire format.
//
//  The decide() truth table is the safety model: a runnable ticket can
//  ONLY be minted by the gate (RunTicket's init is file-private to
//  MoActions.swift), so "GUI and MCP behave identically" is a property
//  of the code, not a discipline.
//

import XCTest
@testable import Burrow

final class MoActionsTests: XCTestCase {

    // MARK: - Agent gate: previews are always allowed

    func testAgent_previewIsAlwaysAllowed_evenWithNoOptIns() throws {
        let gate = ActionGate.agent(actionsOptIn: false, irreversibleOptIn: false)
        guard case .run(let ticket) = MoActions.decide(.clean, .preview, gate) else {
            return XCTFail("preview must not require any opt-in")
        }
        // Engine-style, not mo-style: the ticket's args are what actually gets spawned (the
        // bundled binary is the engine post-repoint), so `mint` translates mo's `--dry-run` away
        // to the engine's own dry-run default rather than passing it through untranslated.
        XCTAssertEqual(ticket.command.args, ["clean"])
        XCTAssertNil(ticket.command.stdin)
        XCTAssertEqual(ticket.command.timeout, 180)
        XCTAssertFalse(ticket.command.elevated)
        XCTAssertEqual(ticket.mode, .preview)
        XCTAssertNil(ticket.preflight)
    }

    // MARK: - Agent gate: real runs need the opt-in

    func testAgent_realCleanWithoutOptIn_isBlocked() {
        let gate = ActionGate.agent(actionsOptIn: false, irreversibleOptIn: false)
        XCTAssertEqual(MoActions.decide(.clean, .real, gate),
                       .blocked(.agentCleanupsOptInOff))
        XCTAssertEqual(MoActions.decide(.optimize, .real, gate),
                       .blocked(.agentCleanupsOptInOff))
    }

    func testAgent_realCleanWithOptIn_runsUnelevated() throws {
        let gate = ActionGate.agent(actionsOptIn: true, irreversibleOptIn: false)
        guard case .run(let ticket) = MoActions.decide(.clean, .real, gate) else {
            return XCTFail("opted-in real clean must run")
        }
        // A live mo run (`["clean"]`, no --dry-run) needs the engine's --apply, or this would
        // silently no-op against the engine's dry-run default — the exact §2 bug.
        XCTAssertEqual(ticket.command.args, ["clean", "--apply"])
        // An MCP server can't field a sudo prompt — agent runs never elevate.
        XCTAssertFalse(ticket.command.elevated)
        XCTAssertEqual(ticket.command.timeout, 600)
    }

    // MARK: - Agent gate: uninstall needs BOTH switches

    func testAgent_uninstallNeedsTheSecondOptInToo() {
        let action = MoAction.uninstall(apps: ["Slack"], permanent: false)
        XCTAssertEqual(
            MoActions.decide(action, .real, .agent(actionsOptIn: false, irreversibleOptIn: false)),
            .blocked(.agentCleanupsOptInOff))
        XCTAssertEqual(
            MoActions.decide(action, .real, .agent(actionsOptIn: false, irreversibleOptIn: true)),
            .blocked(.agentCleanupsOptInOff),
            "the second switch alone is not enough — gate order pinned")
        XCTAssertEqual(
            MoActions.decide(action, .real, .agent(actionsOptIn: true, irreversibleOptIn: false)),
            .blocked(.agentUninstallOptInOff))
    }

    func testAgent_uninstallFullyOptedIn_mintsPreflightedTicket() throws {
        let action = MoAction.uninstall(apps: ["Slack", "Zoom"], permanent: true)
        let gate = ActionGate.agent(actionsOptIn: true, irreversibleOptIn: true)
        guard case .run(let ticket) = MoActions.decide(action, .real, gate) else {
            return XCTFail("fully opted-in uninstall must run")
        }
        // --apply appended (live mo run, no --dry-run to drop); --permanent rides through
        // untouched — it isn't part of the dry-run/apply mapping.
        XCTAssertEqual(ticket.command.args, ["uninstall", "--permanent", "Slack", "Zoom", "--apply"])
        XCTAssertEqual(ticket.command.stdin, String(repeating: "y\n", count: 4))
        XCTAssertEqual(ticket.command.timeout, 600)
        XCTAssertEqual(ticket.preflight, .verifyUninstallMatch(expected: ["Slack", "Zoom"]))
    }

    func testAgent_uninstallPreview_skipsPreflightAndStdin() throws {
        let action = MoAction.uninstall(apps: ["Slack"], permanent: false)
        guard case .run(let ticket) = MoActions.decide(
            action, .preview, .agent(actionsOptIn: false, irreversibleOptIn: false)) else {
            return XCTFail("uninstall preview is read-only — always allowed")
        }
        XCTAssertEqual(ticket.command.args, ["uninstall", "Slack"])
        XCTAssertNil(ticket.preflight)
    }

    // MARK: - Agent gate: interactive tools downgrade with a note

    func testAgent_realPurge_downgradesToPreviewWithNote() throws {
        let gate = ActionGate.agent(actionsOptIn: true, irreversibleOptIn: true)
        guard case .run(let ticket) = MoActions.decide(.purge, .real, gate) else {
            return XCTFail("agent purge must downgrade, not block")
        }
        XCTAssertEqual(ticket.mode, .preview, "real purge is TUI-only — agents get the preview")
        XCTAssertEqual(ticket.command.args, ["purge"])
        XCTAssertNotNil(ticket.note, "the downgrade carries the redirect note")

        guard case .run(let plain) = MoActions.decide(.purge, .preview, gate) else {
            return XCTFail()
        }
        XCTAssertEqual(plain.command.args, ["purge"])
        XCTAssertNil(plain.note, "an asked-for preview needs no redirect")
    }

    // MARK: - GUI gate

    func testGUI_previewWithoutFDA_gatesUnlessElevationGranted() throws {
        XCTAssertEqual(
            MoActions.decide(.clean, .preview, .gui(hasFullDiskAccess: false)),
            .needsFullDiskAccess)
        guard case .run(let ticket) = MoActions.decide(
            .clean, .preview, .gui(hasFullDiskAccess: false, elevationGranted: true)) else {
            return XCTFail("'Scan with admin' resolves the gate — root bypasses TCC")
        }
        XCTAssertTrue(ticket.command.elevated)
        XCTAssertEqual(ticket.command.args, ["clean"])
    }

    func testGUI_realCleanNeedsExplicitConfirm_thenRunsElevated() throws {
        XCTAssertEqual(
            MoActions.decide(.clean, .real, .gui(hasFullDiskAccess: false)),
            .needsConfirmation)
        guard case .run(let ticket) = MoActions.decide(
            .clean, .real, .gui(hasFullDiskAccess: false, userConfirmed: true)) else {
            return XCTFail("confirmed real clean must run")
        }
        XCTAssertTrue(ticket.command.elevated, "real clean goes through the one auth prompt")
        XCTAssertNil(ticket.command.timeout, "a watched streaming run is explicitly unbounded")
    }

    func testGUI_optimizeAuthPromptIsTheConsent() throws {
        // No .needsConfirmation cell for optimize: the admin prompt IS the
        // user's yes.
        guard case .run(let ticket) = MoActions.decide(
            .optimize, .real, .gui(hasFullDiskAccess: false)) else {
            return XCTFail("optimize must run without a separate dialog")
        }
        XCTAssertTrue(ticket.command.elevated)
        XCTAssertEqual(ticket.command.args, ["optimize", "--apply"])
    }

    func testGUI_uninstallConfirmedTicket_carriesPreflightAndUnifiedTimeout() throws {
        let action = MoAction.uninstall(apps: ["Slack"], permanent: false)
        XCTAssertEqual(MoActions.decide(action, .real, .gui(hasFullDiskAccess: true)),
                       .needsConfirmation)
        guard case .run(let ticket) = MoActions.decide(
            action, .real, .gui(hasFullDiskAccess: true, userConfirmed: true)) else {
            return XCTFail()
        }
        XCTAssertEqual(ticket.preflight, .verifyUninstallMatch(expected: ["Slack"]))
        XCTAssertFalse(ticket.command.elevated)
        // Deliberate unification: the GUI previously used 300 s where MCP
        // used 600 s for the same command — the catalog spells it once.
        XCTAssertEqual(ticket.command.timeout, 600)
    }

    func testGUI_realPurgeRoutesToTheInteractiveFlow() {
        XCTAssertEqual(MoActions.decide(.purge, .real, .gui(hasFullDiskAccess: true)),
                       .interactiveFlow)
        XCTAssertEqual(MoActions.decide(.installer, .real, .gui(hasFullDiskAccess: true)),
                       .interactiveFlow)
    }

    // MARK: - GUI ≡ MCP equivalence

    /// Same action, both surfaces fully consented: the argv, stdin, and
    /// preflight must be identical — only elevation and timeout may differ,
    /// and those differences are the documented asymmetry (agents can't
    /// field auth prompts; watched streams are unbounded).
    func testEquivalence_confirmedGUIAndOptedInAgentMintTheSameCommand() throws {
        let action = MoAction.uninstall(apps: ["Slack"], permanent: false)
        guard case .run(let gui) = MoActions.decide(
                  action, .real, .gui(hasFullDiskAccess: true, userConfirmed: true)),
              case .run(let agent) = MoActions.decide(
                  action, .real, .agent(actionsOptIn: true, irreversibleOptIn: true)) else {
            return XCTFail()
        }
        XCTAssertEqual(gui.command.args, agent.command.args)
        XCTAssertEqual(gui.command.stdin, agent.command.stdin)
        XCTAssertEqual(gui.preflight, agent.preflight)
        XCTAssertEqual(gui.command.timeout, agent.command.timeout)
        // Pin the concrete value too, not just "the two surfaces agree" — engine-style
        // (--apply appended), never mo's own live-by-default argv passed through raw.
        XCTAssertEqual(gui.command.args, ["uninstall", "Slack", "--apply"])
    }

    // MARK: - mo↔engine argv translation (the §2 fix)
    //
    // `mint` is the one place every RunTicket's args get built, so this sweeps the whole catalog
    // rather than relying on one example per action to catch a regression. The bundled binary
    // every ticket ultimately reaches is the engine (post-repoint), which reads mo's own
    // `--dry-run`-less "live" argv as ITS dry-run — so a ticket that still carries a bare
    // mo-style live command with no `--apply` would silently no-op if this translation ever
    // regressed.

    func testMint_everyRealTicket_carriesApply_neverBareDryRun() throws {
        let cases: [(MoAction, ActionGate)] = [
            (.clean, .agent(actionsOptIn: true, irreversibleOptIn: true)),
            (.optimize, .agent(actionsOptIn: true, irreversibleOptIn: true)),
            (.uninstall(apps: ["Slack"], permanent: false),
             .agent(actionsOptIn: true, irreversibleOptIn: true)),
        ]
        for (action, gate) in cases {
            guard case .run(let ticket) = MoActions.decide(action, .real, gate) else {
                return XCTFail("\(action) real run should mint under a fully opted-in gate")
            }
            XCTAssertTrue(ticket.command.args.contains("--apply"),
                         "\(action): a real run must reach the engine with --apply, or it " +
                         "silently no-ops against the engine's dry-run default")
            XCTAssertFalse(ticket.command.args.contains("--dry-run"),
                          "\(action): mo's own --dry-run flag is meaningless to the engine and " +
                          "must not leak through untranslated")
        }
    }

    func testMint_everyPreviewTicket_neverCarriesApply() throws {
        let cases: [MoAction] = [.clean, .optimize, .purge, .installer,
                                 .uninstall(apps: ["Slack"], permanent: false)]
        for action in cases {
            guard case .run(let ticket) = MoActions.decide(
                action, .preview, .agent(actionsOptIn: false, irreversibleOptIn: false)) else {
                return XCTFail("\(action) preview should always mint")
            }
            XCTAssertFalse(ticket.command.args.contains("--apply"),
                          "\(action): a preview must never gain --apply — that would turn a " +
                          "\"just show me\" request into a live destructive run")
            XCTAssertFalse(ticket.command.args.contains("--dry-run"),
                          "\(action): mo's --dry-run is translated away, not passed through")
        }
    }

    // MARK: - The frozen wire format (golden tests)

    func testWire_simpleDryRunResult_isByteStable() {
        let json = ActionWire.result(command: "clean", dryRun: true, ran: false,
                                     exitCode: 0, output: "ok")
        XCTAssertEqual(json, #"{"command":"clean","dry_run":true,"exit_code":0,"output":"ok","ran":false}"#)
    }

    func testWire_resultAttachesParsedSummary() throws {
        let transcript = """
        ➤ User Caches
        → removed 12 items, 191.3MB
        Potential space: 383.8MB | Items: 372 | Categories: 20
        """
        let json = ActionWire.result(command: "clean", dryRun: true, ran: false,
                                     exitCode: 0, output: transcript)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let summary = try XCTUnwrap(obj["summary"] as? [String: Any],
                                    "agents get structured freed-bytes, not just prose")
        XCTAssertEqual(summary["space"] as? String, "383.8MB")
        XCTAssertEqual(summary["items"] as? String, "372")
        XCTAssertEqual(summary["categories"] as? String, "20")
        XCTAssertEqual(obj["output"] as? String, transcript, "raw output stays — additive only")
    }

    func testWire_timedOutRun_isByteStable_andSaysWhatHappened() {
        // Observed in real agent transcripts: a killed clean rendered as
        // `{"exit_code":9,"output":"","ran":false}` — nothing actionable.
        let json = ActionWire.result(command: "clean", dryRun: true, ran: false,
                                     exitCode: 9, output: "", timedOutAfter: 600)
        XCTAssertEqual(json, #"{"command":"clean","dry_run":true,"exit_code":9,"hint":"mo clean was killed after 600s without finishing — retry, or run it from the Burrow app","output":"","ran":false,"timed_out":true}"#)
    }

    func testWire_untimedResult_carriesNoTimeoutMarker() {
        let json = ActionWire.result(command: "clean", dryRun: true, ran: false,
                                     exitCode: 0, output: "ok")
        XCTAssertFalse(json.contains("timed_out"), "additive only — absent unless it happened")
    }

    func testWire_blockedClean_isByteStable() {
        let json = ActionWire.blocked(command: "clean", reason: .agentCleanupsOptInOff)
        XCTAssertEqual(json, #"{"blocked":true,"command":"clean","ran":false,"reason":"Real cleanups are off. Turn on 'Let agents run cleanups for real' in Burrow ▸ Settings, then retry with confirm:true. (A dry-run preview works without it.)"}"#)
    }

    func testWire_blockedUninstall_isByteStable() {
        let json = ActionWire.blocked(command: "uninstall", reason: .agentUninstallOptInOff,
                                      apps: ["Slack"])
        XCTAssertEqual(json, #"{"apps":["Slack"],"blocked":true,"command":"uninstall","ran":false,"reason":"Uninstalls are off for agents. Real `mo uninstall` (and any permanent delete) additionally requires 'Also allow uninstalls & permanent deletes' in Burrow ▸ Settings ▸ Agent. A dry-run preview works without it."}"#)
    }

    func testWire_interactivePreviewWithConfirm_isByteStable() {
        let json = ActionWire.result(command: "purge", dryRun: true, ran: false,
                                     exitCode: 0, output: "would purge",
                                     note: "Real `mo purge` is an interactive selection flow — run it from the Burrow app. This is the preview.")
        XCTAssertEqual(json, #"{"command":"purge","dry_run":true,"exit_code":0,"interactive_only":true,"note":"Real `mo purge` is an interactive selection flow — run it from the Burrow app. This is the preview.","output":"would purge","ran":false}"#)
    }

    func testWire_uninstallAborts_areByteStable() {
        // The nil-matched case is what every real call against the bundled engine hits (it
        // answers in JSON, never the legacy text `matchedApps` parses) — the message must say
        // uninstall is unavailable in this build and why, not the old "couldn't verify" non-answer.
        XCTAssertEqual(
            ActionWire.uninstallAbort(apps: ["Slack"], matched: nil),
            #"{"apps":["Slack"],"command":"uninstall","error":"aborted: Uninstall isn't available in this build: the bundled engine can only resolve one app per request and expects an exact bundle id where Burrow currently sends display names, so there's no reliable way to confirm what it would actually remove before anything is deleted.","ran":false}"#)
        XCTAssertEqual(
            ActionWire.uninstallAbort(apps: ["Slack"], matched: ["Slack", "Slackpad"],
                                      mismatch: "mo would also remove: Slackpad"),
            #"{"apps":["Slack"],"command":"uninstall","error":"aborted: mo matched a different set than requested (mo would also remove: Slackpad). Use exact names from burrow_list_apps.","matched":["Slack","Slackpad"],"ran":false}"#)
    }

    /// Guards the exact honesty property Fix 2 introduced: the nil-matched abort must name the
    /// build limitation, and must NOT claim a verification was attempted (the old wording read as
    /// "we tried to check and couldn't", when in fact no check is even possible against this
    /// engine yet).
    func testWire_uninstallAbort_nilMatch_namesTheRealReason() {
        let json = ActionWire.uninstallAbort(apps: ["Slack"], matched: nil)
        XCTAssertTrue(json.contains("unavailable in this build"),
                      "must say uninstall is unavailable in this build: \(json)")
        XCTAssertFalse(json.contains("couldn't verify"),
                       "must not claim a verification was attempted and came back inconclusive: \(json)")
    }
}
