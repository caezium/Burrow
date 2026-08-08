//
//  CrashReporterPolicyTests.swift
//  BurrowTests
//

import XCTest
import Sentry
@testable import Burrow

final class CrashReporterPolicyTests: XCTestCase {
    func testSensitiveCapturedEventIsScrubbedBeforeTransport() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SentrySensitiveEvent.json")
        let fixture = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL))
                as? [String: Any]
        )
        let exceptionFixture = try XCTUnwrap(fixture["exception"] as? [String: Any])
        let frameFixture = try XCTUnwrap(fixture["frame"] as? [String: Any])
        let debugFixture = try XCTUnwrap(fixture["debugMeta"] as? [String: Any])

        let frame = Frame()
        frame.function = frameFixture["function"] as? String
        frame.module = frameFixture["module"] as? String
        frame.package = frameFixture["package"] as? String
        frame.fileName = frameFixture["fileName"] as? String
        frame.contextLine = frameFixture["contextLine"] as? String
        frame.preContext = ["sk-live-SECRET"]
        frame.postContext = ["/Users/alice/Documents/customer.txt"]
        frame.imageAddress = frameFixture["imageAddress"] as? String
        frame.instructionAddress = frameFixture["instructionAddress"] as? String
        frame.symbolAddress = frameFixture["symbolAddress"] as? String
        frame.vars = frameFixture["vars"] as? [String: Any]
        let stacktrace = SentryStacktrace(
            frames: [frame],
            registers: ["x0": "sk-live-SECRET", "sp": "0x100001234"]
        )

        let mechanism = Mechanism(type: exceptionFixture["mechanismType"] as! String)
        mechanism.desc = exceptionFixture["mechanismDescription"] as? String
        mechanism.helpLink = exceptionFixture["mechanismHelp"] as? String
        mechanism.data = exceptionFixture["mechanismData"] as? [String: Any]
        let exception = Exception(
            value: exceptionFixture["value"] as? String,
            type: exceptionFixture["type"] as? String
        )
        exception.module = exceptionFixture["module"] as? String
        exception.mechanism = mechanism
        exception.stacktrace = stacktrace

        let debugMeta = DebugMeta()
        debugMeta.debugID = debugFixture["debugID"] as? String
        debugMeta.type = debugFixture["type"] as? String
        debugMeta.codeFile = debugFixture["codeFile"] as? String
        debugMeta.imageAddress = debugFixture["imageAddress"] as? String
        debugMeta.imageVmAddress = debugFixture["imageVmAddress"] as? String

        let event = Event()
        event.exceptions = [exception]
        event.stacktrace = stacktrace
        event.context = fixture["contexts"] as? [String: [String: Any]]
        event.debugMeta = [debugMeta]
        event.fingerprint = ["burrow-app-hang", "launch_started", "/Users/alice/Secret.swift"]

        CrashReporter.scrubForTransport(event)
        let serialized = try JSONSerialization.data(withJSONObject: event.serialize())
        let outbound = try XCTUnwrap(String(data: serialized, encoding: .utf8))

        for sensitive in [
            "sk-live-SECRET", "alice", "customer.txt", "/Users/", "Downloads",
            "--upload", "example.com/private",
        ] {
            XCTAssertFalse(outbound.localizedCaseInsensitiveContains(sensitive), outbound)
        }
        XCTAssertTrue(outbound.contains("0.11.2"), outbound)
        XCTAssertTrue(outbound.contains("B7C38183-66CD-4C76-895A-150D17B4E2D7"), outbound)
        XCTAssertTrue(outbound.contains("0x100001234"), outbound)
    }

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
