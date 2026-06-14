//
//  MoEngineTests.swift
//  BurrowTests
//
//  Boundary tests for the unified runner facade (issue #48, slice 2). The
//  capture + elevated + discovery entry points all delegate to injected ports,
//  so they're driven here with scripted fakes — same seam style as
//  MoleProcessTests (capture port) and PrivilegeBrokerTests (elevation port).
//
//  The point of these tests is the WIRING: that a `MoCommand` lands on the
//  capture runner as the exact argv/stdin/env/timeout it described, that a
//  `.mo` target resolves through the locator (and degrades to a clean nonzero
//  exit when `mo` is missing), and that the elevated path routes the TRUSTED
//  binary to the broker — never a PATH lookup.
//

import XCTest
@testable import Burrow

final class MoEngineTests: XCTestCase {
    private enum FakeError: Error { case launchFailed }

    // MARK: - Scripted ports

    /// Records the capture call and replays a canned result (or throws).
    private final class FakeCapturePort: MoleProcessPort {
        var result = MoleProcessResult(stdout: "", stderr: "", exitCode: 0)
        var error: Error?

        private(set) var receivedExecutable: String?
        private(set) var receivedArgs: [String]?
        private(set) var receivedStdin: String?
        private(set) var receivedEnvironment: [String: String]?
        private(set) var receivedTimeout: TimeInterval?

        func capture(executable: String,
                     args: [String],
                     stdin: String?,
                     environment: [String: String]?,
                     timeout: TimeInterval) throws -> MoleProcessResult {
            receivedExecutable = executable
            receivedArgs = args
            receivedStdin = stdin
            receivedEnvironment = environment
            receivedTimeout = timeout
            if let error { throw error }
            return result
        }
    }

    /// Canned discovery: the normal lookup and the trusted-only lookup are
    /// separately settable so a test can prove the elevated path takes the
    /// trusted one.
    private struct FakeLocator: MoLocator {
        var located: String?
        var trusted: String?
        func locate() -> String? { located }
        func locateTrusted() -> String? { trusted }
    }

    /// In-memory stand-in for osascript: records the elevated (exe, args) and
    /// replays a canned outcome — no auth dialog.
    private final class FakeBroker: PrivilegeBroker, @unchecked Sendable {
        private(set) var calls: [(executable: String, args: [String])] = []
        var outcome: ElevatedOutcome
        init(outcome: ElevatedOutcome) { self.outcome = outcome }
        func openElevated(executable: String, args: [String]) -> ElevatedOutcome {
            calls.append((executable, args))
            return outcome
        }
    }

    // MARK: - capture: command → port wiring

    func testCapture_resolvesMoTargetThroughLocatorAndForwardsTheCommand() throws {
        let port = FakeCapturePort()
        port.result = MoleProcessResult(stdout: "out", stderr: "err", exitCode: 0)
        let engine = MoEngine(processPort: port,
                              locator: FakeLocator(located: "/fake/bin/mo"))

        let captured = try engine.capture(MoCommand(
            target: .mo,
            args: ["status", "--json"],
            stdin: "y\n",
            environment: ["PATH": "/tmp"],
            timeout: 8))

        // The result maps field-for-field from the port's MoleProcessResult.
        XCTAssertEqual(captured.stdout, "out")
        XCTAssertEqual(captured.stderr, "err")
        XCTAssertEqual(captured.exitCode, 0)
        // The discovered path, args, stdin, env, and timeout reach the runner
        // unchanged — behavior-preserving translation of the old MoleCLI.run.
        XCTAssertEqual(port.receivedExecutable, "/fake/bin/mo")
        XCTAssertEqual(port.receivedArgs, ["status", "--json"])
        XCTAssertEqual(port.receivedStdin, "y\n")
        XCTAssertEqual(port.receivedEnvironment, ["PATH": "/tmp"])
        XCTAssertEqual(port.receivedTimeout, 8)
    }

    func testCapture_explicitExecutableTargetBypassesDiscovery() throws {
        let port = FakeCapturePort()
        // A locator that would resolve a different mo — proving the explicit
        // path (the brew straggler's shape) wins.
        let engine = MoEngine(processPort: port,
                              locator: FakeLocator(located: "/fake/bin/mo"))

        _ = try engine.capture(MoCommand(
            target: .executable("/opt/homebrew/bin/brew"),
            args: ["outdated", "--json=v2"],
            timeout: 120))

        XCTAssertEqual(port.receivedExecutable, "/opt/homebrew/bin/brew")
        XCTAssertEqual(port.receivedArgs, ["outdated", "--json=v2"])
    }

    func testCapture_unresolvedMoFallsBackToFalseForACleanNonzeroExit() throws {
        // The locator misses (mo not installed). The facade must NOT throw —
        // it runs /usr/bin/false so the run degrades to a nonzero exit, exactly
        // the way MoleCLI.run did. Uses the REAL capture port for the actual
        // exit code.
        let engine = MoEngine(locator: FakeLocator(located: nil))

        let captured = try engine.capture(MoCommand(target: .mo, args: ["status"], timeout: 5))

        XCTAssertNotEqual(captured.exitCode, 0, "a missing mo degrades to a nonzero exit, not a crash")
    }

    func testCapture_propagatesLaunchFailureFromPort() {
        let port = FakeCapturePort()
        port.error = FakeError.launchFailed
        let engine = MoEngine(processPort: port,
                              locator: FakeLocator(located: "/fake/bin/mo"))

        XCTAssertThrowsError(try engine.capture(MoCommand(target: .mo, args: [])))
    }

    func testCapture_carriesTimedOutFlagThrough() throws {
        let port = FakeCapturePort()
        port.result = MoleProcessResult(stdout: "", stderr: "", exitCode: 15, timedOut: true)
        let engine = MoEngine(processPort: port,
                              locator: FakeLocator(located: "/fake/bin/mo"))

        let captured = try engine.capture(MoCommand(target: .mo, args: ["analyze"], timeout: 1))

        // Issue #48: a timeout says so — the flag rides through the facade so a
        // caller can tell a kill apart from a genuine nonzero exit.
        XCTAssertTrue(captured.timedOut)
        XCTAssertEqual(captured.exitCode, 15)
    }

    func testCapture_defaultTimeoutMatchesTheOldTenSecondDefault() throws {
        let port = FakeCapturePort()
        let engine = MoEngine(processPort: port,
                              locator: FakeLocator(located: "/fake/bin/mo"))

        _ = try engine.capture(MoCommand(target: .mo, args: []))

        XCTAssertEqual(port.receivedTimeout, 10, "unspecified timeout preserves MoleCLI.run's 10s default")
    }

    /// End-to-end through the REAL capture port with a tiny system binary, the
    /// same local-substitutable style MoleCLITests uses for the runner.
    func testCapture_capturesEchoThroughTheRealPort() throws {
        let engine = MoEngine()
        let captured = try engine.capture(MoCommand(
            target: .executable("/bin/echo"), args: ["hello world"]))

        XCTAssertEqual(captured.exitCode, 0)
        XCTAssertEqual(captured.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello world")
    }

    // MARK: - Discovery availability

    func testAvailability_installedReportsTheLocatedPath() {
        let engine = MoEngine(locator: FakeLocator(located: "/fake/bin/mo"))
        XCTAssertEqual(engine.availability(), .installed(path: "/fake/bin/mo"))
    }

    func testAvailability_missingWhenLocatorFindsNothing() {
        let engine = MoEngine(locator: FakeLocator(located: nil))
        XCTAssertEqual(engine.availability(), .missing)
    }

    // MARK: - Elevated one-shot

    func testRunElevatedClassified_routesTrustedBinaryToTheBroker() {
        let broker = FakeBroker(outcome: .exited(0))
        // The normal lookup points one place; the elevated path must use the
        // TRUSTED lookup — never PATH — so a shadowed binary can't get root.
        let engine = MoEngine(privilegeBroker: broker,
                              locator: FakeLocator(located: "/untrusted/mo",
                                                   trusted: "/opt/homebrew/bin/mo"))

        let outcome = engine.runElevatedClassified(args: ["touchid", "enable"])

        XCTAssertEqual(outcome, .exited(0))
        XCTAssertEqual(broker.calls.count, 1)
        XCTAssertEqual(broker.calls.first?.executable, "/opt/homebrew/bin/mo",
                       "elevated runs resolve through the trusted list, never the normal lookup")
        XCTAssertEqual(broker.calls.first?.args, ["touchid", "enable"])
    }

    func testRunElevatedClassified_noTrustedBinaryIsLaunchFailedAndNeverReachesTheBroker() {
        let broker = FakeBroker(outcome: .exited(0))
        let engine = MoEngine(privilegeBroker: broker,
                              locator: FakeLocator(located: "/untrusted/mo", trusted: nil))

        XCTAssertEqual(engine.runElevatedClassified(args: ["touchid", "enable"]), .launchFailed)
        XCTAssertTrue(broker.calls.isEmpty, "a missing trusted mo must never reach the elevation spawn")
    }

    func testRunElevatedClassified_authCancelIsDistinctFromCommandFailure() {
        let cancel = MoEngine(privilegeBroker: FakeBroker(outcome: .authCancelled),
                              locator: FakeLocator(trusted: "/opt/homebrew/bin/mo"))
        XCTAssertEqual(cancel.runElevatedClassified(args: ["touchid", "enable"]), .authCancelled)

        let failed = MoEngine(privilegeBroker: FakeBroker(outcome: .exited(2)),
                              locator: FakeLocator(trusted: "/opt/homebrew/bin/mo"))
        XCTAssertEqual(failed.runElevatedClassified(args: ["touchid", "disable"]), .exited(2))
    }
}
