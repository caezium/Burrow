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
    // The human-text output the `cleanOp()` fixture's `parseTaskReport` reducer consumes.
    static let cannedClean: [ProcessEvent] = [
        .line("➤ Developer tools"),
        .line("  → npm cache, 191.8MB"),
        .line("Potential space: 383.8MB | Items: 372 | Categories: 20"),
        .exited(0),
    ]

    // The engine's `clean --stream` NDJSON preview, which the `moleStream(...)` op's
    // BurrowStreamReport reducer consumes. A dry-run done carries `would_free_human` →
    // summary.space (no freeChange), so the completion line reads "Cleaned 383.8MB · 372 items"
    // — same summary the old human-text "Potential space" preview produced.
    static let cannedCleanStream: [ProcessEvent] = [
        .line(#"{"event":"would_remove","path":"/Users/x/Library/Caches/npm cache","bytes":201129000}"#),
        .line(#"{"event":"done","dry_run":true,"would_free_bytes":402438000,"would_free_human":"383.8MB","count":372}"#),
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
        XCTAssertFalse(op.notifiesOnEnd, "preview-style ops never notify")
    }

    // The real-clean shape: notifyOnEnd rides into the OperationCenter op
    // and the parsed summary replaces the last streamed line as the final
    // detail — that's the body a completion notification carries.
    func testNotifyOnEnd_andFinalDetail_reachOperationCenter() async throws {
        let port = FakeProcessPort(script: Self.cannedCleanStream)
        let center = OperationCenter()
        let flow = OperationFlow<TaskRunReport>(process: port, hasFullDiskAccess: { true },
                                                resolveMo: { _ in "/usr/local/bin/mo" }, center: center)

        flow.start(.moleStream(["clean"], label: "Cleaning caches", notifyOnEnd: true))
        await settle(flow)

        let op = try XCTUnwrap(center.ops.first)
        XCTAssertTrue(op.notifiesOnEnd)
        XCTAssertEqual(op.phase, .done)
        XCTAssertEqual(op.detail, "Cleaned 383.8MB · 372 items",
                       "final detail is the parsed summary, not the last raw line")
    }

    func testAuthCancelledFromThePort_failsTheFlow() async throws {
        // Auth-cancel is classified by the RUNNER now (issue #48) — the flow
        // just renders the failure.
        let port = FakeProcessPort(script: [.authCancelled])
        let flow = makeFlow(port)
        flow.start(Self.cleanOp(elevated: true))
        await settle(flow)
        guard case .finished(.failed) = flow.state else { return XCTFail("expected failed") }
    }

    func testNonzeroPrivilegedCleanupFailsVisiblyAndNeverCompletesTheHUD() async throws {
        var parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-operation-flow-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        parent = URL(fileURLWithPath: try XCTUnwrap(
            InvokingUserIdentity.canonicalPath(parent.path)), isDirectory: true)
        let item = parent.appendingPathComponent("reviewed-cache")
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let snapshot = try CleanupSnapshot.capture(
            list: CleanList(categories: [
                .init(name: "Test", items: [
                    .init(path: item.path, sizeBytes: 1, sizeText: "1B", itemCount: nil),
                ]),
            ], summaryTotalText: "1B", summaryItemCount: 1),
            approvedRootURLs: [parent])
        let plan = try snapshot.plan(selectedPaths: [item.path])

        let port = FakeProcessPort(script: [.exited(ElevatedExitCode.boundaryCheckFailed)])
        let center = OperationCenter()
        let flow = makeFlow(port, center: center)
        var operation = Self.cleanOp(elevated: true)
        operation.cleanupPlan = plan
        flow.start(operation)
        await settle(flow)

        guard case .finished(.failed(let message)) = flow.state else {
            return XCTFail("a fail-closed cleanup exit must not become done")
        }
        // A refused boundary check means NOTHING was deleted, so the message
        // must say so rather than implying a partial run.
        XCTAssertTrue(message.contains("Nothing was cleaned"), message)
        XCTAssertTrue(message.contains("Rescan"), message)
        XCTAssertNil(flow.report, "a refused cleanup must not render the preview's summary")
        XCTAssertEqual(center.ops.first?.phase, .failed)
    }

    /// A cleanup that ran and could not remove everything is a DIFFERENT
    /// outcome from one that was refused before it started, and the two must
    /// not share wording — one leaves the caches in place, the other doesn't.
    func testPartialCleanupFailureReadsAsPartialNotRefused() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-flow-partial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let canonicalParent = URL(fileURLWithPath: try XCTUnwrap(
            InvokingUserIdentity.canonicalPath(parent.path)))
        let item = canonicalParent.appendingPathComponent("reviewed-cache")
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
        let snapshot = try CleanupSnapshot.capture(
            list: CleanList(categories: [
                .init(name: "Test", items: [
                    .init(path: item.path, sizeBytes: 1, sizeText: "1B", itemCount: nil),
                ]),
            ], summaryTotalText: "1B", summaryItemCount: 1),
            approvedRootURLs: [canonicalParent])
        let plan = try snapshot.plan(selectedPaths: [item.path])

        let flow = makeFlow(FakeProcessPort(script: [.exited(1)]))
        var operation = Self.cleanOp(elevated: true)
        operation.cleanupPlan = plan
        flow.start(operation)
        await settle(flow)

        guard case .finished(.failed(let message)) = flow.state else {
            return XCTFail("a nonzero cleanup exit must not become done")
        }
        XCTAssertTrue(message.contains("could not be removed"), message)
        XCTAssertFalse(message.contains("Nothing was cleaned"), message)
    }

    /// This is about the DIRECT engine path, so it has to pin the no-conductor world: with a
    /// conductor staged, `streamOverride` supplies an executable for a non-elevated `clean`
    /// before `resolveMo` is ever consulted, and the unresolvable-engine branch under test is
    /// never reached. It previously relied on the test host happening not to bundle one.
    func testMissingExecutableFailsBeforeSpawn() {
        ConductorBundleFixture.withConductor(present: false) {
            let port = FakeProcessPort(script: [])
            let flow = OperationFlow<CleanReport>(process: port, hasFullDiskAccess: { true },
                                                  resolveMo: { _ in nil }, center: OperationCenter())
            flow.start(Self.cleanOp())
            guard case .finished(.failed) = flow.state else { return XCTFail("expected failed") }
            XCTAssertTrue(port.specs.isEmpty)
        }
    }

    func testElevatedRunFailsBeforeSpawnWhenInvokingAccountCannotBeResolved() {
        let port = FakeProcessPort(script: [.exited(0)])
        let flow = OperationFlow<CleanReport>(
            process: port, hasFullDiskAccess: { true }, resolveMo: { _ in "/usr/bin/true" },
            resolveInvokingUser: {
                throw InvokingUserIdentity.ResolutionError.missingAccount(501)
            }, center: OperationCenter())
        flow.start(Self.cleanOp(elevated: true))
        guard case .finished(.failed) = flow.state else { return XCTFail("expected fail closed") }
        XCTAssertTrue(port.specs.isEmpty, "identity targets are derived before elevation")
    }

    // MARK: - A routing switch must not change destructive semantics (the §2 bug, fallback half)
    //
    // `streamOverride` returning nil (the streaming switch off, or no conductor bundled) used to
    // mean the fallback spawn sent `op.arguments` straight through, untranslated. Once
    // `MoleCLI.bundledExecutable()` became part of `resolveMo`'s resolution chain, that fallback
    // started resolving the SAME bundled engine the conductor branch would have — so the switch
    // stopped being a transport-only decision and started being able to flip a live clean into a
    // silent no-op. These pin that the fallback branch now translates whenever it resolves the
    // bundled engine, and does NOT translate when it resolves anything else.
    //
    // Both therefore have to REACH that branch, and two deliberate acts are what get them there.
    // `bundledExecutableOverride` is what lets the fallback recognise a bundled engine at all —
    // it short-circuits `MoleCLI.bundledExecutable()` before the shared lookup, so it does not
    // also make a conductor "bundled" (that is `BurrowConductor.resourceDirectory`'s seam). And
    // turning the documented `BurrowStreamViaConductor` kill switch off is what stops
    // `streamOverride` answering first: at its shipped default (ON for clean/optimize), a test
    // host that HAD staged a Resources/burrow would spawn the CONDUCTOR's
    // `["clean", "--apply", "--stream"]` instead, whatever `resolveMo` was told to return. The
    // switch off with an engine still bundled is exactly the production configuration these two
    // describe; without it both tests could silently assert about the branch they mean to bypass.

    func testFallbackPath_stillTranslatesArgv_whenResolveMoFindsTheBundledEngine() async throws {
        MoleCLI.bundledExecutableOverride = "/fake/bundled/burrow"
        defer { MoleCLI.bundledExecutableOverride = nil }
        UserDefaults.standard.set(false, forKey: "BurrowStreamViaConductor")
        defer { UserDefaults.standard.removeObject(forKey: "BurrowStreamViaConductor") }
        let port = FakeProcessPort(script: Self.cannedCleanStream)
        let flow = OperationFlow<TaskRunReport>(process: port, hasFullDiskAccess: { true },
                                                resolveMo: { _ in "/fake/bundled/burrow" },
                                                center: OperationCenter())
        // A live real clean — mo-style, no --dry-run — is exactly the destructive case: reaching
        // the engine without --apply would silently no-op it (the §2 bug).
        flow.start(.moleStream(["clean"], elevated: true, label: "Cleaning caches"))
        await settle(flow)
        let spec = try XCTUnwrap(port.specs.first)
        XCTAssertEqual(spec.executable, "/fake/bundled/burrow")
        XCTAssertEqual(spec.arguments, ["clean", "--apply"],
                       "a live mo-style run that falls through to the (still bundled-engine) " +
                       "direct path must gain --apply just like the conductor path would, or a " +
                       "real clean silently no-ops against the engine's dry-run default")
        XCTAssertFalse(spec.arguments.contains("--stream"),
                       "and it must be the DIRECT spawn being asserted: --stream is the " +
                       "conductor transport, so its presence means this never reached the fallback")
    }

    func testFallbackPath_leavesArgvUntranslated_whenResolveMoFindsAnExternalMo() async throws {
        // The override is set (so `bundledExecutable()` resolves to something) but `resolveMo`
        // deliberately returns a DIFFERENT path — the "bundle itself is missing, Homebrew has a
        // real mo" case. That binary speaks mo's own convention, so translating it would turn
        // this elevated PREVIEW into a live delete instead — the dangerous direction.
        MoleCLI.bundledExecutableOverride = "/fake/bundled/burrow"
        defer { MoleCLI.bundledExecutableOverride = nil }
        UserDefaults.standard.set(false, forKey: "BurrowStreamViaConductor")
        defer { UserDefaults.standard.removeObject(forKey: "BurrowStreamViaConductor") }
        let port = FakeProcessPort(script: Self.cannedClean)
        let flow = OperationFlow<TaskRunReport>(process: port, hasFullDiskAccess: { true },
                                                resolveMo: { _ in "/opt/homebrew/bin/mo" },
                                                center: OperationCenter())
        flow.start(.moleStream(["clean", "--dry-run"], elevated: true, label: "Scanning caches"))
        await settle(flow)
        let spec = try XCTUnwrap(port.specs.first)
        XCTAssertEqual(spec.executable, "/opt/homebrew/bin/mo")
        XCTAssertEqual(spec.arguments, ["clean", "--dry-run"],
                       "a genuine external mo fallback must keep mo-style argv untouched — " +
                       "translating it would turn a preview into a live delete on that binary")
    }
}

// MARK: - Production adapter against real (tiny) processes

final class SystemProcessPortTests: XCTestCase {
    /// What the stream produced, filled from the consuming task so the deadline
    /// branch can report how far the run actually got.
    private actor Collected {
        private(set) var lines: [String] = []
        private(set) var exit: Int32?
        private(set) var sawAuthCancel = false
        func append(_ line: String) { lines.append(line) }
        func exited(_ code: Int32) { exit = code }
        func authCancelled() { sawAuthCancel = true }
    }

    /// Consume the stream, but never for longer than `deadline`.
    ///
    /// These tests drive real processes and real pipes, so a bug in the runner
    /// shows up as a test that never returns — which cost one CI run half an
    /// hour of silence before it was cancelled, with a single "started" line to
    /// show for it. A bounded wait turns that into a failure that says how far
    /// the run got; SystemProcessPort's own stderr breadcrumbs say why.
    private func run(_ spec: ProcessSpec, deadline: TimeInterval = 15,
                     file: StaticString = #filePath,
                     line: UInt = #line) async -> (lines: [String], exit: Int32?) {
        let collected = Collected()
        let stream = SystemProcessPort().events(spec)
        let started = Date()
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await e in stream {
                    switch e {
                    case .line(let l): await collected.append(l)
                    case .exited(let c): await collected.exited(c)
                    case .authCancelled: await collected.authCancelled()
                    }
                }
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        let lines = await collected.lines
        let exit = await collected.exit
        if !finished {
            XCTFail("""
                    the stream never finished: \(spec.executable) \(spec.arguments.joined(separator: " ")) \
                    still had not produced a terminal event after \
                    \(String(format: "%.1f", Date().timeIntervalSince(started)))s \
                    (timeout \(spec.timeout.map { "\($0)s" } ?? "none"), \
                    \(lines.count) line(s) so far: \(lines.prefix(4)))
                    """, file: file, line: line)
        }
        if await collected.sawAuthCancel {
            XCTFail("un-elevated specs never classify as auth-cancel", file: file, line: line)
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

    /// The kill has to work on a child that SIGTERM can't touch, and the stream
    /// has to finish even when the pipe's write end outlives that child.
    ///
    /// `trap '' TERM` makes the ignore-disposition survive the exec, so this
    /// child cannot be terminated politely — only the escalation to SIGKILL
    /// ends it. And depending on whether /bin/sh execs `sleep` or forks it, the
    /// surviving `sleep` may still hold our stdout open after the shell is
    /// dead, in which case EOF never arrives and only the readers' own bound
    /// lets the run finish. Both shapes used to wedge the stream forever, which
    /// in the app is a progress HUD that never comes back.
    func testTimeoutFinishesEvenWhenTheChildIgnoresSIGTERM() async {
        let started = Date()
        let r = await run(ProcessSpec(executable: "/bin/sh",
                                      arguments: ["-c", "trap '' TERM; sleep 10"],
                                      stdin: nil, elevated: false, timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(started), 10,
                          "SIGTERM is ignored here: the SIGKILL escalation and the reader " +
                          "bound must still end the run before the 10 s sleep does")
        XCTAssertNotEqual(r.exit, 0, "a killed run never reports success")
    }

    func testSpawnFailureYieldsExit127() async {
        let r = await run(ProcessSpec(executable: "/nonexistent/binary", arguments: [],
                                      stdin: nil, elevated: false, timeout: nil))
        XCTAssertEqual(r.exit, 127)
    }

    // MARK: Auth-cancel classification — an engine rule, not view folklore

    /// Only AppleScript's canonical userCanceledErr is a cancellation.
    func testFinalEvent_classifiesAuthCancel() {
        guard case .authCancelled = SystemProcessPort.finalEvent(
            exitCode: 1, elevated: true,
            appleScriptStderr: "execution error: User canceled. (-128)") else {
            return XCTFail("canonical -128 diagnostic = dismissed auth prompt")
        }
        guard case .exited(1) = SystemProcessPort.finalEvent(
            exitCode: 1, elevated: true, appleScriptStderr: "") else {
            return XCTFail("silent root command failures remain failures")
        }
        // Un-elevated runs have no auth prompt to cancel.
        guard case .exited(2) = SystemProcessPort.finalEvent(
            exitCode: 2, elevated: false,
            appleScriptStderr: "execution error: User canceled. (-128)") else {
            return XCTFail("no elevation, no auth-cancel")
        }
        // Success is success even when silent.
        guard case .exited(0) = SystemProcessPort.finalEvent(
            exitCode: 0, elevated: true,
            appleScriptStderr: "execution error: User canceled. (-128)") else {
            return XCTFail("exit 0 is never a cancel")
        }
    }
}
