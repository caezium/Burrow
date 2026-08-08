//
//  EngineFailureChannelTests.swift
//  BurrowTests
//
//  The repoint moved WHERE a failure is reported, and the app kept reading the old channel.
//
//  The legacy Go/bash `mo` wrote its diagnosis to STDERR and exited non-zero. The Rust engine
//  reports every failure it classifies as an `ok:false` envelope on STDOUT and writes NOTHING to
//  stderr — measured against burrow-engine @ 945000a with the two streams captured separately:
//
//      analyze /nonexistent   exit=1  stdout=193B  stderr=0B
//      dupes   /nonexistent   exit=1  stdout=370B  stderr=0B
//      status  --bogus        exit=2  stdout=165B  stderr=0B
//      bogus-cmd              exit=2  stdout=164B  stderr=0B
//
//  So `DiskScanner` threw `moFailed(exitCode:stderr:)` and the user read "mo analyze exited 2:"
//  with nothing after the colon, while the message sat in the stdout the code had just thrown
//  away. Nine other call sites made the same assumption.
//
//  Every fixture below is a VERBATIM copy of a golden captured from the real binary — source of
//  truth `plans/repoint-redo-groundtruth/engine-error*.golden.json`, re-capture recipe and the
//  stderr byte counts in `engine-error.golden.provenance.txt` beside them. (§3e wants the golden
//  loaded rather than retyped; the Swift test target has no resource for these, so this follows
//  the existing Swift-side convention in `MoleStatusDecodeTests` — embed the bytes, name the file
//  they came from, re-capture there first.) Two DISTINCT classified kinds are covered because
//  `error` is the engine's fallthrough bucket and a suite that only ever saw it would not notice
//  the field disappearing.
//
//  Three properties are load-bearing here, and each has a test that fails if it breaks:
//    1. the reason a user or agent sees is the engine's `error.message`, not an empty string;
//    2. a shape that is NOT an envelope (a legacy `mo`, or its bare `--json`) is untouched —
//       neither mistaken for a failure nor robbed of its stderr diagnosis;
//    3. nothing that reads an envelope turns a failure into a success.
//

import XCTest
@testable import Burrow

final class EngineFailureChannelTests: XCTestCase {

    // MARK: - Fixtures, verbatim from the engine

    /// `burrow-engine analyze /nonexistent --json` → exit 1, stderr 0 bytes.
    private let analyzeMissing = #"{"ok":false,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"analyze","error":{"kind":"error","message":"scan /nonexistent: No such file or directory (os error 2)","platform":"macos"}}"#

    /// `burrow-engine dupes /nonexistent --json` → exit 1, stderr 0 bytes. A second, DIFFERENT
    /// classified kind, whose message also happens to carry embedded newlines (it quotes the
    /// fclones sidecar's own transcript).
    private let dupesMissing = #"{"ok":false,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"dupes","error":{"kind":"process_failed","message":"fclones group exited exit status: 1: [2026-08-07 23:36:00.636] fclones: error: Can't access /nonexistent: No such file or directory (os error 2)\n[2026-08-07 23:36:00.638] fclones: error: Some input paths could not be accessed.","platform":"macos"}}"#

    /// `burrow-engine status --bogus --json` → exit 2, stderr 0 bytes.
    private let statusBogus = #"{"ok":false,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"status","error":{"kind":"error","message":"unknown status option: --bogus","platform":"macos"}}"#

    /// `burrow-engine analyze <fixture> --json` → exit 0. The payload the app's decoders want is
    /// `data`, NOT the envelope's own top level.
    private let analyzeSuccess = #"{"ok":true,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"analyze","data":{"path":"/tmp/burrow-envelope-fixture","overview":false,"entries":[{"name":"sub","path":"/tmp/burrow-envelope-fixture/sub","size":8192,"is_dir":true},{"name":"a.bin","path":"/tmp/burrow-envelope-fixture/a.bin","size":4096,"is_dir":false,"last_access":"2026-08-08T06:36:00Z"}],"total_size":12288,"total_files":2}}"#

    /// What a legacy `mo --json` answers: the payload bare, with no envelope around it. The
    /// shape that must survive every change here untouched.
    private let legacyBareAnalyze = #"{"path":"/Users/x","total_size":4096,"total_files":1,"entries":[{"name":"a","path":"/Users/x/a","size":4096,"is_dir":false}]}"#

    // MARK: - failureReason: the reason exists, on whichever channel it lives

    func testFailureReason_engineFailure_readsTheEnvelopeMessageNotTheEmptyStderr() throws {
        // The exact call the fixed DiskScanner makes: stderr is empty, as the engine leaves it.
        let reason = try XCTUnwrap(BurrowEnvelope.failureReason(stdout: analyzeMissing, stderr: ""))
        XCTAssertEqual(reason, "scan /nonexistent: No such file or directory (os error 2)")
    }

    func testFailureReason_secondClassifiedKind_readsItToo() throws {
        let reason = try XCTUnwrap(BurrowEnvelope.failureReason(stdout: dupesMissing, stderr: ""))
        XCTAssertTrue(reason.hasPrefix("fclones group exited exit status: 1:"), reason)
        XCTAssertTrue(reason.contains("Can't access /nonexistent"), reason)
    }

    func testFailureReason_legacyMo_stillReadsStderr() throws {
        // No envelope at all → the mo-family diagnosis on stderr is the only reason there is,
        // and it must keep coming through. ANSI decoration is stripped, as mo emits it.
        let reason = try XCTUnwrap(BurrowEnvelope.failureReason(
            stdout: "", stderr: "\u{1B}[31manalyzer error: permission denied\u{1B}[0m"))
        XCTAssertEqual(reason, "analyzer error: permission denied")
    }

    func testFailureReason_legacyMoThatComplainsOnStdout_fallsThroughToIt() throws {
        // The fallback `SoftwareView`'s uninstall alert already had, and the reason it was the
        // one site that kept saying something through the repoint.
        let reason = try XCTUnwrap(BurrowEnvelope.failureReason(
            stdout: "Error: no such app\n", stderr: ""))
        XCTAssertEqual(reason, "Error: no such app")
    }

    func testFailureReason_bothStreamsSilent_isNilSoCallersCanSaySo() {
        XCTAssertNil(BurrowEnvelope.failureReason(stdout: "", stderr: "   \n "),
                     "nil, so a caller prints \"no error output\" instead of an empty reason")
    }

    func testFailureKind_classifiesPerFixture_andIsNilForNonEngineShapes() {
        XCTAssertEqual(BurrowEnvelope.failureKind(stdout: analyzeMissing), "error")
        XCTAssertEqual(BurrowEnvelope.failureKind(stdout: dupesMissing), "process_failed")
        XCTAssertEqual(BurrowEnvelope.failureKind(stdout: statusBogus), "error")
        XCTAssertNil(BurrowEnvelope.failureKind(stdout: analyzeSuccess), "a success has no kind")
        XCTAssertNil(BurrowEnvelope.failureKind(stdout: legacyBareAnalyze), "legacy mo has no kinds")
    }

    // MARK: - The discriminator: `burrow_cli`, not "did JSON parse"

    func testReportsFailure_onlyForARealFailureEnvelope() {
        XCTAssertTrue(BurrowEnvelope.reportsFailure(stdout: analyzeMissing))
        XCTAssertTrue(BurrowEnvelope.reportsFailure(stdout: dupesMissing))
        XCTAssertFalse(BurrowEnvelope.reportsFailure(stdout: analyzeSuccess))
        XCTAssertFalse(BurrowEnvelope.reportsFailure(stdout: ""))
        XCTAssertFalse(BurrowEnvelope.reportsFailure(stdout: "not json at all"))
    }

    /// The trap the whole helper is built around: `BurrowEnvelope.parse` succeeds on ANY JSON
    /// object, so a legacy payload parses into an envelope whose `ok` merely DEFAULTED to false.
    /// Anything that used `parse` alone would read a perfectly good legacy result as a failed
    /// run — and, at the `ran`/`ok` call sites, as a failed uninstall or a skipped tick.
    func testReportsFailure_legacyBarePayload_isNotAFailure() {
        XCTAssertFalse(BurrowEnvelope.reportsFailure(stdout: legacyBareAnalyze),
                       "a bare mo payload has no `ok` key — that is not the same as ok:false")
        XCTAssertFalse(BurrowEnvelope.reportsFailure(stdout: #"{"sessions":[]}"#))
        XCTAssertNil(BurrowEnvelope.inOutput(legacyBareAnalyze),
                     "`burrow_cli` is the discriminator, and legacy mo never emits it")
    }

    // MARK: - payloadBytes: unwrap the engine, pass legacy through, refuse a failure

    func testPayloadBytes_successEnvelope_unwrapsToDataNotTheEnvelopeItself() throws {
        let bytes = try XCTUnwrap(BurrowEnvelope.payloadBytes(stdout: analyzeSuccess))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        // Reading the envelope's own top level found none of these — which is how an analyze
        // came back as a directory with no children instead of as an error.
        XCTAssertEqual(obj["path"] as? String, "/tmp/burrow-envelope-fixture")
        XCTAssertEqual(obj["total_size"] as? Int, 12288)
        XCTAssertEqual((obj["entries"] as? [[String: Any]])?.count, 2)
        XCTAssertNil(obj["ok"], "the envelope wrapper must not survive into the payload")
    }

    func testPayloadBytes_failureEnvelope_isNilSoNobodyDecodesAnErrorAsAPayload() {
        XCTAssertNil(BurrowEnvelope.payloadBytes(stdout: analyzeMissing))
        XCTAssertNil(BurrowEnvelope.payloadBytes(stdout: statusBogus))
    }

    func testPayloadBytes_legacyBarePayload_passesThroughByteForByte() throws {
        let bytes = try XCTUnwrap(BurrowEnvelope.payloadBytes(stdout: legacyBareAnalyze))
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), legacyBareAnalyze)
    }

    // MARK: - DiskScanner: the reported bug, and the legacy diagnosis that must survive

    func testDiskScanFailure_namesTheEngineReason_notAnEmptyStringAfterAColon() throws {
        let reason = BurrowEnvelope.failureReason(stdout: analyzeMissing, stderr: "")
        let msg = try XCTUnwrap(DiskScanError.moFailed(exitCode: 1, reason: reason).errorDescription)
        XCTAssertTrue(msg.contains("No such file or directory"), msg)
        XCTAssertFalse(msg.hasSuffix(":"), "the exact symptom: a colon with nothing after it — \(msg)")
    }

    func testDiskScanFailure_genuinelySilentRun_saysSoRatherThanTrailingOff() throws {
        let msg = try XCTUnwrap(DiskScanError.moFailed(exitCode: 2, reason: nil).errorDescription)
        XCTAssertTrue(msg.contains("no error output"), msg)
    }

    /// `indicatesMissingJSONSupport` is a diagnosis about a mo-family binary and must stay one.
    /// It keeps matching the two Go/TUI strings on stderr; it must NOT start matching the
    /// engine, because "too old" is meaningless across the two version scales and would send a
    /// user on the bundled engine to `brew upgrade mole` — a program they do not have.
    func testMissingJSONSupport_stillDiagnosesALegacyMo() {
        XCTAssertTrue(DiskScanner.indicatesMissingJSONSupport(
            stderr: "analyzer error: could not open a new TTY: open /dev/tty: device not configured"))
        XCTAssertTrue(DiskScanner.indicatesMissingJSONSupport(
            stderr: "flag provided but not defined: -json"))
    }

    func testMissingJSONSupport_cannotFireForTheEngine() {
        // What the engine actually leaves on stderr for each fixture: nothing.
        XCTAssertFalse(DiskScanner.indicatesMissingJSONSupport(stderr: ""))
        // And it stays a stderr-only question — handed the engine's own failure envelope it
        // still says no, so the guard at the call sites is belt to that braces rather than the
        // only thing standing between a bundled-engine user and "run `brew upgrade mole`".
        XCTAssertFalse(DiskScanner.indicatesMissingJSONSupport(stderr: analyzeMissing))
        XCTAssertFalse(DiskScanner.indicatesMissingJSONSupport(stderr: statusBogus))
    }

    // MARK: - MCP: the reason reaches an agent as a field, not buried in a string

    func testAnalyzeFailure_carriesReasonAndKind_andKeepsTheStderrFieldHonest() throws {
        let json = ToolCatalog.analyzeFailure(path: "/nonexistent", stdout: analyzeMissing, stderr: "")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["reason"] as? String,
                       "scan /nonexistent: No such file or directory (os error 2)")
        XCTAssertEqual(obj["kind"] as? String, "error")
        XCTAssertEqual(obj["error"] as? String, "mo analyze failed")
        XCTAssertEqual(obj["stderr"] as? String, "", "kept in the shape, and honestly empty")
        XCTAssertNil(obj["entries"], "a failure must never carry an entry list beside it")
    }

    func testAnalyzeFailure_legacyMo_reasonComesFromStderr() throws {
        let json = ToolCatalog.analyzeFailure(path: "/x", stdout: "", stderr: "permission denied")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["reason"] as? String, "permission denied")
        XCTAssertNil(obj["kind"], "legacy mo has no classified kind to report")
    }

    /// The exit code is not the whole test. An `ok:false` body that somehow exits 0 is still a
    /// failure, and must not be passed through where an agent expects the app inventory.
    func testListApps_zeroExitButFailureEnvelope_isStillAnError_andNeverAnEmptyAppsList() throws {
        let json = ToolCatalog.listAppsToolResult(exitCode: 0, stdout: analyzeMissing, stderr: "")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertNotNil(obj["error"])
        XCTAssertEqual(obj["reason"] as? String,
                       "scan /nonexistent: No such file or directory (os error 2)")
        XCTAssertNil(obj["apps"], "an agent reading .apps without checking .error must not find "
                     + "an empty array that reads as \"no apps installed\"")
    }

    /// The other direction, and the one that would be a regression: `uninstall --list` answers
    /// with a BARE JSON array — one of the engine's un-enveloped commands — so a real listing
    /// must still pass through untouched.
    func testListApps_realBareArrayListing_stillPassesThroughVerbatim() {
        let listing = #"[{"name":"Slack","bundle_id":"com.tinyspeck.slackmacgap","path":"/Applications/Slack.app","size":"250MB"}]"#
        XCTAssertEqual(ToolCatalog.listAppsToolResult(exitCode: 0, stdout: listing, stderr: ""), listing)
    }

    // MARK: - The wire format: additive, and no failure dressed as a success

    func testWire_resultWithoutAnError_isUnchangedByteForByte() {
        // The additive fields must be ABSENT on every existing payload, or every golden in
        // MoActionsTests is silently rewritten.
        let json = ActionWire.result(command: "clean", dryRun: true, ran: false,
                                     exitCode: 0, output: "ok")
        XCTAssertEqual(json, #"{"command":"clean","dry_run":true,"exit_code":0,"output":"ok","ran":false}"#)
    }

    func testWire_failedRun_carriesTheEngineReason_andStillSaysItDidNotRun() throws {
        let json = ActionWire.result(command: "clean", dryRun: false, ran: false, exitCode: 1,
                                     output: analyzeMissing,
                                     error: BurrowEnvelope.failureReason(stdout: analyzeMissing, stderr: ""),
                                     kind: BurrowEnvelope.failureKind(stdout: analyzeMissing))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["error"] as? String,
                       "scan /nonexistent: No such file or directory (os error 2)")
        XCTAssertEqual(obj["kind"] as? String, "error")
        XCTAssertEqual(obj["ran"] as? Bool, false, "a run that failed did not run")
    }

    func testWire_uninstallAbort_engineErrorIsAdditive_andNeverFlipsRan() throws {
        let plain = ActionWire.uninstallAbort(apps: ["Slack"], reason: "nothing was removed")
        XCTAssertFalse(plain.contains("engine_error"), "absent unless the dry run itself failed")

        let json = ActionWire.uninstallAbort(apps: ["Slack"], reason: "nothing was removed",
                                             engineError: "No matching applications found. (Slack)")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["engine_error"] as? String, "No matching applications found. (Slack)")
        XCTAssertEqual(obj["ran"] as? Bool, false)
        XCTAssertNotNil(obj["error"], "the abort still says why it aborted")
    }

    /// The pre-flight is a DECISION point, and OPENING it must not have opened this hole with it.
    /// The engine keeps the oracle's exact "No matching applications found." wording, which is the
    /// one sentence the legacy text parser reads as an empty matched set — so fed engine JSON it
    /// used to answer `[]`, and the run failed closed only because `[]` then disagreed with a
    /// non-empty confirmed set. That coincidence is gone: the envelope is checked first, the two
    /// paths share no parsing, and the refusal is now reported as the engine's own refusal.
    func testUninstallPreflight_engineRefusal_isReadAsARefusalNotAsAnEmptyMatch() throws {
        let engineDryRunFailure = #"{"ok":false,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"uninstall","error":{"kind":"error","message":"No matching applications found. (NoSuchAppXYZ)","platform":"macos"}}"#
        XCTAssertNil(UninstallGuard.matchedApps(inDryRunOutput: engineDryRunFailure),
                     "an envelope is never a legacy matched set — nil, not []")
        guard case .engineRefused(let message) = UninstallGuard.readDryRun(stdout: engineDryRunFailure,
                                                                          stderr: "") else {
            return XCTFail("an ok:false envelope is the refusal case")
        }
        XCTAssertEqual(message, "No matching applications found. (NoSuchAppXYZ)")
        let reason = try XCTUnwrap(UninstallGuard.abortReason(
            confirmed: ["com.foo.Bar"],
            dryRun: UninstallGuard.readDryRun(stdout: engineDryRunFailure, stderr: "")))
        XCTAssertTrue(reason.contains("NoSuchAppXYZ"), reason)
        XCTAssertNil(UninstallGuard.matchedApps(inDryRunOutput: analyzeSuccess),
                     "a success envelope is not a matched set either")
    }
}
