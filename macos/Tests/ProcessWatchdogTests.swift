//
//  ProcessWatchdogTests.swift
//  BurrowTests
//

import XCTest
@testable import Burrow

@MainActor
final class ProcessWatchdogTests: XCTestCase {
    func testQuitRoutesTheExactCapturedIdentityThroughConfirmation() {
        let target = ProcessActions.TerminationTarget(
            displayName: "Example",
            identity: .init(
                pid: 42,
                ownerUID: 501,
                startSeconds: 100,
                startMicroseconds: 200,
                executablePath: "/Applications/Example.app/Contents/MacOS/Example"
            )
        )
        var shownTarget: ProcessActions.TerminationTarget?

        let watchdog = ProcessWatchdog(
            processControl: .init(
                isOwnProcess: { _ in XCTFail("quit must not use the suspend ownership path"); return true },
                suspend: { _ in XCTFail("quit must not suspend directly") },
                terminationTarget: { pid, name in
                    XCTAssertEqual(pid, 42)
                    XCTAssertEqual(name, "Example")
                    return target
                },
                confirmTermination: { candidate, _ in
                    shownTarget = candidate
                    return nil
                }
            ),
            configuredAction: { .quit }
        )

        watchdog.dispatch(pid: 42, name: "Example")

        XCTAssertEqual(shownTarget, target)
        XCTAssertTrue(shownTarget?.confirmationDetails.contains("PID 42") == true)
        XCTAssertTrue(shownTarget?.confirmationDetails.contains("user 501") == true)
        XCTAssertTrue(shownTarget?.confirmationDetails.contains("started 100.000200") == true)
        XCTAssertTrue(shownTarget?.confirmationDetails.contains(
            "/Applications/Example.app/Contents/MacOS/Example"
        ) == true)
    }

    func testQuitFailsClosedWhenNoOwnedIdentityCanBeCaptured() {
        var confirmationCount = 0
        var refreshCount = 0
        let watchdog = ProcessWatchdog(
            processControl: .init(
                isOwnProcess: { _ in true },
                suspend: { _ in XCTFail("quit must not suspend directly") },
                terminationTarget: { _, _ in nil },
                confirmTermination: { _, _ in confirmationCount += 1; return .sent }
            ),
            configuredAction: { .quit }
        )

        watchdog.dispatch(pid: 42, name: "Exited") { refreshCount += 1 }

        XCTAssertEqual(confirmationCount, 0)
        XCTAssertEqual(refreshCount, 1)
    }

    func testQuitFailureRefreshesTheProcessList() {
        let target = ProcessActions.TerminationTarget(
            displayName: "Exited",
            identity: .init(pid: 42, ownerUID: 501, startSeconds: 100,
                            startMicroseconds: 200, executablePath: "/tmp/exited")
        )
        var refreshCount = 0
        let watchdog = ProcessWatchdog(
            processControl: .init(
                isOwnProcess: { _ in true },
                suspend: { _ in XCTFail("quit must not suspend directly") },
                terminationTarget: { _, _ in target },
                confirmTermination: { _, refresh in
                    refresh()
                    return .stale
                }
            ),
            configuredAction: { .quit }
        )

        watchdog.dispatch(pid: 42, name: "Exited") { refreshCount += 1 }

        XCTAssertEqual(refreshCount, 1)
    }
}
