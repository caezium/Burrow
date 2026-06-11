//
//  MoInteractiveRealTests.swift
//  BurrowTests
//
//  One real end-to-end check of the refactored selection host against the
//  actual `mo` CLI over a real pseudo-terminal: scan `mo installer` and confirm
//  it resolves (to the chooser, or "nothing found") without hanging. It NEVER
//  confirms a removal, so nothing is deleted. Skipped when `mo` isn't on PATH;
//  the deterministic coverage is SelectionSessionTests + the FakePTY host test.
//

import XCTest
import Combine
@testable import Burrow

@MainActor
final class MoInteractiveRealTests: XCTestCase {
    private var bag = Set<AnyCancellable>()

    func testRealInstallerScan_resolvesWithoutHanging() throws {
        // Opt-in only: the real scan walks Desktop/Documents/Downloads, which
        // triggers TCC prompts on un-granted machines and can exceed the
        // timeout on large disks. CI and default local runs skip it.
        try XCTSkipUnless(Foundation.ProcessInfo.processInfo.environment["BURROW_REAL_MO_TESTS"] == "1",
                          "set BURROW_REAL_MO_TESTS=1 to run the real `mo installer` scan")
        try XCTSkipUnless(MoleCLI.findExecutable() != nil, "needs `mo` on PATH")

        let runner = MoInteractiveRunner(subcommand: "installer", title: "Installers")
        let resolved = expectation(description: "scan reaches choosing or done")
        resolved.assertForOverFulfill = false   // @Published re-emits the same phase on each redraw
        runner.$phase
            .sink { phase in
                switch phase {
                case .choosing, .done, .failed: resolved.fulfill()
                case .scanning, .applying: break
                }
            }
            .store(in: &bag)

        runner.start()
        wait(for: [resolved], timeout: 20)
        runner.cancel()   // back out before any confirm — nothing is removed
    }
}
