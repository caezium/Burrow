//
//  OperationFlowTests.swift
//  BurrowTests
//
//  Boundary tests for the operation flow shell — the run-a-tool lifecycle
//  (FDA gate → optional elevation → spawn → stream → reduce → report →
//  OperationCenter) that CleanView/OptimizeView previously each owned as
//  view plumbing. The process boundary is a scripted fake; no real
//  processes, no TCC, no wall-clock.
//

import XCTest
@testable import Burrow

@MainActor
final class OperationFlowTests: XCTestCase {

    // MARK: Test adapter

    final class FakeProcessPort: ProcessPort, @unchecked Sendable {
        var script: [ProcessEvent]
        /// Keep the stream open after the script (for cancel tests).
        var holdOpen = false
        private(set) var specs: [ProcessSpec] = []
        private(set) var terminated = false

        init(script: [ProcessEvent]) { self.script = script }

        func events(_ spec: ProcessSpec) -> AsyncStream<ProcessEvent> {
            specs.append(spec)
            let s = script, hold = holdOpen
            return AsyncStream { cont in
                cont.onTermination = { @Sendable _ in self.terminated = true }
                for e in s { cont.yield(e) }
                if !hold { cont.finish() }
            }
        }
    }

    /// Canned dry-run output in mo's report shape (parseTaskReport-compatible).
    static let cannedClean: [ProcessEvent] = [
        .line("➤ Developer tools"),
        .line("  → npm cache, 191.8MB"),
        .line("Potential space: 383.8MB | Items: 372 | Categories: 20"),
        .exited(0),
    ]

    typealias CleanReport = (groups: [TaskGroup], summary: TaskSummary?)

    static func cleanOp(gate: ToolOperation<CleanReport>.Gate = .none,
                        elevated: Bool = false) -> ToolOperation<CleanReport> {
        ToolOperation(label: "Scanning caches",
                      arguments: ["clean", "--dry-run"],
                      gate: gate,
                      elevated: elevated,
                      reduce: { parseTaskReport($0) },
                      hudLine: { TaskReportText.line($0) })
    }

    private func makeFlow(_ port: FakeProcessPort, fda: @escaping () -> Bool = { true },
                          center: OperationCenter? = nil) -> OperationFlow<CleanReport> {
        OperationFlow(process: port, hasFullDiskAccess: fda,
                      resolveMo: { _ in "/usr/local/bin/mo" }, center: center ?? OperationCenter())
    }

    private func settle<R>(_ flow: OperationFlow<R>) async {
        for _ in 0..<1000 {
            if case .finished = flow.state { return }
            await Task.yield()
        }
        XCTFail("flow never finished")
    }

    // MARK: Tests

    func testGate_blocksWithoutFDAThenGrantRuns() async throws {
        let port = FakeProcessPort(script: Self.cannedClean)
        var fda = false
        let flow = makeFlow(port, fda: { fda })

        flow.start(Self.cleanOp(gate: .fullDiskAccess(adminBypass: true)))
        guard case .gated(let pending) = flow.state else { return XCTFail("expected FDA gate") }
        XCTAssertTrue(port.specs.isEmpty, "nothing spawns while gated")

        fda = true
        flow.start(pending)                       // "I've granted it" = start again
        await settle(flow)

        XCTAssertEqual(port.specs.last?.elevated, false)
        XCTAssertEqual(flow.report?.summary?.space, "383.8MB")
        XCTAssertEqual(flow.report?.groups.count, 1)
        guard case .finished(.done(exit: 0)) = flow.state else { return XCTFail("expected done(0)") }
    }

    func testGate_adminBypassRunsElevatedWithoutGate() async throws {
        let port = FakeProcessPort(script: Self.cannedClean)
        let flow = makeFlow(port, fda: { false })

        flow.start(Self.cleanOp(gate: .fullDiskAccess(adminBypass: true)))
        guard case .gated(let pending) = flow.state else { return XCTFail("expected gate") }

        flow.start(pending.elevated())            // "Scan with admin" — root dodges TCC
        await settle(flow)
        XCTAssertEqual(port.specs.last?.elevated, true)
        guard case .finished(.done) = flow.state else { return XCTFail("expected done") }
    }

    func testCancel_terminatesChildAndMarksCancelled() async throws {
        let port = FakeProcessPort(script: [.line("➤ Working")])
        port.holdOpen = true                      // process never exits on its own
        let flow = makeFlow(port)

        flow.start(Self.cleanOp())
        XCTAssertTrue(flow.canCancel)
        flow.cancel()

        guard case .finished(.cancelled) = flow.state else { return XCTFail("expected cancelled") }
        for _ in 0..<1000 { if port.terminated { break }; await Task.yield() }
        XCTAssertTrue(port.terminated, "cancelling the flow terminates the child")
    }

    func testElevatedRunCannotCancel() {
        let port = FakeProcessPort(script: [.line("x")])
        port.holdOpen = true
        let flow = makeFlow(port)
        flow.start(Self.cleanOp(elevated: true))
        XCTAssertFalse(flow.canCancel,
                       "SIGTERMing the osascript messenger would orphan the root child")
    }

    func testStdinTimeoutAndPathExecutableReachSpec() async throws {
        let port = FakeProcessPort(script: [.exited(0)])
        let flow = OperationFlow<String>(process: port, hasFullDiskAccess: { true },
                                         resolveMo: { _ in nil }, center: OperationCenter())
        // Uninstall-style blocking run: canned confirmations + long timeout.
        let answers = String(repeating: "y\n", count: 16)
        flow.start(ToolOperation(label: nil,
                                 executable: .path("/opt/homebrew/bin/brew"),
                                 arguments: ["upgrade", "wget"],
                                 stdin: answers,
                                 timeout: 300,
                                 reduce: { $0.joined(separator: "\n") }))
        await settle(flow)
        let spec = try XCTUnwrap(port.specs.first)
        XCTAssertEqual(spec.executable, "/opt/homebrew/bin/brew")
        XCTAssertEqual(spec.stdin, answers)
        XCTAssertEqual(spec.timeout, 300)
    }

    func testOperationCenter_beginDetailEnd() async throws {
        let port = FakeProcessPort(script: Self.cannedClean)
        let center = OperationCenter()
        let flow = makeFlow(port, center: center)

        flow.start(Self.cleanOp())
        await settle(flow)

        let op = try XCTUnwrap(center.ops.first)
        XCTAssertEqual(op.label, "Scanning caches")
        XCTAssertEqual(op.phase, .done)
        XCTAssertFalse(op.detail.isEmpty, "HUD detail fed from the stream")
    }

    func testElevationDeclined_failsWithNoOutput() async throws {
        // osascript exits nonzero with zero lines when the auth prompt is
        // dismissed — that's a failure, not a "done with exit 1".
        let port = FakeProcessPort(script: [.exited(1)])
        let flow = makeFlow(port)
        flow.start(Self.cleanOp(elevated: true))
        await settle(flow)
        guard case .finished(.failed) = flow.state else { return XCTFail("expected failed") }
    }

    func testMissingExecutableFailsBeforeSpawn() {
        let port = FakeProcessPort(script: [])
        let flow = OperationFlow<CleanReport>(process: port, hasFullDiskAccess: { true },
                                              resolveMo: { _ in nil }, center: OperationCenter())
        flow.start(Self.cleanOp())
        guard case .finished(.failed) = flow.state else { return XCTFail("expected failed") }
        XCTAssertTrue(port.specs.isEmpty)
    }
}

// MARK: - Production adapter against real (tiny) processes

final class SystemProcessPortTests: XCTestCase {
    private func run(_ spec: ProcessSpec) async -> (lines: [String], exit: Int32?) {
        var lines: [String] = []
        var exit: Int32?
        for await e in SystemProcessPort().events(spec) {
            switch e {
            case .line(let l): lines.append(l)
            case .exited(let c): exit = c
            }
        }
        return (lines, exit)
    }

    func testStreamsLinesAndExitCode() async {
        let r = await run(ProcessSpec(executable: "/bin/sh",
                                      arguments: ["-c", "printf 'a\\nb\\n'; exit 3"],
                                      stdin: nil, elevated: false, timeout: nil))
        XCTAssertEqual(r.lines, ["a", "b"])
        XCTAssertEqual(r.exit, 3)
    }

    func testStdinIsFedAndClosed() async {
        let r = await run(ProcessSpec(executable: "/bin/cat", arguments: [],
                                      stdin: "hello\n", elevated: false, timeout: nil))
        XCTAssertEqual(r.lines, ["hello"])
        XCTAssertEqual(r.exit, 0)
    }

    func testTimeoutKillsTheChild() async {
        let started = Date()
        let r = await run(ProcessSpec(executable: "/bin/sleep", arguments: ["10"],
                                      stdin: nil, elevated: false, timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5,
                          "the kill timer must fire, not the 10 s sleep")
        XCTAssertNotEqual(r.exit, 0)
    }

    func testSpawnFailureYieldsExit127() async {
        let r = await run(ProcessSpec(executable: "/nonexistent/binary", arguments: [],
                                      stdin: nil, elevated: false, timeout: nil))
        XCTAssertEqual(r.exit, 127)
    }
}
