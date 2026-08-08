//
//  CrashReporterPolicyTests.swift
//  BurrowTests
//

import XCTest
@testable import Burrow

final class CrashReporterPolicyTests: XCTestCase {
    func testAppHangLimiterKeepsFirstAndRateLimitsOnlyRepeats() {
        var limiter = AppHangRateLimiter(minimumInterval: 60)

        XCTAssertTrue(limiter.shouldKeep(group: "launch|frame_a", at: Date(timeIntervalSince1970: 100)))
        XCTAssertFalse(limiter.shouldKeep(group: "launch|frame_a", at: Date(timeIntervalSince1970: 120)))
        XCTAssertTrue(limiter.shouldKeep(group: "launch|frame_b", at: Date(timeIntervalSince1970: 120)))
        XCTAssertTrue(limiter.shouldKeep(group: "launch|frame_a", at: Date(timeIntervalSince1970: 160)))
    }

    func testDiagnosticPrivacyDropsSensitiveKeysAndRedactsPaths() {
        let result = DiagnosticPrivacy.sanitize([
            "phase": "status_item_creating",
            "detail": "/Users/alice/Downloads/Burrow.app",
            "url": "https://example.com/private",
            "request_url": "https://example.com/private",
            "message": "contact alice@example.com or open file:///Users/alice/report.txt",
            "count": 2,
        ])

        XCTAssertEqual(result["phase"] as? String, "status_item_creating")
        XCTAssertEqual(result["detail"] as? String, "<redacted-path>")
        XCTAssertNil(result["url"])
        XCTAssertNil(result["request_url"])
        XCTAssertEqual(
            result["message"] as? String,
            "contact <redacted-email> or open <redacted-url>"
        )
        XCTAssertEqual(result["count"] as? Int, 2)
    }

    func testDiagnosticPrivacyRedactsNonHomeAndWindowsPaths() {
        XCTAssertEqual(
            DiagnosticPrivacy.redact("open /Volumes/Private/Customer/Burrow.app"),
            "<redacted-path>"
        )
        XCTAssertEqual(
            DiagnosticPrivacy.redact(#"open C:\Users\alice\Private\Burrow.app"#),
            "<redacted-path>"
        )
        XCTAssertEqual(
            DiagnosticPrivacy.redact("open /Users/alice/My Documents/customer.txt"),
            "<redacted-path>"
        )
    }

    func testProfilingOnlyRunsFromApplications() {
        XCTAssertTrue(CrashReporter.isProfilingPathSafe(URL(fileURLWithPath: "/Applications/Burrow.app")))
        XCTAssertFalse(CrashReporter.isProfilingPathSafe(URL(fileURLWithPath: "/Users/alice/Downloads/Burrow.app")))
        XCTAssertFalse(CrashReporter.isProfilingPathSafe(URL(fileURLWithPath: "/Applications-old/Burrow.app")))
    }

    func testOptOutAbandonsRatherThanFinishesActiveLaunchTrace() {
        XCTAssertTrue(LaunchTraceEndReason.completed.shouldFinish)
        XCTAssertFalse(LaunchTraceEndReason.telemetryDisabled.shouldFinish)
    }

    func testUpdaterDiagnosticContextKeepsOnlyBoundedClassificationFields() {
        XCTAssertTrue(CrashReporter.diagnosticContextFields.contains("failure_category"))
        XCTAssertTrue(CrashReporter.diagnosticContextFields.contains("recovery"))
        XCTAssertTrue(CrashReporter.diagnosticContextFields.contains("underlying_error_domain"))
        XCTAssertTrue(CrashReporter.diagnosticContextFields.contains("underlying_error_code"))
        XCTAssertFalse(CrashReporter.diagnosticContextFields.contains("description"))
        XCTAssertFalse(CrashReporter.diagnosticContextFields.contains("url"))
    }
}
