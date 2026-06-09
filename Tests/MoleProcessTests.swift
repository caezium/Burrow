//
//  MoleProcessTests.swift
//  BurrowTests
//

import XCTest
@testable import Burrow

final class MoleProcessTests: XCTestCase {
    private enum FakeError: Error {
        case launchFailed
    }

    private final class FakeMoleProcessPort: MoleProcessPort {
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

            if let error {
                throw error
            }
            return result
        }
    }

    override func tearDown() {
        MoleCLI.processPort = SystemMoleProcess()
        super.tearDown()
    }

    func testCapture_returnsCannedResultFromInjectedPort() throws {
        let fake = FakeMoleProcessPort()
        fake.result = MoleProcessResult(stdout: "out", stderr: "err", exitCode: 0)

        let result = try MoleProcess.capture(
            executable: "/bin/example",
            args: ["--flag"],
            environment: ["PATH": "/tmp"],
            timeout: 12,
            port: fake
        )

        XCTAssertEqual(result.stdout, "out")
        XCTAssertEqual(result.stderr, "err")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(fake.receivedExecutable, "/bin/example")
        XCTAssertEqual(fake.receivedArgs, ["--flag"])
        XCTAssertEqual(fake.receivedEnvironment, ["PATH": "/tmp"])
        XCTAssertEqual(fake.receivedTimeout, 12)
    }

    func testCapture_forwardsStdinToPort() throws {
        let fake = FakeMoleProcessPort()

        _ = try MoleProcess.capture(
            executable: "/bin/cat",
            args: [],
            stdin: "piped input\n",
            port: fake
        )

        XCTAssertEqual(fake.receivedStdin, "piped input\n")
    }

    func testCapture_passesThroughNonZeroExitAndStderr() throws {
        let fake = FakeMoleProcessPort()
        fake.result = MoleProcessResult(stdout: "", stderr: "boom", exitCode: 42)

        let result = try MoleProcess.capture(executable: "/usr/bin/false", args: [], port: fake)

        XCTAssertEqual(result.exitCode, 42)
        XCTAssertEqual(result.stderr, "boom")
    }

    func testCapture_propagatesLaunchFailureFromPort() {
        let fake = FakeMoleProcessPort()
        fake.error = FakeError.launchFailed

        XCTAssertThrowsError(try MoleProcess.capture(executable: "/missing", args: [], port: fake))
    }

    func testSystemCapture_timesOutWithNonZeroExitInsteadOfThrowing() throws {
        let start = Date()
        let result = try SystemMoleProcess().capture(
            executable: "/bin/sleep",
            args: ["5"],
            stdin: nil,
            environment: nil,
            timeout: 0.4
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 3.0, "the 5s sleep must be killed by the 0.4s timeout")
        XCTAssertNotEqual(result.exitCode, 0, "a terminated process is non-zero")
    }

    func testMoleCLIRun_stillCapturesKnownEchoInvocationThroughRealPort() throws {
        let result = try MoleCLI.run(args: ["hello world"], executable: "/bin/echo")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello world")
    }

    func testMoleCLIRun_mapsInjectedPortResult() throws {
        let fake = FakeMoleProcessPort()
        fake.result = MoleProcessResult(stdout: "mapped out", stderr: "mapped err", exitCode: 7)
        MoleCLI.processPort = fake

        let result = try MoleCLI.run(args: ["ignored"], executable: "/bin/example", stdin: "yes\n", timeout: 3)

        XCTAssertEqual(result.stdout, "mapped out")
        XCTAssertEqual(result.stderr, "mapped err")
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(fake.receivedExecutable, "/bin/example")
        XCTAssertEqual(fake.receivedArgs, ["ignored"])
        XCTAssertEqual(fake.receivedStdin, "yes\n")
        XCTAssertEqual(fake.receivedTimeout, 3)
    }
}
