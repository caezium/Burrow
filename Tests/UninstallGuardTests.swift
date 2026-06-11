//
//  UninstallGuardTests.swift
//  BurrowTests
//
//  The uninstall pre-flight parser is the safety interlock between the
//  user's confirm sheet and mo's own name matching (audit H4). Fixtures
//  are captured from the real `mo uninstall --dry-run` output, ANSI
//  escapes and clear-screen included.
//

import XCTest
@testable import Burrow

final class UninstallGuardTests: XCTestCase {

    // Captured verbatim from `mo uninstall --dry-run IDLE` (mole 1.x).
    private let singleAppFixture = """
    \u{1B}[0;33m→ DRY RUN MODE\u{1B}[0m, No app files or settings will be modified

    \u{1B}[2J\u{1B}[H\u{1B}[1;34m◎\u{1B}[0m Matched 1 app(s):
    1. IDLE  187KB  |  Last: 1y ago

    Proceed with uninstallation? [y/N]
    """

    private let multiAppFixture = """
    \u{1B}[2J\u{1B}[H\u{1B}[1;34m◎\u{1B}[0m Matched 3 app(s):
    1. Slack  120MB  |  Last: 2d ago
    2. Python Launcher  315KB  |  Last: 1y ago
    3. Zoom  80MB  |  Last: 5d ago

    Proceed with uninstallation? [y/N]
    """

    private let noneFixture = """
    \u{1B}[0;33mWarning:\u{1B}[0m No application found matching 'Nope'
    No matching applications found.
    """

    // MARK: - Parsing

    func testMatchedApps_parsesSingleApp() {
        XCTAssertEqual(UninstallGuard.matchedApps(inDryRunOutput: singleAppFixture), ["IDLE"])
    }

    func testMatchedApps_parsesMultipleAppsIncludingSpacedNames() {
        XCTAssertEqual(UninstallGuard.matchedApps(inDryRunOutput: multiAppFixture),
                       ["Slack", "Python Launcher", "Zoom"])
    }

    func testMatchedApps_emptyWhenNothingMatched() {
        XCTAssertEqual(UninstallGuard.matchedApps(inDryRunOutput: noneFixture), [])
    }

    func testMatchedApps_nilOnUnrecognizedOutput() {
        XCTAssertNil(UninstallGuard.matchedApps(inDryRunOutput: "Segmentation fault"),
                     "unknown output must parse to nil so the caller fails closed")
        XCTAssertNil(UninstallGuard.matchedApps(inDryRunOutput: ""))
    }

    // MARK: - Verdict

    func testMismatch_nilWhenSetsAgree() {
        XCTAssertNil(UninstallGuard.mismatchDescription(confirmed: ["IDLE"], matched: ["IDLE"]))
        XCTAssertNil(UninstallGuard.mismatchDescription(confirmed: ["Slack", "Zoom"],
                                                        matched: ["Zoom", "Slack"]),
                     "order must not matter")
        XCTAssertNil(UninstallGuard.mismatchDescription(confirmed: ["idle"], matched: ["IDLE"]),
                     "case must not matter — names echo mo's own canonical list")
    }

    func testMismatch_reportsExtraApps() {
        let desc = UninstallGuard.mismatchDescription(confirmed: ["Slack"],
                                                      matched: ["Slack", "Zoom"])
        let unwrapped = try! XCTUnwrap(desc)
        XCTAssertTrue(unwrapped.contains("Zoom"),
                      "the app mo would remove beyond the confirmation must be named")
    }

    func testMismatch_reportsMissingApps() {
        let desc = UninstallGuard.mismatchDescription(confirmed: ["Slack", "Zoom"],
                                                      matched: ["Slack"])
        let unwrapped = try! XCTUnwrap(desc)
        XCTAssertTrue(unwrapped.contains("Zoom"))
    }

    func testMismatch_countDivergenceAlwaysMismatches() {
        XCTAssertNotNil(UninstallGuard.mismatchDescription(confirmed: ["Slack"], matched: []))
        XCTAssertNotNil(UninstallGuard.mismatchDescription(confirmed: [], matched: ["Slack"]))
    }
}
