//
//  PrivilegeBrokerTests.swift
//  BurrowTests
//
//  Boundary tests for the one-shot elevated path (issue #48) — the code that
//  runs `mo` as ROOT, and that no test could previously reach because it
//  spawned a real osascript auth dialog inline.
//
//  Two seams are exercised in memory, with NO osascript, NO sudo, NO GUI:
//    * `AuthCancel` — the pure rule that decides a dismissed auth prompt vs a
//      command that ran and failed. Shared by the streaming runner
//      (SystemProcessPort.finalEvent) and this one-shot broker, so it's
//      table-tested exhaustively here.
//    * `PrivilegeBroker` — the spawn port. A scripted fake stands in for
//      osascript, so `MoleCLI.runElevated`/`runElevatedClassified` can be
//      driven through every outcome (cancel, fail, success, launch-failure)
//      and the osascript spec quoting verified — the previously-untestable
//      ROOT path is now fully covered.
//

import XCTest
@testable import Burrow

// MARK: - Scripted fake broker

/// In-memory stand-in for osascript. Records the (executable, args) it was
/// asked to elevate so quoting/injection can be asserted, and replays a
/// canned outcome — no real process, no auth dialog.
final class FakePrivilegeBroker: PrivilegeBroker, @unchecked Sendable {
    private(set) var calls: [(executable: String, args: [String])] = []
    var outcome: ElevatedOutcome

    init(outcome: ElevatedOutcome) { self.outcome = outcome }

    func openElevated(executable: String, args: [String]) -> ElevatedOutcome {
        calls.append((executable, args))
        return outcome
    }
}

final class PrivilegeBrokerTests: XCTestCase {

    override func tearDown() {
        MoleCLI.privilegeBroker = SystemPrivilegeBroker()
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
    // `runElevated` still returns Int32 for existing callers; both failure
    // shapes must collapse to a nonzero code, exactly as the old inline
    // spawn did (catch → 1, no trusted mo → 127).

    func testElevatedOutcome_exitCodeShim() {
        XCTAssertEqual(ElevatedOutcome.exited(0).exitCode, 0)
        XCTAssertEqual(ElevatedOutcome.exited(3).exitCode, 3)
        XCTAssertNotEqual(ElevatedOutcome.authCancelled.exitCode, 0, "a dismissed prompt is a failure to callers")
        XCTAssertEqual(ElevatedOutcome.launchFailed.exitCode, 127, "matches the old 'no trusted mo' sentinel")
    }

    // MARK: - Broker routing through MoleCLI (in-memory, no osascript)
    //
    // `runElevated` resolves the binary through `trustedExecutable()` ONLY —
    // never `discoveryCandidates`/PATH, because a user-writable path entry
    // would hand root to a shadowed binary. So these tests can't inject a
    // fake `mo` path the way the capture-runner tests do; they assert the
    // invariant against whatever the trusted lookup actually resolves, and
    // skip the spawn-shape assertions when no trusted mo is installed (a
    // valid CI state — nil is the launch-failure path, covered separately).

    func testRunElevated_routesTrustedExecutableAndArgsToBroker() throws {
        guard let trusted = MoleCLI.trustedExecutable() else {
            throw XCTSkip("no trusted mo installed; spawn-routing shape needs one")
        }
        let fake = FakePrivilegeBroker(outcome: .exited(0))
        MoleCLI.privilegeBroker = fake

        let code = MoleCLI.runElevated(args: ["touchid", "enable"])

        XCTAssertEqual(code, 0)
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(fake.calls.first?.executable, trusted,
                       "elevated runs resolve through the trusted list, never PATH")
        XCTAssertEqual(fake.calls.first?.args, ["touchid", "enable"])
    }

    func testRunElevated_authCancelSurfacesAsNonzeroButClassified() throws {
        guard MoleCLI.trustedExecutable() != nil else {
            throw XCTSkip("no trusted mo installed; the broker is never reached")
        }
        MoleCLI.privilegeBroker = FakePrivilegeBroker(outcome: .authCancelled)

        // Legacy Int32 caller: a dismissed prompt is still "didn't work".
        XCTAssertNotEqual(MoleCLI.runElevated(args: ["touchid", "enable"]), 0)
        // New caller: the cancel is NAMED, distinct from a command failure.
        XCTAssertEqual(MoleCLI.runElevatedClassified(args: ["touchid", "enable"]), .authCancelled)
    }

    func testRunElevated_commandFailureIsDistinctFromCancel() throws {
        guard MoleCLI.trustedExecutable() != nil else {
            throw XCTSkip("no trusted mo installed; the broker is never reached")
        }
        MoleCLI.privilegeBroker = FakePrivilegeBroker(outcome: .exited(2))

        XCTAssertEqual(MoleCLI.runElevatedClassified(args: ["touchid", "disable"]), .exited(2))
        XCTAssertEqual(MoleCLI.runElevated(args: ["touchid", "disable"]), 2)
    }

    /// No trusted `mo` → the broker is never asked to elevate; the result is
    /// the launch-failure sentinel (127), matching the old `guard … else
    /// return 127`. Only assertable when the trusted lookup genuinely misses;
    /// where a real mo is installed the guard can't be forced (resolution is
    /// deliberately not injectable), so we assert the inverse there: the
    /// broker IS reached.
    func testRunElevated_noTrustedExecutableTakesLaunchFailurePath() {
        let fake = FakePrivilegeBroker(outcome: .exited(0))
        MoleCLI.privilegeBroker = fake

        if MoleCLI.trustedExecutable() == nil {
            XCTAssertEqual(MoleCLI.runElevatedClassified(args: ["touchid", "enable"]), .launchFailed)
            XCTAssertEqual(MoleCLI.runElevated(args: ["touchid", "enable"]), 127)
            XCTAssertTrue(fake.calls.isEmpty, "a missing trusted mo must never reach the elevation spawn")
        } else {
            _ = MoleCLI.runElevatedClassified(args: ["touchid", "enable"])
            XCTAssertFalse(fake.calls.isEmpty, "with a trusted mo, the broker is reached")
        }
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
