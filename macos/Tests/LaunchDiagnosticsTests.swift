//
//  LaunchDiagnosticsTests.swift
//  BurrowTests
//

import XCTest
@testable import Burrow

final class LaunchDiagnosticsTests: XCTestCase {
    private let environment = RuntimeEnvironment(
        osVersion: "macOS 27.0.0",
        osMajorVersion: 27,
        osBuild: "26A5400a",
        architecture: "arm64",
        appVersion: "0.11.1",
        appBuild: "22"
    )

    func testMacOS27Beta4UsesStatusItemSafeMode() {
        let environment = RuntimeEnvironment(
            osVersion: "macOS 27.0.0",
            osMajorVersion: 27,
            osBuild: "26A5388g",
            architecture: "arm64",
            appVersion: "0.11.0",
            appBuild: "21"
        )

        XCTAssertEqual(
            LaunchRecovery.reason(environment: environment, previous: nil),
            .macOS27Beta4
        )
    }

    func testLaterMacOS27BuildKeepsStatusItemEnabled() {
        XCTAssertNil(LaunchRecovery.reason(environment: environment, previous: nil))
    }

    func testNormalInitialStatusItemCreationIsDeferredPastTheLaunchTurn() {
        XCTAssertTrue(
            StatusItemStartupPolicy.shouldScheduleInitialCreation(
                showMenuBarIcon: true,
                recoveryReason: nil
            )
        )
        XCTAssertGreaterThanOrEqual(
            StatusItemStartupPolicy.initialDelayNanoseconds,
            1_000_000_000
        )
    }

    func testCompatibilityAndIconDisabledLaunchesDoNotScheduleAStatusItem() {
        XCTAssertFalse(
            StatusItemStartupPolicy.shouldScheduleInitialCreation(
                showMenuBarIcon: false,
                recoveryReason: nil
            )
        )
        XCTAssertFalse(
            StatusItemStartupPolicy.shouldScheduleInitialCreation(
                showMenuBarIcon: true,
                recoveryReason: .macOS27Beta4
            )
        )
    }

    /// Safe mode engages on the SECOND consecutive interrupted creation, not
    /// the first. One interrupted launch is indistinguishable from a force
    /// quit or a restart during startup; a real freeze reproduces every time.
    func testInterruptedStatusItemCreationUsesSafeModeOnNextLaunch() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-launch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let first = LaunchJournal(fileURL: fileURL, now: { Date(timeIntervalSince1970: 100) })
        XCTAssertNil(first.begin(environment: environment))
        first.mark(.statusItemCreating)

        // One strike: suspicious, but not yet acted on.
        let second = LaunchJournal(fileURL: fileURL, now: { Date(timeIntervalSince1970: 110) })
        let afterOne = second.begin(environment: environment)
        XCTAssertEqual(afterOne?.phase, .statusItemCreating)
        XCTAssertNil(LaunchRecovery.reason(environment: environment, previous: afterOne),
                     "a single interrupted launch must not cost the user the menu bar")
        second.mark(.statusItemCreating)

        // Two in a row on the same build: now it engages.
        let third = LaunchJournal(fileURL: fileURL, now: { Date(timeIntervalSince1970: 120) })
        let afterTwo = third.begin(environment: environment)
        XCTAssertEqual(
            LaunchRecovery.reason(environment: environment, previous: afterTwo),
            .previousStatusItemFailure
        )
    }

    func testNormallyTerminatedLaunchIsNotReportedAsIncomplete() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-launch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let first = LaunchJournal(fileURL: fileURL)
        XCTAssertNil(first.begin(environment: environment))
        first.mark(.appReady)
        first.mark(.terminatedNormally)

        let second = LaunchJournal(fileURL: fileURL)
        XCTAssertNil(second.begin(environment: environment))
    }

    func testStatusItemRecoveryPersistsUntilTheOSBuildChanges() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-launch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        // Two consecutive interrupted launches to reach the threshold.
        let failed = LaunchJournal(fileURL: fileURL)
        failed.begin(environment: environment)
        failed.mark(.statusItemCreating)

        let failedAgain = LaunchJournal(fileURL: fileURL)
        failedAgain.begin(environment: environment)
        failedAgain.mark(.statusItemCreating)

        let recovery = LaunchJournal(fileURL: fileURL)
        recovery.begin(environment: environment)
        recovery.mark(.appReady)
        recovery.mark(.terminatedNormally)

        let next = LaunchJournal(fileURL: fileURL)
        let last = next.lastRecord()
        XCTAssertNil(next.begin(environment: environment))
        XCTAssertEqual(
            LaunchRecovery.reason(environment: environment, previous: last),
            .previousStatusItemFailure
        )

        let updatedOS = RuntimeEnvironment(
            osVersion: "macOS 27.0.0",
            osMajorVersion: 27,
            osBuild: "26A5401b",
            architecture: "arm64",
            appVersion: "0.11.1",
            appBuild: "22"
        )
        XCTAssertNil(LaunchRecovery.reason(environment: updatedOS, previous: last))
    }

    func testStatusItemThatNeverStabilizedRecoversEvenAfterAppReady() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-launch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        // The freeze this guards against hangs WindowServer AFTER the item
        // exists, so the phase reads appReady rather than statusItemCreating.
        // It reproduces every launch, so two runs reach the threshold.
        let launch = LaunchJournal(fileURL: fileURL)
        launch.begin(environment: environment)
        launch.mark(.statusItemCreating)
        launch.mark(.statusItemReady)
        launch.mark(.appReady)

        let again = LaunchJournal(fileURL: fileURL)
        again.begin(environment: environment)
        again.mark(.statusItemCreating)
        again.mark(.statusItemReady)
        again.mark(.appReady)

        let previous = again.snapshot()
        XCTAssertEqual(
            LaunchRecovery.reason(environment: environment, previous: previous),
            .previousStatusItemFailure
        )
    }

    func testInterruptedStatusItemGetsFreshAttemptAfterOSUpdate() {
        let previousEnvironment = RuntimeEnvironment(
            osVersion: environment.osVersion,
            osMajorVersion: environment.osMajorVersion,
            osBuild: "26A5399z",
            architecture: environment.architecture,
            appVersion: environment.appVersion,
            appBuild: environment.appBuild
        )
        let previous = LaunchRecord(
            runID: UUID().uuidString,
            environment: previousEnvironment,
            phase: .statusItemCreating,
            startedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 101),
            statusItemAttempted: true,
            statusItemStable: false
        )

        XCTAssertNil(LaunchRecovery.reason(environment: environment, previous: previous))
    }

    func testStabilizedStatusItemDoesNotTriggerRecovery() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-launch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let launch = LaunchJournal(fileURL: fileURL)
        launch.begin(environment: environment)
        launch.mark(.statusItemCreating)
        launch.mark(.statusItemReady)
        launch.markStatusItemStable()
        launch.mark(.appReady)

        XCTAssertNil(LaunchRecovery.reason(environment: environment, previous: launch.snapshot()))
    }

    func testStabilizedStatusItemEnabledAfterLaunchDoesNotTriggerRecovery() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-launch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let launch = LaunchJournal(fileURL: fileURL)
        launch.begin(environment: environment)
        launch.mark(.appReady)
        launch.mark(.statusItemCreating)
        launch.mark(.statusItemReady)
        launch.markStatusItemStable()

        XCTAssertNil(LaunchRecovery.reason(environment: environment, previous: launch.snapshot()))
    }

    func testIntentionallyDisabledStatusItemDoesNotTriggerRecovery() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-launch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let launch = LaunchJournal(fileURL: fileURL)
        launch.begin(environment: environment)
        launch.mark(.statusItemCreating)
        launch.mark(.statusItemReady)
        launch.markStatusItemDisabled()

        XCTAssertNil(LaunchRecovery.reason(environment: environment, previous: launch.snapshot()))
    }

    func testInterruptedAutomaticUpdaterIsSuppressedUntilAppOrOSChanges() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-launch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let failed = LaunchJournal(fileURL: fileURL)
        failed.begin(environment: environment)
        failed.mark(.updaterScheduled)

        let recovery = LaunchJournal(fileURL: fileURL)
        let previous = recovery.begin(environment: environment)
        XCTAssertEqual(
            AutomaticUpdateRecovery.reason(environment: environment, previous: previous),
            .previousAutomaticUpdaterFailure
        )
        recovery.mark(.appReady)
        recovery.mark(.terminatedNormally)

        let persisted = LaunchJournal(fileURL: fileURL).lastRecord()
        XCTAssertEqual(
            AutomaticUpdateRecovery.reason(environment: environment, previous: persisted),
            .previousAutomaticUpdaterFailure
        )

        let updatedApp = RuntimeEnvironment(
            osVersion: environment.osVersion,
            osMajorVersion: environment.osMajorVersion,
            osBuild: environment.osBuild,
            architecture: environment.architecture,
            appVersion: "0.11.2",
            appBuild: "23"
        )
        XCTAssertNil(AutomaticUpdateRecovery.reason(environment: updatedApp, previous: persisted))

        let explicitRetry = LaunchJournal(fileURL: fileURL)
        explicitRetry.begin(environment: environment)
        explicitRetry.mark(.updaterScheduled)
        explicitRetry.markAutomaticUpdaterStable()
        explicitRetry.mark(.updaterReady)
        explicitRetry.mark(.terminatedNormally)
        XCTAssertNil(
            AutomaticUpdateRecovery.reason(
                environment: environment,
                previous: LaunchJournal(fileURL: fileURL).lastRecord()
            )
        )
    }

    func testStableAutomaticUpdaterDoesNotTriggerRecovery() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-launch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let launch = LaunchJournal(fileURL: fileURL)
        launch.begin(environment: environment)
        launch.mark(.updaterScheduled)
        launch.markAutomaticUpdaterStable()
        launch.mark(.updaterReady)

        XCTAssertNil(
            AutomaticUpdateRecovery.reason(environment: environment, previous: launch.snapshot())
        )
    }

    func testInterruptedAutomaticUpdaterGetsFreshAttemptAfterAppUpdate() {
        let previousEnvironment = RuntimeEnvironment(
            osVersion: environment.osVersion,
            osMajorVersion: environment.osMajorVersion,
            osBuild: environment.osBuild,
            architecture: environment.architecture,
            appVersion: "0.11.0",
            appBuild: "21"
        )
        let previous = LaunchRecord(
            runID: UUID().uuidString,
            environment: previousEnvironment,
            phase: .updaterScheduled,
            startedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 101),
            automaticUpdaterAttempted: true,
            automaticUpdaterStable: false
        )

        XCTAssertNil(
            AutomaticUpdateRecovery.reason(environment: environment, previous: previous)
        )
    }

    func testRecoveryReportContainsUsefulContextWithoutUserPaths() {
        let unsafeEnvironment = RuntimeEnvironment(
            osVersion: "macOS 27.0.0",
            osMajorVersion: 27,
            osBuild: "26A5388g",
            architecture: "/Users/alice/private",
            appVersion: "0.11.0",
            appBuild: "21"
        )
        let previous = LaunchRecord(
            runID: "private-run-id",
            environment: unsafeEnvironment,
            phase: .statusItemCreating,
            startedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 104)
        )

        let report = LaunchDiagnosticReport.make(
            reason: .previousStatusItemFailure,
            previous: previous,
            current: environment,
            menuBarMode: "metrics"
        )

        XCTAssertTrue(report.contains("status_item_creating"))
        XCTAssertTrue(report.contains("26A5388g"))
        XCTAssertFalse(report.contains("alice"))
        XCTAssertFalse(report.contains("private-run-id"))
    }
}

// MARK: - Status-item guard false positives
//
// Burrow is a menu-bar app, so pausing the status item removes its primary
// surface. The suspicion rule is deliberately broad — it has to be, because
// the macOS 27 Beta 4 freeze hung WindowServer AFTER the item existed, so the
// next boot saw `.statusItemReady`, not `.statusItemCreating`.
//
// What was wrong is that ONE suspicion was enough to act on. That fires on a
// force quit, an unrelated crash, a jetsam kill, or Launch at Login followed
// by a restart — anything that kills the app inside the 30-second stability
// window — and the mark then persisted until the user updated macOS.
//
// Two consecutive occurrences are now required. A real freeze reproduces
// every launch, so it is still caught on the second run; a one-off never
// costs anyone their menu bar.

final class StatusItemGuardFalsePositiveTests: XCTestCase {

    private func environment(build: String = "25F84", major: Int = 26) -> RuntimeEnvironment {
        RuntimeEnvironment(osVersion: "macOS 26.5.2", osMajorVersion: major, osBuild: build,
                           architecture: "arm64", appVersion: "0.12.0", appBuild: "24")
    }

    private func record(phase: LaunchPhase,
                        build: String = "25F84",
                        attempted: Bool? = nil,
                        stable: Bool? = nil,
                        unsafeBuild: String? = nil,
                        streak: Int? = nil) -> LaunchRecord {
        LaunchRecord(runID: UUID().uuidString,
                     environment: environment(build: build),
                     phase: phase,
                     startedAt: Date(timeIntervalSince1970: 100),
                     updatedAt: Date(timeIntervalSince1970: 120),
                     statusItemUnsafeOSBuild: unsafeBuild,
                     statusItemAttempted: attempted,
                     statusItemStable: stable,
                     statusItemFailureStreak: streak)
    }

    /// The reported bug: one abnormal exit with the item up must not pause
    /// the menu bar. This is the force-quit / restart-after-login case.
    func testASingleBadExitDoesNotPauseTheMenuBar() {
        let previous = record(phase: .statusItemReady, attempted: true, stable: false, streak: 0)
        XCTAssertNil(LaunchRecovery.reason(environment: environment(), previous: previous),
                     "one unexplained exit is not evidence the status item is dangerous")
    }

    /// Launch at Login, then the user restarts before the 30-second stability
    /// timer elapses — shutdown can kill the app before
    /// applicationWillTerminate finishes. The most likely real-world path.
    func testRestartShortlyAfterLoginDoesNotPause() {
        let previous = record(phase: .appReady, attempted: true, stable: false, streak: 0)
        XCTAssertNil(LaunchRecovery.reason(environment: environment(), previous: previous))
    }

    /// But a REPEAT does pause — the freeze this guard exists for reproduces
    /// every launch.
    func testASecondConsecutiveFailurePauses() {
        let previous = record(phase: .statusItemReady, attempted: true, stable: false, streak: 1)
        XCTAssertEqual(LaunchRecovery.reason(environment: environment(), previous: previous),
                       .previousStatusItemFailure)
    }

    /// A launch that reached stable is positive proof the item works here, so
    /// the streak resets. Without this, a mark survived until the user updated
    /// macOS.
    func testAStableLaunchClearsTheStreak() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-launch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let env = environment()
        let journal = LaunchJournal(fileURL: fileURL)
        journal.begin(environment: env)
        journal.mark(.statusItemCreating)
        journal.mark(.statusItemReady)
        journal.markStatusItemStable()
        journal.mark(.terminatedNormally)

        let previous = journal.snapshot()
        XCTAssertNil(LaunchRecovery.reason(environment: env, previous: previous))
    }

    /// The exact-build macOS 27 Beta 4 guard is untouched and still immediate.
    func testMacOS27Beta4GuardStillAppliesWithNoHistory() {
        let beta = RuntimeEnvironment(osVersion: "macOS 27.0", osMajorVersion: 27,
                                      osBuild: "26A5388g", architecture: "arm64",
                                      appVersion: "0.12.0", appBuild: "24")
        XCTAssertEqual(LaunchRecovery.reason(environment: beta, previous: nil), .macOS27Beta4)
    }

    /// A clean exit never pauses anything.
    func testCleanExitNeverPauses() {
        let previous = record(phase: .terminatedNormally, attempted: true, stable: true)
        XCTAssertNil(LaunchRecovery.reason(environment: environment(), previous: previous))
    }

    /// An already-marked build keeps being refused while the mark stands.
    func testAnExistingUnsafeMarkIsStillHonoured() {
        let previous = record(phase: .terminatedNormally, unsafeBuild: "25F84")
        XCTAssertEqual(LaunchRecovery.reason(environment: environment(), previous: previous),
                       .previousStatusItemFailure)
    }

    /// A streak from a different macOS build does not carry over.
    func testStreakDoesNotCarryAcrossOSBuilds() {
        let previous = record(phase: .statusItemReady, build: "25F70",
                              attempted: true, stable: false, streak: 5)
        XCTAssertNil(LaunchRecovery.reason(environment: environment(build: "25F84"),
                                           previous: previous))
    }

    // MARK: - Credential-shaped labels

    /// The literal marker list matched `token=` only when written tight, so a
    /// space either side of the separator — or inside the name — was enough to
    /// carry a live credential into an uploaded diagnostic.
    func testSafeDiagnosticLabel_rejectsCredentialsWhateverTheSpacing() {
        for value in ["access_token = abc123", "api key=abc123", "API_KEY : abc123",
                      "auth-token=abc123", "refresh token = abc123", "token=abc123",
                      "Secret = hunter2", "password:hunter2"] {
            XCTAssertNil(DiagnosticPrivacy.safeDiagnosticLabel(value),
                         "\(value) must never reach a diagnostic")
        }
    }

    /// And it still keeps the symbol labels it exists to preserve — a rule that
    /// rejects everything would be just as useless as one that rejects nothing.
    func testSafeDiagnosticLabel_keepsOrdinarySymbolNames() {
        for value in ["NSStatusItem", "-[BurrowApp applicationDidFinishLaunching:]",
                      "Swift.String.init(cString:)", "main"] {
            XCTAssertEqual(DiagnosticPrivacy.safeDiagnosticLabel(value), value)
        }
    }
}
