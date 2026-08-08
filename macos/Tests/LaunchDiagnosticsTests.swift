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

    func testInterruptedStatusItemCreationUsesSafeModeOnNextLaunch() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-launch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let first = LaunchJournal(fileURL: fileURL, now: { Date(timeIntervalSince1970: 100) })
        XCTAssertNil(first.begin(environment: environment))
        first.mark(.statusItemCreating)

        let second = LaunchJournal(fileURL: fileURL, now: { Date(timeIntervalSince1970: 110) })
        let previous = second.begin(environment: environment)
        XCTAssertEqual(previous?.phase, .statusItemCreating)
        XCTAssertEqual(
            LaunchRecovery.reason(environment: environment, previous: previous),
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

        let failed = LaunchJournal(fileURL: fileURL)
        failed.begin(environment: environment)
        failed.mark(.statusItemCreating)

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

        let launch = LaunchJournal(fileURL: fileURL)
        launch.begin(environment: environment)
        launch.mark(.statusItemCreating)
        launch.mark(.statusItemReady)
        launch.mark(.appReady)

        let previous = launch.snapshot()
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
