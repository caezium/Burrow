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

    // MARK: - Which binary every expectation below is about
    //
    // A ticket's argv is only meaningful relative to the program that will read it, so `mint`
    // resolves the binary ONCE and translates the catalog's mo-style argv only when what resolved
    // is the engine sealed in the app bundle. That makes every assertion in this file an
    // assertion ABOUT A BINARY, and this helper is where each test says which one.
    //
    // The default is the bundled engine because that is what a shipped build resolves — so the
    // byte-for-byte pins below are the argv production actually sends. Tests that mean the other
    // binary pass `on:` explicitly. Nothing here touches real discovery: the CI runner has
    // neither a bundled engine nor a Homebrew `mo`, and a test whose answer depended on that
    // would be pinning the machine rather than the gate.

    private static let bundledPath = "/fake/bundled/burrow"
    /// Where `MoleCLI.trustedExecutable()` lands when no engine is bundled — a real legacy `mo`
    /// (mole 1.46.0 on the machine this was written on), which deletes by default.
    private static let legacyMoPath = "/opt/homebrew/bin/mo"

    private func decide(_ action: MoAction, _ mode: RunMode, _ gate: ActionGate,
                        on target: EngineTarget = .bundledEngine(MoActionsTests.bundledPath)) -> Verdict {
        MoActions.decide(action, mode, gate, resolve: { _ in target })
    }

    // MARK: - Agent gate: previews are always allowed

    func testAgent_previewIsAlwaysAllowed_evenWithNoOptIns() throws {
        let gate = ActionGate.agent(actionsOptIn: false, irreversibleOptIn: false)
        guard case .run(let ticket) = decide(.clean, .preview, gate) else {
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
        XCTAssertEqual(decide(.clean, .real, gate),
                       .blocked(.agentCleanupsOptInOff))
        XCTAssertEqual(decide(.optimize, .real, gate),
                       .blocked(.agentCleanupsOptInOff))
    }

    func testAgent_realCleanWithOptIn_runsUnelevated() throws {
        let gate = ActionGate.agent(actionsOptIn: true, irreversibleOptIn: false)
        guard case .run(let ticket) = decide(.clean, .real, gate) else {
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
            decide(action, .real, .agent(actionsOptIn: false, irreversibleOptIn: false)),
            .blocked(.agentCleanupsOptInOff))
        XCTAssertEqual(
            decide(action, .real, .agent(actionsOptIn: false, irreversibleOptIn: true)),
            .blocked(.agentCleanupsOptInOff),
            "the second switch alone is not enough — gate order pinned")
        XCTAssertEqual(
            decide(action, .real, .agent(actionsOptIn: true, irreversibleOptIn: false)),
            .blocked(.agentUninstallOptInOff))
    }

    func testAgent_uninstallFullyOptedIn_mintsPreflightedTicket() throws {
        let action = MoAction.uninstall(apps: ["Slack", "Zoom"], permanent: true)
        let gate = ActionGate.agent(actionsOptIn: true, irreversibleOptIn: true)
        guard case .run(let ticket) = decide(action, .real, gate) else {
            return XCTFail("fully opted-in uninstall must run")
        }
        // --apply appended (live mo run, no --dry-run to drop); --permanent rides through
        // untouched — it isn't part of the dry-run/apply mapping.
        XCTAssertEqual(ticket.command.args, ["uninstall", "--permanent", "Slack", "Zoom", "--apply"])
        XCTAssertEqual(ticket.command.stdin, String(repeating: "y\n", count: 4))
        XCTAssertEqual(ticket.command.timeout, 600)
        XCTAssertEqual(ticket.preflight?.policy, .verifyUninstallMatch(expected: ["Slack", "Zoom"]))
    }

    func testAgent_uninstallPreview_skipsPreflightAndStdin() throws {
        let action = MoAction.uninstall(apps: ["Slack"], permanent: false)
        guard case .run(let ticket) = decide(
            action, .preview, .agent(actionsOptIn: false, irreversibleOptIn: false)) else {
            return XCTFail("uninstall preview is read-only — always allowed")
        }
        XCTAssertEqual(ticket.command.args, ["uninstall", "Slack"])
        XCTAssertNil(ticket.preflight)
    }

    // MARK: - Agent gate: interactive tools downgrade with a note

    func testAgent_realPurge_downgradesToPreviewWithNote() throws {
        let gate = ActionGate.agent(actionsOptIn: true, irreversibleOptIn: true)
        guard case .run(let ticket) = decide(.purge, .real, gate) else {
            return XCTFail("agent purge must downgrade, not block")
        }
        XCTAssertEqual(ticket.mode, .preview, "real purge is TUI-only — agents get the preview")
        XCTAssertEqual(ticket.command.args, ["purge"])
        XCTAssertNotNil(ticket.note, "the downgrade carries the redirect note")

        guard case .run(let plain) = decide(.purge, .preview, gate) else {
            return XCTFail()
        }
        XCTAssertEqual(plain.command.args, ["purge"])
        XCTAssertNil(plain.note, "an asked-for preview needs no redirect")
    }

    // MARK: - GUI gate

    func testGUI_previewWithoutFDA_gatesUnlessElevationGranted() throws {
        XCTAssertEqual(
            decide(.clean, .preview, .gui(hasFullDiskAccess: false)),
            .needsFullDiskAccess)
        guard case .run(let ticket) = decide(
            .clean, .preview, .gui(hasFullDiskAccess: false, elevationGranted: true)) else {
            return XCTFail("'Scan with admin' resolves the gate — root bypasses TCC")
        }
        XCTAssertTrue(ticket.command.elevated)
        XCTAssertEqual(ticket.command.args, ["clean"])
    }

    func testGUI_realCleanNeedsExplicitConfirm_thenRunsElevated() throws {
        XCTAssertEqual(
            decide(.clean, .real, .gui(hasFullDiskAccess: false)),
            .needsConfirmation)
        guard case .run(let ticket) = decide(
            .clean, .real, .gui(hasFullDiskAccess: false, userConfirmed: true)) else {
            return XCTFail("confirmed real clean must run")
        }
        XCTAssertTrue(ticket.command.elevated, "real clean goes through the one auth prompt")
        XCTAssertNil(ticket.command.timeout, "a watched streaming run is explicitly unbounded")
    }

    func testGUI_optimizeAuthPromptIsTheConsent() throws {
        // No .needsConfirmation cell for optimize: the admin prompt IS the
        // user's yes.
        guard case .run(let ticket) = decide(
            .optimize, .real, .gui(hasFullDiskAccess: false)) else {
            return XCTFail("optimize must run without a separate dialog")
        }
        XCTAssertTrue(ticket.command.elevated)
        XCTAssertEqual(ticket.command.args, ["optimize", "--apply"])
    }

    func testGUI_uninstallConfirmedTicket_carriesPreflightAndUnifiedTimeout() throws {
        let action = MoAction.uninstall(apps: ["Slack"], permanent: false)
        XCTAssertEqual(decide(action, .real, .gui(hasFullDiskAccess: true)),
                       .needsConfirmation)
        guard case .run(let ticket) = decide(
            action, .real, .gui(hasFullDiskAccess: true, userConfirmed: true)) else {
            return XCTFail()
        }
        XCTAssertEqual(ticket.preflight?.policy, .verifyUninstallMatch(expected: ["Slack"]))
        XCTAssertFalse(ticket.command.elevated)
        // Deliberate unification: the GUI previously used 300 s where MCP
        // used 600 s for the same command — the catalog spells it once.
        XCTAssertEqual(ticket.command.timeout, 600)
    }

    func testGUI_realPurgeRoutesToTheInteractiveFlow() {
        XCTAssertEqual(decide(.purge, .real, .gui(hasFullDiskAccess: true)),
                       .interactiveFlow)
        XCTAssertEqual(decide(.installer, .real, .gui(hasFullDiskAccess: true)),
                       .interactiveFlow)
    }

    // MARK: - GUI ≡ MCP equivalence

    /// Same action, both surfaces fully consented: the argv, stdin, and
    /// preflight must be identical — only elevation and timeout may differ,
    /// and those differences are the documented asymmetry (agents can't
    /// field auth prompts; watched streams are unbounded).
    func testEquivalence_confirmedGUIAndOptedInAgentMintTheSameCommand() throws {
        let action = MoAction.uninstall(apps: ["Slack"], permanent: false)
        guard case .run(let gui) = decide(
                  action, .real, .gui(hasFullDiskAccess: true, userConfirmed: true)),
              case .run(let agent) = decide(
                  action, .real, .agent(actionsOptIn: true, irreversibleOptIn: true)) else {
            return XCTFail()
        }
        XCTAssertEqual(gui.command.args, agent.command.args)
        XCTAssertEqual(gui.command.stdin, agent.command.stdin)
        // The whole pre-flight, probe argv included — it is one value, so this compares both
        // halves and not just which check was asked for.
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
            guard case .run(let ticket) = decide(action, .real, gate) else {
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
            guard case .run(let ticket) = decide(
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

    // MARK: - WHICH binary the argv was built for (the preview that deleted)
    //
    // The translation above is correct for exactly one program. `mint` used to apply it
    // unconditionally while every ticket was spawned through a `.mo` target, and that target
    // falls through to `/opt/homebrew/bin/mo` when no engine is bundled. So on a build without
    // the staged engine, an MCP `burrow_clean` PREVIEW went in as the catalog's `["clean",
    // "--dry-run"]`, the translation dropped the flag (the engine previews by default and needs
    // no flag to say so), and what reached the legacy `mo` was `["clean"]` — mole 1.46.0's LIVE
    // clean. A preview that deletes.
    //
    // The guard is a path-identity check, the same one `OperationFlow.start` makes: translate
    // only when the resolved binary IS the bundled engine. These pin both sides of it, because
    // each direction breaks something different — untranslated argv to the engine silently
    // no-ops a real run, translated argv to mo deletes on a preview.

    func testMint_previewOnALegacyMo_keepsMosDryRun_soAPreviewCannotDelete() throws {
        let gate = ActionGate.agent(actionsOptIn: false, irreversibleOptIn: false)
        for action in [MoAction.clean, .optimize, .purge, .installer] {
            guard case .run(let ticket) = decide(action, .preview, gate,
                                                 on: .moStyle(Self.legacyMoPath)) else {
                return XCTFail("\(action) preview must still mint")
            }
            XCTAssertEqual(ticket.command.args, [action.commandName, "--dry-run"],
                           "\(action): a legacy mo runs LIVE without --dry-run, so dropping the " +
                           "flag for it turns a preview into a real destructive run")
        }
    }

    func testMint_uninstallPreviewOnALegacyMo_keepsMosDryRun() throws {
        guard case .run(let ticket) = decide(.uninstall(apps: ["Slack"], permanent: false), .preview,
                                             .agent(actionsOptIn: false, irreversibleOptIn: false),
                                             on: .moStyle(Self.legacyMoPath)) else {
            return XCTFail("an uninstall preview is read-only — always allowed")
        }
        XCTAssertEqual(ticket.command.args, ["uninstall", "--dry-run", "Slack"],
                       "engine-style `[uninstall, Slack]` is mo's live uninstall")
        XCTAssertNil(ticket.command.stdin, "and a preview never pre-answers a prompt")
    }

    func testMint_realRunOnALegacyMo_usesMosOwnLiveSpelling_neverApply() throws {
        let cases: [(MoAction, [String])] = [
            (.clean, ["clean"]),
            (.optimize, ["optimize"]),
            (.uninstall(apps: ["Slack"], permanent: false), ["uninstall", "Slack"]),
            (.uninstall(apps: ["Slack"], permanent: true), ["uninstall", "--permanent", "Slack"]),
        ]
        let gate = ActionGate.agent(actionsOptIn: true, irreversibleOptIn: true)
        for (action, expected) in cases {
            guard case .run(let ticket) = decide(action, .real, gate,
                                                 on: .moStyle(Self.legacyMoPath)) else {
                return XCTFail("\(action) real run should mint under a fully opted-in gate")
            }
            // mo IS live by default, so its live spelling is the bare command. `--apply` is not
            // merely redundant there: mole 1.46.0's clean.sh answers an unknown flag with
            // "Unknown option for mo clean" and exit 1, so the pre-fix argv made every real run
            // against a legacy mo fail before it started.
            XCTAssertEqual(ticket.command.args, expected, "\(action)")
        }
    }

    func testMint_whenNothingResolves_staysMoStyle_andSpawnsABinaryThatFails() throws {
        guard case .run(let ticket) = decide(.clean, .preview,
                                             .agent(actionsOptIn: false, irreversibleOptIn: false),
                                             on: .unresolved) else {
            return XCTFail("a preview mints whatever discovery found")
        }
        XCTAssertEqual(ticket.command.args, ["clean", "--dry-run"],
                       "an unidentified binary never receives engine-specific argv")
        XCTAssertNil(ticket.command.executable)
        XCTAssertEqual(ticket.command.spawnPath, "/usr/bin/false",
                       "same clean nonzero exit MoEngine already gives an unresolvable `.mo`")
    }

    // MARK: - One resolution, carried — not two that could disagree

    func testMint_carriesTheResolvedBinary_soTheSpawnCannotReResolve() throws {
        for target in [EngineTarget.bundledEngine(Self.bundledPath),
                       .moStyle(Self.legacyMoPath)] {
            guard case .run(let ticket) = decide(.uninstall(apps: ["Slack"], permanent: false),
                                                 .real,
                                                 .agent(actionsOptIn: true, irreversibleOptIn: true),
                                                 on: target) else {
                return XCTFail("\(target)")
            }
            XCTAssertEqual(ticket.command.executable, target.path,
                           "\(target): the ticket names the file its argv was built for")
            XCTAssertEqual(ticket.command.spawnPath, target.path)
            XCTAssertEqual(ticket.preflight?.command.executable, target.path,
                           "\(target): the probe reads the plan of the binary that will act on it")
        }
    }

    /// The decision and the spawn come from ONE lookup. Two lookups is not a style point: a
    /// second one that answered differently would hand a legacy `mo` argv translated for the
    /// engine, which is the whole defect.
    func testMint_resolvesExactlyOnce_perTicket() throws {
        var calls = 0
        let verdict = MoActions.decide(.uninstall(apps: ["Slack"], permanent: false), .real,
                                       .agent(actionsOptIn: true, irreversibleOptIn: true),
                                       resolve: { _ in
            calls += 1
            return .bundledEngine(Self.bundledPath)
        })
        guard case .run(let ticket) = verdict else { return XCTFail("fully opted-in must mint") }
        XCTAssertEqual(calls, 1, "argv, spawn path and pre-flight all come from one lookup")
        XCTAssertEqual(ticket.command.executable, ticket.preflight?.command.executable,
                       "so the probe and the run cannot be different files")
    }

    /// A refusal spawns nothing, so it asks discovery nothing — which also keeps `decide` free of
    /// a `which mo` subprocess on the paths that only ever return a verdict.
    func testDecide_refusals_neverResolveABinary() {
        var calls = 0
        let counting: (Bool) -> EngineTarget = { _ in
            calls += 1
            return .bundledEngine(Self.bundledPath)
        }
        _ = MoActions.decide(.clean, .real, .agent(actionsOptIn: false, irreversibleOptIn: false),
                             resolve: counting)                       // blocked
        _ = MoActions.decide(.clean, .real, .gui(hasFullDiskAccess: true), resolve: counting)
                                                                      // needsConfirmation
        _ = MoActions.decide(.clean, .preview, .gui(hasFullDiskAccess: false), resolve: counting)
                                                                      // needsFullDiskAccess
        _ = MoActions.decide(.purge, .real, .gui(hasFullDiskAccess: true), resolve: counting)
                                                                      // interactiveFlow
        XCTAssertEqual(calls, 0)
    }

    /// Elevation is settled BEFORE the lookup because it changes which lookup is legitimate: an
    /// elevated run must resolve through trusted locations only, never a PATH hit a user-writable
    /// directory could shadow. `mint` therefore has to ask with the ticket's own elevation.
    func testMint_asksTheLookupWithTheTicketsOwnElevation() {
        var asked: [Bool] = []
        let recording: (Bool) -> EngineTarget = {
            asked.append($0)
            return .bundledEngine(Self.bundledPath)
        }
        _ = MoActions.decide(.clean, .preview,
                             .gui(hasFullDiskAccess: false, elevationGranted: true),
                             resolve: recording)
        XCTAssertEqual(asked, [true], "'Scan with admin' resolves through the trusted lookup")

        asked = []
        _ = MoActions.decide(.clean, .preview,
                             .agent(actionsOptIn: false, irreversibleOptIn: false),
                             resolve: recording)
        XCTAssertEqual(asked, [false], "an agent preview never elevates")
    }

    // MARK: - The uninstall pre-flight's argv (read-only ASSERTED, not assumed)
    //
    // `matchPreflight`'s command is the probe that runs before the user's consent is acted on, and
    // its argv was untested — the section above pins what `mint` builds, which is a different string.
    // It used to translate to `["uninstall", <ids>]`: no flag at all, non-destructive purely
    // because the engine happens to default that way. That was a small bet while `uninstall` only
    // swept `~/Library` leftovers and a much larger one since burrow-engine `df9ea3f`, where the
    // same command deletes the `.app`. So the flag is on the wire now, and these pin it.
    //
    // The probe is built against the same resolved binary as the ticket it guards, so it has two
    // spellings and both are pinned: the engine's (below) and mo's own (`--dry-run` ahead of the
    // positionals), further down.

    /// The exact argv `matchPreflight` builds for one app, and the ONE definition of it in this
    /// file — the capture below is the verbatim stdout of running it, so a change to either has to
    /// move both, rather than leaving a hardcoded string quietly describing a run that no longer
    /// happens.
    private let preflightArgvLocalSend = ["uninstall", "org.localsend.localsendApp", "--dry-run"]

    /// Verbatim stdout of `burrow-engine` @ `4a46426` invoked with exactly
    /// `preflightArgvLocalSend`, captured 2026-08-08 against the real /Applications on this
    /// machine. Two things were established at the same time, neither of them hand-typed:
    ///
    ///  - The output is **byte-identical** to the flagless `uninstall org.localsend.localsendApp`
    ///    this argv replaces, so spelling the flag changed the guarantee and not the answer — the
    ///    guard reads the same plan it always did.
    ///  - `/Applications/LocalSend.app` was still on disk afterwards. The probe removes nothing.
    ///
    /// `data.dry_run` is the engine's own statement about which code path ran: `cli.rs` hard-codes
    /// `"dry_run":true` inside the `if !apply` branch and `"dry_run":false` in the apply branch, so
    /// it reports the branch taken rather than echoing a flag back.
    private let preflightCapture = #"{"ok":true,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"uninstall","data":{"dry_run":true,"total_bytes":58727750,"total_human":"58.7MB","items":[{"path":"/Applications/LocalSend.app","label":"Application","size":58686554,"size_human":"58.7MB","bundle_id":"org.localsend.localsendApp","kind":"application"},{"path":"/Users/henry/Library/Containers/org.localsend.localsendApp","label":"Container","size":41196,"size_human":"41KB","bundle_id":"org.localsend.localsendApp","kind":"leftover"}],"apps":[{"query":"org.localsend.localsendApp","name":"LocalSend","bundle_id":"org.localsend.localsendApp","path":"/Applications/LocalSend.app","matched_by":"identifier","item_count":1,"leftover_bytes":41196,"total_bytes":58727750,"total_human":"58.7MB","application":{"path":"/Applications/LocalSend.app","present":true,"size":58686554,"size_human":"58.7MB","needs_admin":false,"action":"delete","cask":null,"refusal":null,"symlink":false,"symlink_target":null}}],"unmatched":[],"matched_count":1,"requires_confirmation":false,"ambiguous":[],"removes_applications":1,"requires_admin":false,"external_commands":[],"warnings":[]}}"#

    func testPreflight_argvCarriesTheDryRunFlag_soReadOnlyIsNotInheritedFromADefault() throws {
        let action = MoAction.uninstall(apps: ["org.localsend.localsendApp"], permanent: false)
        let pre = try XCTUnwrap(action.matchPreflight(on: .bundledEngine(Self.bundledPath))?.command)
        XCTAssertEqual(pre.args, preflightArgvLocalSend)
        XCTAssertFalse(pre.elevated, "the probe never elevates — the uninstall ticket doesn't either")
    }

    /// The capture is what makes the pin above worth something: it is what the engine ANSWERED to
    /// that exact argv, so "read-only" is a measurement and not a belief about a default.
    func testPreflight_theCapturedAnswerToThatArgv_saysItRanReadOnly() throws {
        let envelope = try XCTUnwrap(BurrowEnvelope.inOutput(preflightCapture))
        XCTAssertTrue(envelope.ok)
        let data = try XCTUnwrap(envelope.data)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(payload["dry_run"] as? Bool, true,
                       "the engine reports which branch ran; anything but true means the probe " +
                       "was a real removal")
        // And the probe still does its job with the flag on — the guard's whole input is here.
        let plan = UninstallGuard.decodePlan(payload)
        XCTAssertEqual(plan.apps.map(\.query), ["org.localsend.localsendApp"])
        XCTAssertEqual(plan.apps.first?.path, "/Applications/LocalSend.app")
        XCTAssertEqual(plan.removesApplications, 1)
        XCTAssertNil(UninstallGuard.abortReason(confirmed: ["org.localsend.localsendApp"],
                                                dryRun: .engine(plan), expecting: []),
                     "a clean single-app resolution must still pass the guard")
    }

    /// The pair the engine refuses outright (`reject_contradictory_flags`, exit 2, "cannot take
    /// both"). Swept over the catalog rather than shown by example, because the pre-flight is built
    /// on a different code path from `mint` and only one of the two used to be covered at all.
    func testPreflight_neverCarriesApply_andNeverBothFlags() throws {
        let actions: [MoAction] = [
            .uninstall(apps: ["Slack"], permanent: false),
            .uninstall(apps: ["Slack"], permanent: true),
            .uninstall(apps: ["Slack", "Zoom"], permanent: true),
        ]
        // Swept over BOTH dialects: whichever binary resolved, the probe says it is read-only and
        // never carries the flag that deletes. `--apply` on a legacy `mo` is not merely wrong, it
        // is rejected outright ("Unknown uninstall option", exit 1) — but the reason it must not
        // be there is the engine's, and the reason it must not be there on mo is mo's, so the
        // property is asserted for each rather than argued from one.
        let targets: [EngineTarget] = [.bundledEngine(Self.bundledPath),
                                       .moStyle(Self.legacyMoPath), .unresolved]
        for action in actions {
            for target in targets {
                let pre = try XCTUnwrap(action.matchPreflight(on: target)?.command)
                XCTAssertTrue(pre.args.contains("--dry-run"),
                              "\(action) on \(target): the probe must SAY it is read-only, not inherit it")
                XCTAssertFalse(pre.args.contains("--apply"),
                               "\(action) on \(target): the probe runs before consent is acted on " +
                               "— it may never carry the flag that deletes")
                XCTAssertFalse(pre.args.contains("--permanent"),
                               "\(action) on \(target): a preview asks what would go, never how")
            }
        }
        XCTAssertNil(MoAction.clean.matchPreflight(on: .bundledEngine(Self.bundledPath)),
                     "only uninstall has a pre-flight")
        XCTAssertNil(MoAction.purge.matchPreflight(on: .moStyle(Self.legacyMoPath)))
    }

    /// The invalid state the type now forbids, asserted where it would come from.
    ///
    /// `RunTicket` used to carry the pre-flight POLICY and its PROBE as two independent optionals,
    /// which made "verify the matched set, with nothing to verify it against" a representable
    /// ticket. Nothing minted it, but the consumers could not know that: `MCP.execute` read both
    /// in one `if`, so a policy without a probe would have skipped the guard entirely and gone
    /// straight to the irreversible apply — failing OPEN, silently. `ActionPreflight` holds both,
    /// so that pair no longer exists to get wrong.
    ///
    /// What a type can't state is the other half of the coupling: that every action whose SPEC
    /// demands a pre-flight can actually build one. `mint` reads `requiresMatchPreflight` and asks
    /// the action for the value, and an action that answered nil there would mint a real
    /// destructive ticket with no guard at all. That is a catalog fact, so it is swept over the
    /// catalog rather than argued from the one action that has a pre-flight today.
    func testCatalog_specAndProbeAgreeOnWhichActionsHaveAPreflight() {
        let catalog: [MoAction] = [.clean, .optimize, .purge, .installer,
                                   .uninstall(apps: ["Slack"], permanent: false)]
        for action in catalog {
            XCTAssertEqual(action.spec.requiresMatchPreflight,
                           action.matchPreflight(on: .bundledEngine(Self.bundledPath)) != nil,
                           "\(action): the spec and the probe builder disagree — one direction " +
                           "mints an unguarded real run, the other guards a run that needs none")
        }
    }

    /// And the ticket end of it: a real uninstall arrives with BOTH halves, aimed at one binary.
    func testMint_realUninstallTicket_carriesPolicyAndProbeTogether() throws {
        guard case .run(let ticket) = decide(.uninstall(apps: ["Slack"], permanent: false), .real,
                                             .agent(actionsOptIn: true, irreversibleOptIn: true))
        else { return XCTFail("fully opted-in uninstall must mint") }
        let preflight = try XCTUnwrap(ticket.preflight,
                                      "a real uninstall without its pre-flight is an unguarded delete")
        XCTAssertEqual(preflight.policy, .verifyUninstallMatch(expected: ["Slack"]))
        XCTAssertEqual(preflight.command.args, ["uninstall", "Slack", "--dry-run"])
        XCTAssertEqual(preflight.command.executable, ticket.command.executable)
    }

    /// Multi-app, which also pins the flag's position after the positionals — verified accepted by
    /// the real binary, whose output for that spelling is byte-identical to the leading one.
    func testPreflight_multiAppArgv_isByteStable() throws {
        let action = MoAction.uninstall(apps: ["Slack", "Zoom"], permanent: true)
        let pre = try XCTUnwrap(action.matchPreflight(on: .bundledEngine(Self.bundledPath))?.command)
        XCTAssertEqual(pre.args, ["uninstall", "Slack", "Zoom", "--dry-run"])
        XCTAssertEqual(pre.stdin, "")
        XCTAssertEqual(pre.timeout, 120)
    }

    /// The other dialect. mo's own documented preview spelling, untranslated — `mo uninstall
    /// --dry-run <apps>`. Sending it the engine's spelling instead would be sending a binary
    /// argv built for a different program, and the only reason today's translated spelling
    /// survives contact with mole 1.46.0 is that its `uninstall.sh` happens to sweep every
    /// argument (`for arg in "$@"`) rather than stopping at the first positional. That is a
    /// property of a program Burrow doesn't own; not relying on it costs one branch.
    func testPreflight_onALegacyMo_isMosOwnPreviewSpelling() throws {
        let action = MoAction.uninstall(apps: ["Slack", "Zoom"], permanent: true)
        let pre = try XCTUnwrap(action.matchPreflight(on: .moStyle(Self.legacyMoPath))?.command)
        XCTAssertEqual(pre.args, ["uninstall", "--dry-run", "Slack", "Zoom"])
        XCTAssertEqual(pre.executable, Self.legacyMoPath,
                       "the probe carries the binary it was built for")
        XCTAssertEqual(pre.stdin, "")
        XCTAssertEqual(pre.timeout, 120)
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

    /// This test is about the WIRE FORMAT being byte stable — key order, escaping, `ran:false`,
    /// `matched` present only when the binary said something. The abort PROSE is passed in rather
    /// than composed here, and `UninstallGuardTests` owns whether each reason is the right one; a
    /// copy of the prose in this file would only catch edits, and it already went red once for a
    /// source change that was correct.
    func testWire_uninstallAborts_areByteStable() {
        XCTAssertEqual(
            ActionWire.uninstallAbort(apps: ["Slack"], reason: "the engine matched nothing."),
            #"{"apps":["Slack"],"command":"uninstall","error":"aborted: the engine matched nothing.","ran":false}"#)
        XCTAssertEqual(
            ActionWire.uninstallAbort(apps: ["Slack"], reason: "mo would also remove: Slackpad",
                                      matched: ["Slack", "Slackpad"]),
            #"{"apps":["Slack"],"command":"uninstall","error":"aborted: mo would also remove: Slackpad","matched":["Slack","Slackpad"],"ran":false}"#)
    }

    /// An abort never claims a run happened, whatever it was handed.
    func testWire_uninstallAbort_neverFlipsRan() throws {
        for matched in [nil, [], ["Slack"]] as [[String]?] {
            let json = ActionWire.uninstallAbort(apps: ["Slack"], reason: "nope", matched: matched)
            let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            XCTAssertEqual(obj["ran"] as? Bool, false, json)
            XCTAssertNotNil(obj["error"], json)
        }
    }
}
