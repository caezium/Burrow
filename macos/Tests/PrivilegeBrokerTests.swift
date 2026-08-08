//
//  PrivilegeBrokerTests.swift
//  BurrowTests
//
//  Boundary tests for the elevated path (issue #48) — the code that runs
//  commands as ROOT, and that no test could previously reach because it
//  spawned a real osascript auth dialog inline.
//
//  Two pure pieces are exercised in memory, with NO osascript, NO sudo, NO GUI:
//    * `AuthCancel` — the rule that decides a dismissed auth prompt vs a
//      command that ran and failed. Shared by the streaming runner
//      (SystemProcessPort.finalEvent) and the one-shot broker, so it's
//      table-tested exhaustively here.
//    * `MoleCLI.elevatedScript` — the two-pass quoter whose output runs as
//      root inside `do shell script`. The injection cases at the bottom are
//      the quoting that, if it broke, would delete the wrong files.
//
//  The scripted-fake broker tests that used to live here went with
//  `MoleCLI.runElevated`/`runElevatedClassified`, deleted once the
//  `mo touchid` setting (their only caller) was removed. `PrivilegeBroker`
//  itself is still live — Connectivity's flush-DNS / renew-DHCP fixes use
//  `SystemPrivilegeBroker.openElevated` — but it is constructed directly at
//  that call site, so there is no injection seam left to drive a fake through.
//

import XCTest
@testable import Burrow

final class PrivilegeBrokerTests: XCTestCase {

    override func tearDown() {
        MoleCLI.discoveryCandidates = nil
        MoleCLI.resetDiscoveryCache()
        super.tearDown()
    }

    // MARK: - Auth-cancel rule (the one engine taxonomy, exhaustive table)
    //
    // "elevated + nonzero exit + produced nothing = dismissed prompt." Output
    // proves the command actually ran under root, so it's a real failure, not
    // a cancel. All four cells of elevated × output, plus exit-code edges.

    func testAuthCancel_classifiesDismissedPrompt() {
        // elevated, failed, silent → cancel.
        XCTAssertTrue(AuthCancel.isAuthCancelled(elevated: true, exitCode: 1, sawOutput: false))
        XCTAssertTrue(AuthCancel.isAuthCancelled(elevated: true, exitCode: -128, sawOutput: false))
    }

    func testAuthCancel_outputMeansRealFailure() {
        // The command printed → it ran; a nonzero exit is its own failure.
        XCTAssertFalse(AuthCancel.isAuthCancelled(elevated: true, exitCode: 1, sawOutput: true))
    }

    func testAuthCancel_unelevatedNeverCancels() {
        // No elevation = no auth prompt to dismiss.
        XCTAssertFalse(AuthCancel.isAuthCancelled(elevated: false, exitCode: 1, sawOutput: false))
        XCTAssertFalse(AuthCancel.isAuthCancelled(elevated: false, exitCode: 1, sawOutput: true))
    }

    func testAuthCancel_successIsNeverCancel() {
        // Exit 0 is success even when silent.
        XCTAssertFalse(AuthCancel.isAuthCancelled(elevated: true, exitCode: 0, sawOutput: false))
        XCTAssertFalse(AuthCancel.isAuthCancelled(elevated: true, exitCode: 0, sawOutput: true))
    }

    func testAuthCancel_outcomeMapsThePredicate() {
        // The one-shot helper folds the predicate into the named outcome.
        XCTAssertEqual(AuthCancel.outcome(exitCode: 1, sawOutput: false), .authCancelled)
        XCTAssertEqual(AuthCancel.outcome(exitCode: 1, sawOutput: true), .exited(1))
        XCTAssertEqual(AuthCancel.outcome(exitCode: 0, sawOutput: false), .exited(0))
        XCTAssertEqual(AuthCancel.outcome(exitCode: 5, sawOutput: true), .exited(5))
    }

    /// The streaming runner and the one-shot broker must agree on the rule —
    /// they share `AuthCancel`, so the same inputs land the same way through
    /// both surfaces. Guards against the two paths drifting apart again.
    func testAuthCancel_streamingAndOneShotAgree() {
        for (code, output) in [(Int32(1), false), (Int32(1), true), (Int32(0), false), (Int32(2), true)] {
            let stream = SystemProcessPort.finalEvent(exitCode: code, elevated: true, sawOutput: output)
            let oneShot = AuthCancel.outcome(exitCode: code, sawOutput: output)
            switch (stream, oneShot) {
            case (.authCancelled, .authCancelled):
                break
            case (.exited(let a), .exited(let b)):
                XCTAssertEqual(a, b)
            default:
                XCTFail("streaming and one-shot disagreed for exit \(code), output \(output)")
            }
        }
    }

    // MARK: - ElevatedOutcome back-compat (the preserved Int32 contract)
    //
    // The Int32 shim still backs `Connectivity.run`; both failure
    // shapes must collapse to a nonzero code, exactly as the old inline
    // spawn did (catch → 1, no trusted mo → 127).

    func testElevatedOutcome_exitCodeShim() {
        XCTAssertEqual(ElevatedOutcome.exited(0).exitCode, 0)
        XCTAssertEqual(ElevatedOutcome.exited(3).exitCode, 3)
        XCTAssertNotEqual(ElevatedOutcome.authCancelled.exitCode, 0, "a dismissed prompt is a failure to callers")
        XCTAssertEqual(ElevatedOutcome.launchFailed.exitCode, 127, "matches the old 'no trusted mo' sentinel")
    }

    // MARK: - osascript spec quoting through the broker (injection cases)
    //
    // The string the broker builds runs as ROOT inside `do shell script …`.
    // `SystemPrivilegeBroker` composes it via `MoleCLI.elevatedScript`; these
    // assert the dangerous inputs ride INERT — the quoting that, if it broke,
    // would delete the wrong files. (The builder itself is unit-tested in
    // MoleCLITests; here we pin the broker→builder wiring for real argv.)

    func testElevatedScript_brokerComposesInertRootInvocation() {
        // A path with spaces + args with shell metacharacters: every element
        // single-quoted, the whole thing AppleScript-escaped.
        let script = MoleCLI.elevatedScript(executable: "/opt/home brew/bin/mo",
                                            args: ["clean", "path with 'quotes'", "$(rm -rf /)"])
        XCTAssertTrue(script.hasPrefix("do shell script \""))
        XCTAssertTrue(script.hasSuffix("\" with administrator privileges"))
        // Command substitution stays a literal string, never executes.
        XCTAssertTrue(script.contains("'$(rm -rf /)'"),
                      "metacharacters must ride inert inside single quotes")
        // A single quote in an arg goes through the shell's '\'' dance, whose
        // backslash is then AppleScript-escaped (\\).
        XCTAssertTrue(script.contains(#"'path with '\\''quotes'\\'''"#))
    }

    func testElevatedScript_neutralizesNewlineAndBacktick() {
        let script = MoleCLI.elevatedScript(executable: "/usr/local/bin/mo",
                                            args: ["uninstall", "a\nb", "`whoami`"])
        XCTAssertTrue(script.contains("'`whoami`'"), "backticks inert in single quotes")
        // A newline survives inside the single-quoted arg (no statement break).
        XCTAssertTrue(script.contains("'a\nb'"))
    }
}
