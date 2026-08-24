//
//  UpdateCheckTests.swift
//  BurrowTests
//
//  Version comparison remains shared by the Updates inventory for apps that
//  publish version strings. Burrow's own updates are selected and verified by
//  Sparkle, whose native updater replaces the old GitHub/Homebrew path.
//

import XCTest
import Sparkle
@testable import Burrow

final class UpdateCheckTests: XCTestCase {
    func testIsNewer_numericPerComponent() {
        XCTAssertTrue(UpdateCheck.isNewer("0.7.0", than: "0.6.7"))
        XCTAssertTrue(UpdateCheck.isNewer("0.6.10", than: "0.6.9"))
        XCTAssertFalse(UpdateCheck.isNewer("0.6.7", than: "0.6.7"))
        XCTAssertFalse(UpdateCheck.isNewer("0.6.7", than: "0.7.0"))
        XCTAssertTrue(UpdateCheck.isNewer("1.0", than: "0.9.9"))   // shorter remote
        XCTAssertTrue(UpdateCheck.isNewer("0.6.7.1", than: "0.6.7")) // greenlight:ignore hardcoded-ipv4 — version fixture
    }

    func testIsNewer_toleratesLeadingV() {
        XCTAssertTrue(UpdateCheck.isNewer("v0.7.0", than: "0.6.7"))
        XCTAssertFalse(UpdateCheck.isNewer("v0.6.7", than: "v0.6.7"))
    }

    func testAutomaticCheckToggleStartsUpdaterOnlyWhenEnabled() {
        XCTAssertFalse(UpdateStartPolicy.shouldStartForAutomaticChecks(enabled: false))
        XCTAssertTrue(UpdateStartPolicy.shouldStartForAutomaticChecks(enabled: true))
    }

    func testManualUpdateRecoveryUsesCanonicalInstallPage() {
        XCTAssertEqual(
            UpdateRecovery.manualDownloadURL.absoluteString,
            "https://burrow.computer/install"
        )
    }

    func testTranslocatedSparkleFailureRequiresMovingTheAppWithoutCreatingASentryIssue() {
        let error = NSError(domain: SUSparkleErrorDomain, code: 1005)

        let failure = UpdateFailurePolicy.classify(error)

        XCTAssertEqual(failure.category, .appTranslocation)
        XCTAssertEqual(failure.recovery, .moveToApplications)
        XCTAssertFalse(failure.shouldCaptureInSentry)
    }

    func testOfflineDownloadFailureUsesSparklesScheduledRetryAndKeepsOnlyBoundedCauseFields() {
        let underlying = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet,
            userInfo: [NSLocalizedDescriptionKey: "private network detail"]
        )
        let error = NSError(
            domain: SUSparkleErrorDomain,
            code: 2001,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )

        let failure = UpdateFailurePolicy.classify(error)
        let properties = UpdateFailurePolicy.telemetryProperties(for: error)

        XCTAssertEqual(failure.category, .transientDownload)
        XCTAssertEqual(failure.recovery, .sparkleScheduledRetry)
        XCTAssertFalse(failure.shouldCaptureInSentry)
        XCTAssertEqual(properties["underlying_error_domain"] as? String, NSURLErrorDomain)
        XCTAssertEqual(properties["underlying_error_code"] as? Int, NSURLErrorNotConnectedToInternet)
        XCTAssertEqual(properties["failure_category"] as? String, "transient_download")
        XCTAssertEqual(properties["recovery"] as? String, "sparkle_scheduled_retry")
        XCTAssertNil(properties["description"])
    }

    func testUserCancelledUpdateDoesNotCreateASentryIssue() {
        let error = NSError(domain: SUSparkleErrorDomain, code: 4007)

        let failure = UpdateFailurePolicy.classify(error)

        XCTAssertEqual(failure.category, .cancelled)
        XCTAssertEqual(failure.recovery, .none)
        XCTAssertFalse(failure.shouldCaptureInSentry)
    }

    func testNonSparkleErrorWithCancellationCodeRemainsActionable() {
        let error = NSError(domain: "ExampleDomain", code: 4007)

        let failure = UpdateFailurePolicy.classify(error)

        XCTAssertEqual(failure.category, .other)
        XCTAssertEqual(failure.recovery, .none)
        XCTAssertTrue(failure.shouldCaptureInSentry)
    }

    func testSignatureFailureRemainsADeveloperActionableSentryIssue() {
        let error = NSError(domain: SUSparkleErrorDomain, code: 3001)

        let failure = UpdateFailurePolicy.classify(error)

        XCTAssertEqual(failure.category, .signatureValidation)
        XCTAssertEqual(failure.recovery, .none)
        XCTAssertTrue(failure.shouldCaptureInSentry)
    }

    func testInvalidDownloadConfigurationStillCreatesASentryIssue() {
        let underlying = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL)
        let error = NSError(
            domain: SUSparkleErrorDomain,
            code: 2001,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )

        let failure = UpdateFailurePolicy.classify(error)

        XCTAssertEqual(failure.category, .configuration)
        XCTAssertEqual(failure.recovery, .none)
        XCTAssertTrue(failure.shouldCaptureInSentry)
    }

    func testDirectInvalidURLFailureIsConfigurationRatherThanTransientNetwork() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL)

        let failure = UpdateFailurePolicy.classify(error)

        XCTAssertEqual(failure.category, .configuration)
        XCTAssertEqual(failure.recovery, .none)
        XCTAssertTrue(failure.shouldCaptureInSentry)
    }

}
