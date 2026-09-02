//
//  BurrowEnvelopeTests.swift
//  BurrowTests
//
//  The conductor envelope is the contract every migrated call site will parse: branch on `ok`,
//  read `data` (success) or `error` (failure). These pin the parse — including the int-precision
//  round-trip that lets `data` feed the command's own decoder — plus BurrowEngine's pure
//  argv/env shaping. Mirrors the Windows BurrowEnvelopeTests (#248) so both GUIs prove the same
//  contract. (The spawn itself can't run in CI; these cover everything up to it.)
//

import XCTest
@testable import Burrow

final class BurrowEnvelopeTests: XCTestCase {

    // MARK: envelope parsing

    func testSuccessEnvelope_extractsDataForConcreteDecoder() throws {
        let json = #"{"ok":true,"burrow_cli":"0.0.1","engine":"burrow-engine","command":"status","data":{"health_score":92}}"#
        let env = try BurrowEnvelope.parse(json)
        XCTAssertTrue(env.ok)
        XCTAssertEqual(env.command, "status")
        XCTAssertEqual(env.burrowCli, "0.0.1")
        XCTAssertNil(env.error)
        // `data` round-trips to bytes the command's own decoder reads — and stays an INTEGER
        // (92, not 92.0), which a Codable Double bridge would have blurred.
        let data = try XCTUnwrap(env.data)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(payload["health_score"] as? Int, 92)
    }

    func testFailureEnvelope_branchesOnOkAndClassifies() throws {
        let json = #"{"ok":false,"burrow_cli":"0.0.1","engine":"burrow-engine","command":"clean","error":{"kind":"not_found","message":"engine \"mole\" not found","platform":"macos"}}"#
        let env = try BurrowEnvelope.parse(json)
        XCTAssertFalse(env.ok)
        XCTAssertNil(env.data, "a failure carries no data")
        XCTAssertEqual(env.command, "clean")
        let err = try XCTUnwrap(env.error)
        XCTAssertEqual(err.kind, "not_found")
        XCTAssertEqual(err.message, #"engine "mole" not found"#)
        XCTAssertEqual(err.platform, "macos")
    }

    func testUnsupportedEnvelope_carriesFeatureAlongsideError() throws {
        let json = #"{"ok":false,"burrow_cli":"0.0.1","engine":"burrow-engine","command":"dupes","error":{"kind":"unsupported","message":"not on Windows"},"feature":"dupes apply"}"#
        let env = try BurrowEnvelope.parse(json)
        XCTAssertFalse(env.ok)
        XCTAssertEqual(env.error?.kind, "unsupported")
        XCTAssertEqual(env.error?.feature, "dupes apply")
    }

    func testTextData_survivesAsValidJSON() throws {
        // clean's dry-run report comes back as data.text (escaped newlines/quotes) — the
        // envelope must keep it as valid, decodable JSON.
        let json = #"{"ok":true,"burrow_cli":"0.0.1","engine":"burrow-engine","command":"clean","data":{"text":"Would remove:\n  ~/Library/Caches"}}"#
        let env = try BurrowEnvelope.parse(json)
        XCTAssertTrue(env.ok)
        let data = try XCTUnwrap(env.data)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue((payload["text"] as? String)?.contains("Would remove") ?? false)
    }

    func testDataArray_isSupported() throws {
        let json = #"{"ok":true,"burrow_cli":"0.0.1","engine":"burrow-engine","command":"analyze","data":[1,2,3]}"#
        let env = try BurrowEnvelope.parse(json)
        let data = try XCTUnwrap(env.data)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? [Int], [1, 2, 3])
    }

    func testGarbage_throwsNotJSON() {
        XCTAssertThrowsError(try BurrowEnvelope.parse("not json at all")) { error in
            XCTAssertTrue(error is BurrowEnvelope.ParseError)
        }
    }

    func testNonObjectJSON_throwsNotAnObject() {
        XCTAssertThrowsError(try BurrowEnvelope.parse("[1,2,3]"))
    }

    // MARK: conductor command shaping

    func testConductorArgv_appendsJsonAfterArgs() {
        XCTAssertEqual(BurrowEngine.argv(command: "analyze", args: ["/tmp"]),
                       ["analyze", "/tmp", "--json"])
        XCTAssertEqual(BurrowEngine.argv(command: "status", args: []),
                       ["status", "--json"])
    }

    func testConductorEnvironment_neverSetsEngineDir() {
        // BURROW_ENGINE_DIR named the OLD conductor at the digger's runtime directory (a sibling
        // Resources/engine this app layout never had post-repoint). The engine looks for nothing,
        // so this key must never be (re)introduced.
        XCTAssertNil(BurrowEngine.environment()["BURROW_ENGINE_DIR"])
    }

    // MARK: PATH augmentation (the Finder-launch trap — brew sidecars/engine shell-outs)

    func testAugmentedPATH_prependsHomebrewBinsToStrippedLaunchPATH() {
        // The launchd/Finder default — no /opt/homebrew/bin.
        let out = BurrowEngine.augmentedPATH("/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(out, "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    func testAugmentedPATH_isIdempotentAndPreservesExistingEntries() {
        // A terminal launch already has the brew bins — don't duplicate them or reorder.
        let terminal = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        XCTAssertEqual(BurrowEngine.augmentedPATH(terminal), terminal)
        // Only the missing one is added.
        XCTAssertEqual(BurrowEngine.augmentedPATH("/opt/homebrew/bin:/usr/bin"),
                       "/usr/local/bin:/opt/homebrew/bin:/usr/bin")
    }

    func testAugmentedPATH_handlesEmptyOrNil() {
        let fallback = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        XCTAssertEqual(BurrowEngine.augmentedPATH(nil), fallback)
        XCTAssertEqual(BurrowEngine.augmentedPATH(""), fallback)
    }

    // MARK: mo→engine argv translation (safety-critical: dry-run/apply INVERSION)
    //
    // `engineArgv` is the semantic mapping every caller shares — MoActions's action catalog
    // (MCP + the Software tab's uninstall) and this file's own streaming path alike. Test it
    // directly, not just through `streamArgv`, since `MoActionsTests` pins the MoActions side of
    // the same contract.

    func testEngineArgv_preview_dropsDryRun_neverApply() {
        // mo preview (`clean --dry-run`) maps to the engine's DEFAULT (dry-run) — must NOT gain
        // --apply, or a "preview" would delete for real.
        XCTAssertEqual(BurrowEngine.engineArgv(fromMo: ["clean", "--dry-run"]), ["clean"])
    }

    func testEngineArgv_live_addsApply() {
        // mo live (`clean`, no --dry-run) needs --apply on the engine — or a real clean would
        // silently no-op (the engine defaults to dry-run). This is the §2 bug in miniature.
        XCTAssertEqual(BurrowEngine.engineArgv(fromMo: ["clean"]), ["clean", "--apply"])
        XCTAssertEqual(BurrowEngine.engineArgv(fromMo: ["optimize"]), ["optimize", "--apply"])
    }

    func testEngineArgv_uninstallPreview_singleAndMultiApp() {
        XCTAssertEqual(BurrowEngine.engineArgv(fromMo: ["uninstall", "--dry-run", "Slack"]),
                       ["uninstall", "Slack"])
        XCTAssertEqual(
            BurrowEngine.engineArgv(fromMo: ["uninstall", "--dry-run", "Slack", "Zoom"]),
            ["uninstall", "Slack", "Zoom"])
    }

    func testEngineArgv_uninstallLive_permanentFlagPassesThroughUntouched() {
        // --permanent isn't part of the dry-run/apply inversion this function owns — it rides
        // through unchanged either way. (The engine doesn't currently interpret it at all; see
        // the accompanying report — that's a separate, already-flagged gap, not this mapping's job.)
        XCTAssertEqual(
            BurrowEngine.engineArgv(fromMo: ["uninstall", "--permanent", "Slack"]),
            ["uninstall", "--permanent", "Slack", "--apply"])
    }

    // MARK: assertDryRun — read-only stated on the wire, not inherited from the engine's default

    func testEngineArgv_assertDryRun_spellsTheFlagInsteadOfRelyingOnTheDefault() {
        // Without it a preview is "no flag", which is read-only only for as long as the engine
        // keeps defaulting that way. With it the argv says so — and `uninstall` is the command
        // where that distinction now costs an application rather than a wrong screen.
        XCTAssertEqual(
            BurrowEngine.engineArgv(fromMo: ["uninstall", "--dry-run", "Slack"],
                                       assertDryRun: true),
            ["uninstall", "Slack", "--dry-run"])
        XCTAssertEqual(
            BurrowEngine.engineArgv(fromMo: ["uninstall", "--dry-run", "Slack", "Zoom"],
                                       assertDryRun: true),
            ["uninstall", "Slack", "Zoom", "--dry-run"])
    }

    func testEngineArgv_assertDryRun_forcesThePreviewEvenOnLiveMoArgv() {
        // It means "this run must not change anything", not "pass the flag along if one was
        // already there". A caller that asks for it on mo's LIVE spelling gets the preview, not
        // a live run with an ignored parameter — the failure direction has to be the safe one.
        XCTAssertEqual(BurrowEngine.engineArgv(fromMo: ["uninstall", "Slack"],
                                                  assertDryRun: true),
                       ["uninstall", "Slack", "--dry-run"])
        XCTAssertEqual(BurrowEngine.engineArgv(fromMo: ["clean"], assertDryRun: true),
                       ["clean", "--dry-run"])
    }

    func testEngineArgv_defaultIsOff_soEveryExistingCallerIsByteIdentical() {
        // `mint`, `streamArgv` and OperationFlow all call the one-argument form. Adding a
        // parameter must not have moved any of them.
        for mo in [["clean"], ["clean", "--dry-run"], ["optimize"],
                   ["uninstall", "--dry-run", "Slack"], ["uninstall", "--permanent", "Slack"]] {
            XCTAssertEqual(BurrowEngine.engineArgv(fromMo: mo),
                           BurrowEngine.engineArgv(fromMo: mo, assertDryRun: false), "\(mo)")
        }
    }

    /// The one combination the engine refuses outright: `reject_contradictory_flags` answers
    /// `--apply` + `--dry-run` with `ok:false` and **exit 2** ("uninstall cannot take both …"),
    /// before dispatch reaches the command. Verified against burrow-engine @ `4a46426`, both
    /// orderings. So a translation that could emit the pair doesn't delete anything — it turns
    /// every uninstall into an unreadable failure — but the pre-flight would then abort on a
    /// format problem rather than on what the engine actually said, which is the wrong sentence
    /// in front of the user and one refactor away from being the wrong outcome too.
    ///
    /// Swept over both the mo spellings and both parameter values rather than pinned by example:
    /// the guarantee is structural (the two appends are the arms of one `if`), so the test that
    /// matches it is exhaustive, not illustrative.
    func testEngineArgv_neverEmitsApplyAndDryRunTogether() {
        let moShapes: [[String]] = [
            ["clean"], ["clean", "--dry-run"],
            ["optimize"], ["optimize", "--dry-run"],
            ["purge"], ["purge", "--dry-run"],
            ["installer"], ["installer", "--dry-run"],
            ["uninstall", "Slack"], ["uninstall", "--dry-run", "Slack"],
            ["uninstall", "--permanent", "Slack"],
            ["uninstall", "--permanent", "--dry-run", "Slack", "Zoom"],
        ]
        for mo in moShapes {
            for assert in [false, true] {
                let out = BurrowEngine.engineArgv(fromMo: mo, assertDryRun: assert)
                XCTAssertFalse(out.contains("--apply") && out.contains("--dry-run"),
                               "\(mo) assertDryRun:\(assert) → \(out): the engine refuses this " +
                               "pair at exit 2 and no argv this function builds may contain it")
                // Belt and braces on the same fact: at most one of the two, ever.
                XCTAssertLessThanOrEqual(
                    out.filter { $0 == "--apply" || $0 == "--dry-run" }.count, 1, "\(out)")
            }
        }
        // And `streamArgv`, which only ever adds a transport flag on top.
        for mo in moShapes {
            let out = BurrowEngine.streamArgv(fromMo: mo)
            XCTAssertFalse(out.contains("--apply") && out.contains("--dry-run"), "\(out)")
        }
    }

    func testStreamArgv_preview_dropsDryRun_neverApply() {
        // Delegates to engineArgv, plus the transport-only --stream.
        XCTAssertEqual(BurrowEngine.streamArgv(fromMo: ["clean", "--dry-run"]),
                       ["clean", "--stream"])
    }

    func testStreamArgv_live_addsApply() {
        XCTAssertEqual(BurrowEngine.streamArgv(fromMo: ["clean"]),
                       ["clean", "--apply", "--stream"])
        XCTAssertEqual(BurrowEngine.streamArgv(fromMo: ["optimize"]),
                       ["optimize", "--apply", "--stream"])
    }

    // MARK: streamOverride / shouldStreamViaConductor

    func testShouldStreamViaConductor_onByDefault() {
        // `streamingEnabled` is `?? true` (see its doc: "Default ON, hand-validated on a real
        // build") — with no UserDefaults key set (the CI/fresh-launch case), clean/optimize stream
        // through the conductor unless someone explicitly turns the switch off. An earlier version
        // of this test asserted the OPPOSITE — that the switch defaults OFF — which doesn't match
        // `streamingEnabled`'s own `?? true` fallback and failed in exactly the environment (no
        // host app, no launch args) it claimed to cover.
        withStreamSwitch(nil) {
            XCTAssertTrue(BurrowEngine.shouldStreamViaConductor(command: "clean"))
            XCTAssertTrue(BurrowEngine.shouldStreamViaConductor(command: "optimize"))
        }
    }

    func testShouldStreamViaConductor_explicitlyOff_disablesStreaming() {
        withStreamSwitch(false) {
            XCTAssertFalse(BurrowEngine.shouldStreamViaConductor(command: "clean"))
            XCTAssertFalse(BurrowEngine.shouldStreamViaConductor(command: "optimize"))
        }
    }

    func testShouldStreamViaConductor_onlyTheCommandsTheEngineStreams_whenSwitchIsOn() {
        withStreamSwitch(true) {
            XCTAssertTrue(BurrowEngine.shouldStreamViaConductor(command: "clean"))
            XCTAssertTrue(BurrowEngine.shouldStreamViaConductor(command: "optimize"))
            // `purge --stream` speaks clean's NDJSON vocabulary (BUR-132) and streams too.
            XCTAssertTrue(BurrowEngine.shouldStreamViaConductor(command: "purge"))
            // installer has no --stream in the engine (it runs buffered); uninstall is
            // matcher-gated — neither is ever streamed, switch on or off.
            XCTAssertFalse(BurrowEngine.shouldStreamViaConductor(command: "installer"))
            XCTAssertFalse(BurrowEngine.shouldStreamViaConductor(command: "uninstall"))
        }
    }

    /// No conductor staged → no override, whatever the switch says, because there is nothing to
    /// route to. This is the fallback every call site depends on.
    func testStreamOverride_withoutBundledConductor_keepsDirectEngine() {
        ConductorBundleFixture.withConductor(present: false) {
            XCTAssertNil(BurrowEngine.streamOverride(moArgs: ["clean"]))
        }
    }

    /// Streaming is ON by default (`BurrowStreamViaConductor` unset), so a build that bundled the
    /// conductor routes `clean` through it.
    ///
    /// This used to be asserted the other way round, as "off by default keeps the direct engine".
    /// It only ever passed because the test host bundled no conductor and `streamOverride` bailed
    /// at its last guard — so the assertion held for a reason unrelated to the switch, and would
    /// have kept holding had the default flipped either way.
    func testStreamOverride_withBundledConductor_routesThroughItByDefault() {
        withStreamSwitch(nil) {
            ConductorBundleFixture.withConductor(present: true) {
                let override = BurrowEngine.streamOverride(moArgs: ["clean"])
                XCTAssertEqual(override?.arguments, ["clean", "--apply", "--stream"])
                XCTAssertEqual(URL(fileURLWithPath: override?.executable ?? "").lastPathComponent, "burrow")
            }
        }
    }

    /// The documented kill-switch has to actually kill it.
    func testStreamOverride_killSwitchKeepsDirectEngineEvenWithConductorBundled() {
        withStreamSwitch(false) {
            ConductorBundleFixture.withConductor(present: true) {
                XCTAssertNil(BurrowEngine.streamOverride(moArgs: ["clean"]))
            }
        }
    }

    /// The inverse of the assertion this replaces. `streamOverride` used to take an `elevated`
    /// flag and return nil for every elevated run; that guard meant `CleanView`/`TuneUpView`'s
    /// real clean/optimize (the app's only GUI callers of `.moleStream`, all `elevated: true`)
    /// never received the mo→engine argv translation, so every actual Clean/Optimize button fell
    /// through to the direct-engine path with untranslated argv — which the engine reads with
    /// inverted dry-run/apply meaning. The parameter is gone (see `shouldStreamViaConductor`'s
    /// doc); elevation now decides osascript-vs-plain-spawn in `SystemProcessPort` and nothing
    /// else. An elevated run must therefore route exactly like an unelevated one.
    func testStreamOverride_elevatedRunsRouteThroughTheConductorToo() {
        withStreamSwitch(true) {
            ConductorBundleFixture.withConductor(present: true) {
                // The argv an elevated LIVE clean produces — `--apply`, so it actually deletes.
                let override = BurrowEngine.streamOverride(moArgs: ["clean"])
                XCTAssertEqual(override?.arguments, ["clean", "--apply", "--stream"])
            }
        }
    }

    /// The switch lives in the scratch suite for the duration — see the shared fixture.
    private func withStreamSwitch(_ value: Bool?, _ body: () -> Void) {
        ConductorBundleFixture.withStreamSwitch(value, body)
    }

    /// The property the fixture exists for: flipping the switch inside a test must leave the
    /// developer's real preference domain exactly as it was.
    func testStreamSwitchFixture_neverWritesTheLiveDefaultsDomain() {
        let key = BurrowEngine.streamingKey
        let before = UserDefaults.standard.object(forKey: key) as? Bool
        withStreamSwitch(false) {
            XCTAssertFalse(BurrowEngine.streamingEnabled)
            XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Bool, before,
                           "the switch must be flipped in the scratch suite, not in .standard")
        }
        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Bool, before)
    }
}
