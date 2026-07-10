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

    func testConductorEnvironment_pointsAtBundledEngine() {
        let dir = URL(fileURLWithPath: "/Applications/Burrow.app/Contents/Resources/engine")
        let env = BurrowConductor.environment(engineDir: dir)
        XCTAssertEqual(env["BURROW_ENGINE_DIR"], dir.path)
    }

    func testConductorEnvironment_nilEngineDirLeavesItUnset() {
        // A build without a bundled engine sets no override — the conductor resolves on its own.
        XCTAssertNil(BurrowConductor.environment(engineDir: nil)["BURROW_ENGINE_DIR"])
    }

    // MARK: streaming argv translation (safety-critical: mo↔burrow dry-run/apply INVERSION)

    func testStreamArgv_preview_dropsDryRun_neverApply() {
        // mo preview (`clean --dry-run`) maps to burrow's DEFAULT (dry-run) — must NOT gain
        // --apply, or a "preview" would delete for real.
        XCTAssertEqual(BurrowConductor.streamArgv(fromMo: ["clean", "--dry-run"]),
                       ["clean", "--stream"])
    }

    func testStreamArgv_live_addsApply() {
        // mo live (`clean`, no --dry-run) needs --apply on burrow — or a real clean would silently
        // no-op (burrow defaults to dry-run).
        XCTAssertEqual(BurrowConductor.streamArgv(fromMo: ["clean"]),
                       ["clean", "--apply", "--stream"])
        XCTAssertEqual(BurrowConductor.streamArgv(fromMo: ["optimize"]),
                       ["optimize", "--apply", "--stream"])
    }

    func testStreamOverride_offByDefault_keepsDirectEngine() {
        // The switch is off unless explicitly set → no override, the direct mo path is preserved.
        XCTAssertNil(BurrowConductor.streamOverride(moArgs: ["clean"], elevated: false))
    }

    func testStreamOverride_elevatedAlwaysDirect() {
        UserDefaults.standard.set(true, forKey: "BurrowStreamViaConductor")
        defer { UserDefaults.standard.removeObject(forKey: "BurrowStreamViaConductor") }
        // Elevated runs (osascript, fresh env) stay on mo even with the switch on.
        XCTAssertNil(BurrowConductor.streamOverride(moArgs: ["clean"], elevated: true))
    }
}
