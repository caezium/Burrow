//
//  MoInteractiveHostTests.swift
//  BurrowTests
//
//  Integration test for the host that wires the SelectionSession reducer to a
//  pseudo-terminal. Uses a scripted FakePTY (records keystrokes, replays canned
//  frames) and a manual tick so the whole flow runs deterministically with no
//  real subprocess and no wall-clock. An injected executable path lets it run
//  on a bare CI runner without `mo` (the FakePTY ignores the path anyway).
//

import XCTest
@testable import Burrow

/// Records what the host writes and lets the test feed canned frames/exit.
final class FakePTY: PTYPort {
    var onOutput: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    private(set) var sent: [UInt8] = []
    private(set) var launched = false

    func launch(_ executable: String, _ args: [String]) throws { launched = true }
    func send(_ bytes: [UInt8]) { sent.append(contentsOf: bytes) }
    func terminate() {}

    func emit(_ s: String) { onOutput?(s) }
    func exitProcess(_ code: Int32) { onExit?(code) }
}

@MainActor
final class MoInteractiveHostTests: XCTestCase {
    private let scanFrame = """
    Select Installers to Remove , 0B, 0 selected
    \u{27A4} \u{25CB} a.dmg   771KB | Desktop
      \u{25CB} b.dmg   760KB | Desktop
      \u{25CB} c.dmg   1.26GB | Desktop
    \u{2191}\u{2193}  |  Space Select  |  Enter Confirm  |  A All  |  I Invert  |  Q Quit
    """
    private let selectedFrame = """
    Select Installers to Remove , 760KB, 1 selected
      \u{25CB} a.dmg   771KB | Desktop
    \u{27A4} \u{25CF} b.dmg   760KB | Desktop
      \u{25CB} c.dmg   1.26GB | Desktop
    \u{2191}\u{2193}  |  Space Select  |  Enter Confirm  |  A All  |  I Invert  |  Q Quit
    """

    /// Regression: a child that prints then exits must deliver `onExit`. A pty
    /// at EOF fires the readability handler with empty data forever; if we don't
    /// disarm it, that spin starves the process terminationHandler and the exit
    /// is never reported — the UI hangs on "Scanning…" when Mole finds nothing.
    func testPTYTask_reportsExitWhenChildExitsImmediately() {
        let pty = PTYTask()
        let exited = expectation(description: "onExit fires")
        pty.onOutput = { _ in }
        pty.onExit = { _ in exited.fulfill() }
        try? pty.launch("/bin/echo", ["hi"])   // prints, then exits → pty EOF
        wait(for: [exited], timeout: 5)
    }

    /// Regression: a rescan calls launch() again on the same PTYTask. A Process
    /// can only run once, so the second launch must spin up a FRESH child and
    /// report its exit too — reusing the old one left the rescan with a dead
    /// child and the UI hung on "Scanning…".
    func testPTYTask_relaunchAfterChildExits_stillReportsExit() {
        let pty = PTYTask()
        pty.onOutput = { _ in }
        let first = expectation(description: "first exit")
        pty.onExit = { _ in first.fulfill() }
        try? pty.launch("/bin/echo", ["one"])
        wait(for: [first], timeout: 5)

        let second = expectation(description: "second exit")
        pty.onExit = { _ in second.fulfill() }
        try? pty.launch("/bin/echo", ["two"])
        wait(for: [second], timeout: 5)
    }

    /// Regression: a rescan from the chooser terminates a child that is still
    /// ALIVE, and that child's exit is reported asynchronously — after `launch()`
    /// has already armed a fresh one. Untagged, the dead child's SIGTERM arrived
    /// as the new scan's exit, and because the reducer reads an exit-before-any-
    /// list as "nothing to remove", the rescan collapsed straight to `.done`.
    /// `/bin/cat` stands in for `mo` at the selection screen: it holds the pty
    /// open and never exits on its own, so any exit seen here is the old one's.
    func testPTYTask_relaunchWhileRunning_doesNotReportTheOldChildsExit() {
        let pty = PTYTask()

        // First child up and running (it echoes, which proves the pty is live).
        let greeted = expectation(description: "first child is running")
        // The pty's own line discipline echoes the write and `cat` prints it
        // back, so "ready" can arrive in one read or two.
        greeted.assertForOverFulfill = false
        pty.onOutput = { if $0.contains("ready") { greeted.fulfill() } }
        try? pty.launch("/bin/cat", [])
        pty.send(Array("ready\n".utf8))
        wait(for: [greeted], timeout: 5)

        // Exactly what InstallerView.start() does on Rescan: tear the old child
        // down and relaunch, synchronously, on main.
        let stale = expectation(description: "no exit is reported for the new child")
        stale.isInverted = true
        pty.onOutput = { _ in }
        pty.onExit = { _ in stale.fulfill() }
        pty.terminate()
        try? pty.launch("/bin/cat", [])

        // The second `cat` is still alive, so a fired onExit can only be the
        // first child's SIGTERM leaking across the relaunch.
        wait(for: [stale], timeout: 2)
        pty.onExit = nil        // the teardown SIGTERM must not fulfil a settled expectation
        pty.terminate()
    }

    /// The other half of the same guarantee: retiring the old generation must not
    /// cost the NEW child its own exit report.
    func testPTYTask_relaunchWhileRunning_stillReportsTheNewChildsExit() {
        let pty = PTYTask()
        pty.onOutput = { _ in }
        try? pty.launch("/bin/cat", [])

        let exited = expectation(description: "the new child's exit is reported")
        pty.onExit = { _ in exited.fulfill() }
        pty.terminate()
        try? pty.launch("/bin/echo", ["done"])   // prints, then exits → pty EOF
        wait(for: [exited], timeout: 5)
    }

    func testHost_scanSelectConfirm_drivesKeystrokesAndFinishes() {
        let fake = FakePTY()
        // Large tick interval so the real timer never fires; we step manually.
        // Injected executable path → no dependency on `mo` being installed;
        // the FakePTY's launch() ignores the path entirely.
        let runner = MoInteractiveRunner(subcommand: "installer", title: "Installers",
                                         pty: fake, tickInterval: 999,
                                         executablePath: "/fake/mo")
        runner.start()
        XCTAssertTrue(fake.launched)

        // Mole renders the list → host reaches `choosing`.
        fake.emit(scanFrame)
        XCTAssertEqual(runner.phase, .choosing)
        XCTAssertEqual(runner.items.map(\.name), ["a.dmg", "b.dmg", "c.dmg"])

        // User removes b → host sends the toggle keystrokes and enters `applying`.
        runner.confirm([1])
        XCTAssertEqual(runner.phase, .applying)
        XCTAssertFalse(fake.sent.isEmpty, "selection keystrokes were written to the pty")

        // Mole redraws with b checked; two ticks settle + verify → proceed (Enter).
        fake.emit(selectedFrame)
        runner.tick(); runner.tick()

        // Mole's confirm screen; the next tick confirms because the count matches.
        fake.emit("➤ Delete 1 installers, 760KB  Enter confirm, ESC cancel: ")
        runner.tick()
        XCTAssertTrue(fake.sent.contains(0x0d), "the confirming Enter reached the pty")

        // Mole prints its result and exits → host finishes.
        fake.emit("\nRemoved 1 installer, freed 760KB\n")
        fake.exitProcess(0)
        XCTAssertEqual(runner.phase, .done(0))
        XCTAssertTrue(runner.resultText.contains("Removed 1 installer"))
    }
}
