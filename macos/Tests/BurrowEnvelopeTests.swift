//
//  BurrowEnvelopeTests.swift
//  BurrowTests
//
//  The conductor envelope is the contract every migrated call site will parse: branch on `ok`,
//  read `data` (success) or `error` (failure). These pin the parse — including the int-precision
//  round-trip that lets `data` feed the command's own decoder — plus BurrowConductor's pure
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
        XCTAssertEqual(BurrowConductor.argv(command: "analyze", args: ["/tmp"]),
                       ["analyze", "/tmp", "--json"])
        XCTAssertEqual(BurrowConductor.argv(command: "status", args: []),
                       ["status", "--json"])
    }

    func testConductorEnvironment_neverSetsEngineDir() {
        // BURROW_ENGINE_DIR named the OLD conductor at the digger's runtime directory (a sibling
        // Resources/engine this app layout never had post-repoint). The engine looks for nothing,
        // so this key must never be (re)introduced.
        XCTAssertNil(BurrowConductor.environment()["BURROW_ENGINE_DIR"])
    }

    // MARK: PATH augmentation (the Finder-launch trap — brew sidecars/engine shell-outs)

    func testAugmentedPATH_prependsHomebrewBinsToStrippedLaunchPATH() {
        // The launchd/Finder default — no /opt/homebrew/bin.
        let out = BurrowConductor.augmentedPATH("/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(out, "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    func testAugmentedPATH_isIdempotentAndPreservesExistingEntries() {
        // A terminal launch already has the brew bins — don't duplicate them or reorder.
        let terminal = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        XCTAssertEqual(BurrowConductor.augmentedPATH(terminal), terminal)
        // Only the missing one is added.
        XCTAssertEqual(BurrowConductor.augmentedPATH("/opt/homebrew/bin:/usr/bin"),
                       "/usr/local/bin:/opt/homebrew/bin:/usr/bin")
    }

    func testAugmentedPATH_handlesEmptyOrNil() {
        let fallback = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        XCTAssertEqual(BurrowConductor.augmentedPATH(nil), fallback)
        XCTAssertEqual(BurrowConductor.augmentedPATH(""), fallback)
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
        XCTAssertEqual(BurrowConductor.engineArgv(fromMo: ["clean", "--dry-run"]), ["clean"])
    }

    func testEngineArgv_live_addsApply() {
        // mo live (`clean`, no --dry-run) needs --apply on the engine — or a real clean would
        // silently no-op (the engine defaults to dry-run). This is the §2 bug in miniature.
        XCTAssertEqual(BurrowConductor.engineArgv(fromMo: ["clean"]), ["clean", "--apply"])
        XCTAssertEqual(BurrowConductor.engineArgv(fromMo: ["optimize"]), ["optimize", "--apply"])
    }

    func testEngineArgv_uninstallPreview_singleAndMultiApp() {
        XCTAssertEqual(BurrowConductor.engineArgv(fromMo: ["uninstall", "--dry-run", "Slack"]),
                       ["uninstall", "Slack"])
        XCTAssertEqual(
            BurrowConductor.engineArgv(fromMo: ["uninstall", "--dry-run", "Slack", "Zoom"]),
            ["uninstall", "Slack", "Zoom"])
    }

    func testEngineArgv_uninstallLive_permanentFlagPassesThroughUntouched() {
        // --permanent isn't part of the dry-run/apply inversion this function owns — it rides
        // through unchanged either way. (The engine doesn't currently interpret it at all; see
        // the accompanying report — that's a separate, already-flagged gap, not this mapping's job.)
        XCTAssertEqual(
            BurrowConductor.engineArgv(fromMo: ["uninstall", "--permanent", "Slack"]),
            ["uninstall", "--permanent", "Slack", "--apply"])
    }

    func testStreamArgv_preview_dropsDryRun_neverApply() {
        // Delegates to engineArgv, plus the transport-only --stream.
        XCTAssertEqual(BurrowConductor.streamArgv(fromMo: ["clean", "--dry-run"]),
                       ["clean", "--stream"])
    }

    func testStreamArgv_live_addsApply() {
        XCTAssertEqual(BurrowConductor.streamArgv(fromMo: ["clean"]),
                       ["clean", "--apply", "--stream"])
        XCTAssertEqual(BurrowConductor.streamArgv(fromMo: ["optimize"]),
                       ["optimize", "--apply", "--stream"])
    }

    // MARK: streamOverride / shouldStreamViaConductor
    //
    // `streamOverride` itself needs a real bundled `burrow` binary to ever return non-nil, which
    // this test host doesn't ship — so these test the pure decision (`shouldStreamViaConductor`)
    // rather than asserting a real override fires. Whether the resolved binary actually behaves
    // is the hand-test in the plan's exit gate ("An elevated clean that actually deletes").

    func testShouldStreamViaConductor_onByDefault() {
        // `streamingEnabled` is `?? true` (see its doc: "Default ON, hand-validated on a real
        // build") — with no UserDefaults key set (the CI/fresh-launch case, and this test's own
        // starting state), clean/optimize stream through the conductor unless someone explicitly
        // turns the switch off. An earlier version of this test asserted the OPPOSITE — that the
        // switch defaults OFF — which doesn't match `streamingEnabled`'s own `?? true` fallback
        // and failed in exactly the environment (no host app, no launch args) it claimed to cover.
        XCTAssertTrue(BurrowConductor.shouldStreamViaConductor(command: "clean"))
        XCTAssertTrue(BurrowConductor.shouldStreamViaConductor(command: "optimize"))
    }

    func testShouldStreamViaConductor_explicitlyOff_disablesStreaming() {
        UserDefaults.standard.set(false, forKey: "BurrowStreamViaConductor")
        defer { UserDefaults.standard.removeObject(forKey: "BurrowStreamViaConductor") }
        XCTAssertFalse(BurrowConductor.shouldStreamViaConductor(command: "clean"))
        XCTAssertFalse(BurrowConductor.shouldStreamViaConductor(command: "optimize"))
    }

    func testShouldStreamViaConductor_onlyClean_andOptimize_whenSwitchIsOn() {
        UserDefaults.standard.set(true, forKey: "BurrowStreamViaConductor")
        defer { UserDefaults.standard.removeObject(forKey: "BurrowStreamViaConductor") }
        XCTAssertTrue(BurrowConductor.shouldStreamViaConductor(command: "clean"))
        XCTAssertTrue(BurrowConductor.shouldStreamViaConductor(command: "optimize"))
        // purge/installer are the interactive PTY flow; uninstall is matcher-gated — neither is
        // ever streamed, switch on or off.
        XCTAssertFalse(BurrowConductor.shouldStreamViaConductor(command: "purge"))
        XCTAssertFalse(BurrowConductor.shouldStreamViaConductor(command: "installer"))
        XCTAssertFalse(BurrowConductor.shouldStreamViaConductor(command: "uninstall"))
    }

    // `shouldStreamViaConductor`/`streamOverride` deliberately take no `elevated` parameter at
    // all — see `shouldStreamViaConductor`'s doc for why. Before this change, a `!elevated` guard
    // meant `CleanView`/`TuneUpView`'s real clean/optimize (the app's ONLY GUI callers of
    // `.moleStream`, both always `elevated: true`) never received the mo→engine argv translation:
    // every actual Clean/Optimize button fell through to the direct-engine path with untranslated
    // argv, which the engine reads with inverted dry-run/apply meaning. There is no elevated-vs-
    // not variant of `shouldStreamViaConductor` to test — the absence of the parameter IS the
    // regression guard; a future edit would have to deliberately re-add it to reintroduce the bug.

    func testStreamOverride_offByDefault_keepsDirectEngine() {
        XCTAssertNil(BurrowConductor.streamOverride(moArgs: ["clean"]))
    }
}
