//
//  ProcessActionsTests.swift
//  BurrowTests
//

import XCTest
import Darwin
@testable import Burrow

final class ProcessActionsTests: XCTestCase {
    func testTerminateFailsClosedWhenPIDWasReused() {
        let expected = target(identity: identity(start: 10))
        let signals = LockedSignals()

        let result = ProcessActions.terminate(
            expected,
            force: false,
            currentUID: 501,
            readIdentity: { _ in self.identity(start: 11) },
            sendSignal: { pid, signal in signals.append(pid: pid, signal: signal); return 0 }
        )

        XCTAssertEqual(result, .stale)
        XCTAssertTrue(signals.values.isEmpty)
    }

    func testTerminateFailsClosedWhenExecutableChangedAfterConfirmation() {
        let expected = target(identity: identity(path: "/Applications/Before.app/Contents/MacOS/Before"))
        let signals = LockedSignals()

        let result = ProcessActions.terminate(
            expected,
            force: false,
            currentUID: 501,
            readIdentity: { _ in self.identity(path: "/Applications/After.app/Contents/MacOS/After") },
            sendSignal: { pid, signal in signals.append(pid: pid, signal: signal); return 0 }
        )

        XCTAssertEqual(result, .stale)
        XCTAssertTrue(signals.values.isEmpty)
    }

    func testTerminateFailsClosedWhenOwnerChanged() {
        let expected = target(identity: identity(owner: 501))
        let signals = LockedSignals()

        let result = ProcessActions.terminate(
            expected,
            force: false,
            currentUID: 501,
            readIdentity: { _ in self.identity(owner: 0) },
            sendSignal: { pid, signal in signals.append(pid: pid, signal: signal); return 0 }
        )

        XCTAssertEqual(result, .notOwned)
        XCTAssertTrue(signals.values.isEmpty)
    }

    func testTerminateSignalsOnlyAnExactRevalidatedIdentity() {
        let identity = identity()
        let expected = target(identity: identity)
        let signals = LockedSignals()

        let result = ProcessActions.terminate(
            expected,
            force: false,
            currentUID: 501,
            readIdentity: { _ in identity },
            sendSignal: { pid, signal in signals.append(pid: pid, signal: signal); return 0 }
        )

        XCTAssertEqual(result, .sent)
        XCTAssertEqual(signals.values, [.init(pid: 42, signal: SIGTERM)])
    }

    func testForceKillUsesTheSameRevalidationBeforeSIGKILL() {
        let identity = identity()
        let expected = target(identity: identity)
        let signals = LockedSignals()

        let result = ProcessActions.terminate(
            expected,
            force: true,
            currentUID: 501,
            readIdentity: { _ in identity },
            sendSignal: { pid, signal in signals.append(pid: pid, signal: signal); return 0 }
        )

        XCTAssertEqual(result, .sent)
        XCTAssertEqual(signals.values, [.init(pid: 42, signal: SIGKILL)])
    }

    func testCancellingConfirmationNeverReadsOrSignalsTheProcess() {
        let expected = target(identity: identity())
        let signals = LockedSignals()
        var identityReads = 0

        let result = ProcessActions.terminateIfConfirmed(
            expected,
            force: false,
            confirmed: false,
            currentUID: 501,
            readIdentity: { _ in identityReads += 1; return self.identity() },
            sendSignal: { pid, signal in signals.append(pid: pid, signal: signal); return 0 }
        )

        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(identityReads, 0)
        XCTAssertTrue(signals.values.isEmpty)
    }

    func testConfirmationDetailsExposeTheCapturedImmutableIdentity() {
        let target = target(identity: identity())

        XCTAssertTrue(target.confirmationDetails.contains("PID 42"))
        XCTAssertTrue(target.confirmationDetails.contains("user 501"))
        XCTAssertTrue(target.confirmationDetails.contains("started 10.000020"))
        XCTAssertTrue(target.confirmationDetails.contains("/Applications/Test.app/Contents/MacOS/Test"))
    }

    private func identity(
        owner: uid_t = 501,
        start: UInt64 = 10,
        path: String? = "/Applications/Test.app/Contents/MacOS/Test"
    ) -> ProcessActions.Identity {
        ProcessActions.Identity(
            pid: 42,
            ownerUID: owner,
            startSeconds: start,
            startMicroseconds: 20,
            executablePath: path
        )
    }

    private func target(identity: ProcessActions.Identity) -> ProcessActions.TerminationTarget {
        ProcessActions.TerminationTarget(displayName: "Test", identity: identity)
    }
}

private final class LockedSignals: @unchecked Sendable {
    struct Value: Equatable {
        let pid: Int32
        let signal: Int32
    }

    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(pid: Int32, signal: Int32) {
        lock.lock()
        storage.append(.init(pid: pid, signal: signal))
        lock.unlock()
    }
}
