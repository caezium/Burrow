//
//  TelemetryPolicyTests.swift
//  BurrowTests
//

import XCTest
@testable import Burrow

final class TelemetryPolicyTests: XCTestCase {
    func testFeatureRefreshInvalidationRejectsOldWorkAfterAReenable() {
        let gate = FeatureFlagRefreshGate()
        let original = gate.currentGeneration
        var enabled = true
        var effects: [String] = []
        gate.perform(ifCurrent: original, isEnabled: { enabled }) { effects.append("cache read") }
        gate.invalidate { enabled = false }
        gate.perform(ifCurrent: gate.currentGeneration, isEnabled: { enabled }) { effects.append("opted-out request") }
        gate.invalidate { enabled = true }
        gate.perform(ifCurrent: original, isEnabled: { enabled }) { effects.append("stale response") }
        gate.perform(ifCurrent: gate.currentGeneration, isEnabled: { enabled }) { effects.append("fresh request") }
        XCTAssertEqual(effects, ["cache read", "fresh request"])
    }

    func testFeatureRefreshFinishesAdmittedEffectsBeforeOptOut() {
        let gate = FeatureFlagRefreshGate()
        let generation = gate.currentGeneration
        let admitted = DispatchSemaphore(value: 0)
        let finishEffect = DispatchSemaphore(value: 0)
        let optOutStarted = DispatchSemaphore(value: 0)
        let complete = expectation(description: "effect and opt-out complete")
        complete.expectedFulfillmentCount = 2
        // Every access is under the gate, including the final snapshot below.
        var effects: [String] = []
        DispatchQueue.global().async {
            gate.perform(ifCurrent: generation, isEnabled: { true }) {
                effects.append("cache read")
                admitted.signal()
                finishEffect.wait()
                effects.append("request admitted")
            }
            complete.fulfill()
        }
        XCTAssertEqual(admitted.wait(timeout: .now() + 5), .success)
        DispatchQueue.global().async {
            optOutStarted.signal()
            gate.invalidate { effects.append("opt-out") }
            complete.fulfill()
        }
        XCTAssertEqual(optOutStarted.wait(timeout: .now() + 5), .success)
        finishEffect.signal()
        wait(for: [complete], timeout: 5)
        gate.perform(ifCurrent: gate.currentGeneration, isEnabled: { true }) {
            XCTAssertEqual(effects, ["cache read", "request admitted", "opt-out"])
        }
    }

    func testRedirectsStayOnTheOriginalHTTPSAuthority() {
        let original = URL(string: "https://us.i.posthog.com/decide/?v=3")!
        XCTAssertTrue(TelemetryRedirectDelegate.permits(from: original,
                                                       to: URL(string: "https://US.I.POSTHOG.COM:443/decide/")))
        for destination in ["https://other.example/decide/", "http://us.i.posthog.com/decide/", // greenlight:ignore http-not-https — rejection fixture
                            "https://us.i.posthog.com:444/decide/", "https://user@us.i.posthog.com/decide/"] {
            XCTAssertFalse(TelemetryRedirectDelegate.permits(from: original, to: URL(string: destination)))
        }
        XCTAssertFalse(TelemetryRedirectDelegate.permits(from: nil, to: original))
    }

    func testTransportDelegateCancelsRedirectBeforeForwardingTheBody() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = URL(string: "https://us.i.posthog.com/decide/?v=3")!
        var request = URLRequest(url: original)
        request.httpMethod = "POST"
        request.httpBody = Data("fixture-identifier".utf8)
        let task = session.dataTask(with: request) // Never resumed; no network.
        let response = HTTPURLResponse(url: original, statusCode: 307, httpVersion: nil, headerFields: nil)!
        let redirected = URLRequest(url: URL(string: "https://other.example/decide/")!)
        var called = false
        TelemetryRedirectDelegate().urlSession(session, task: task, willPerformHTTPRedirection: response,
                                              newRequest: redirected) { accepted in
            called = true
            XCTAssertNil(accepted)
        }
        XCTAssertTrue(called)
    }

    func testFlagExposurePassesTheEventGateWithoutAllowingArbitraryReservedNames() {
        XCTAssertTrue(Telemetry.isAllowedEventName("$feature_flag_called"))
        XCTAssertTrue(Telemetry.isAllowedEventName("feature_operation_completed"))
        XCTAssertFalse(Telemetry.isAllowedEventName("$identify"))
        XCTAssertFalse(Telemetry.isAllowedEventName("$feature_flag_called/secret"))
        XCTAssertFalse(Telemetry.isAllowedEventName("$feature_flag_called\n"))
        let properties = DiagnosticPrivacy.sanitize([
            "$feature_flag": "about_release_notes_link", "$feature_flag_response": true,
        ])
        XCTAssertEqual(properties["$feature_flag"] as? String, "about_release_notes_link")
        XCTAssertEqual(properties["$feature_flag_response"] as? Bool, true)
    }

    func testPostHogTransportRequiresHTTPS() {
        XCTAssertEqual(
            Telemetry.postHogEndpoint(host: "https://us.i.posthog.com")?.absoluteString,
            "https://us.i.posthog.com/batch"
        )
        XCTAssertNil(Telemetry.postHogEndpoint(host: "http://us.i.posthog.com")) // greenlight:ignore http-not-https — rejection fixture
        XCTAssertNil(Telemetry.postHogEndpoint(host: "not a url"))
        XCTAssertNil(Telemetry.postHogEndpoint(host: "https://identity@us.i.posthog.com"))
        XCTAssertNil(Telemetry.postHogEndpoint(host: "https://us.i.posthog.com?mode=test"))
    }

    func testTelemetryValuesAreCoarselyBucketed() {
        XCTAssertEqual(Telemetry.bytesBucket(42), "<1MB")
        XCTAssertEqual(Telemetry.countBucket(12), "10-99")
        XCTAssertEqual(Telemetry.secondsBucket(31), "30-120s")
    }

    func testDeliveryPolicyRetriesOnlyTransientFailures() {
        XCTAssertEqual(
            Telemetry.deliveryDisposition(statusCode: 204, hasTransportError: false),
            .delivered
        )
        XCTAssertEqual(
            Telemetry.deliveryDisposition(statusCode: nil, hasTransportError: true),
            .retry
        )
        XCTAssertEqual(
            Telemetry.deliveryDisposition(statusCode: 429, hasTransportError: false),
            .retry
        )
        XCTAssertEqual(
            Telemetry.deliveryDisposition(statusCode: 503, hasTransportError: false),
            .retry
        )
        XCTAssertEqual(
            Telemetry.deliveryDisposition(statusCode: 400, hasTransportError: false),
            .discard
        )
        XCTAssertEqual(
            Telemetry.deliveryDisposition(statusCode: 401, hasTransportError: false),
            .discard
        )
    }

    func testOutboxRetryBackoffIsBounded() {
        XCTAssertEqual(Telemetry.retryDelay(afterFailure: 1), 30)
        XCTAssertEqual(Telemetry.retryDelay(afterFailure: 2), 60)
        XCTAssertEqual(Telemetry.retryDelay(afterFailure: 8), 3_600)
        XCTAssertEqual(Telemetry.retryDelay(afterFailure: 100), 3_600)
    }

    func testLegacyPostHogAnonymousIDMigratesWithoutChangingIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-posthog-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let projectKey = "analytics-project"
        let legacyDirectory = root
            .appendingPathComponent("dev.caezium.Burrow", isDirectory: true)
            .appendingPathComponent(projectKey, isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let anonymousID = UUID().uuidString.lowercased()
        let legacyPayload = try JSONSerialization.data(withJSONObject: [
            "posthog.anonymousId": anonymousID,
        ])
        try legacyPayload.write(
            to: legacyDirectory.appendingPathComponent("posthog.anonymousId"),
            options: .atomic
        )

        let destination = root
            .appendingPathComponent("Burrow", isDirectory: true)
            .appendingPathComponent("telemetry-id")
        XCTAssertEqual(
            Telemetry.migrateLegacyPostHogAnonymousID(
                projectKey: projectKey,
                applicationSupportRoot: root,
                destination: destination
            ),
            anonymousID
        )
        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8),
            anonymousID
        )
    }

    func testLegacyPostHogMigrationRejectsInvalidIDsAndUnsafeProjectPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-posthog-rejection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let projectKey = "analytics-project"
        let legacyDirectory = root
            .appendingPathComponent("dev.caezium.Burrow", isDirectory: true)
            .appendingPathComponent(projectKey, isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacyPayload = try JSONSerialization.data(withJSONObject: [
            "posthog.anonymousId": "not-an-anonymous-uuid",
        ])
        try legacyPayload.write(
            to: legacyDirectory.appendingPathComponent("posthog.anonymousId"),
            options: .atomic
        )

        let destination = root.appendingPathComponent("telemetry-id")
        XCTAssertNil(
            Telemetry.migrateLegacyPostHogAnonymousID(
                projectKey: projectKey,
                applicationSupportRoot: root,
                destination: destination
            )
        )
        XCTAssertNil(
            Telemetry.migrateLegacyPostHogAnonymousID(
                projectKey: "../analytics-project",
                applicationSupportRoot: root,
                destination: destination
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testScreenViewsEmitOncePerVisiblePanePresentation() {
        var deduper = ScreenTelemetryDeduper()

        XCTAssertTrue(deduper.appeared(on: .home))
        XCTAssertFalse(deduper.appeared(on: .home))
        XCTAssertTrue(deduper.paneChanged(to: .settings))
        XCTAssertFalse(deduper.paneChanged(to: .settings))

        XCTAssertFalse(deduper.visibilityChanged(to: false, pane: .settings))
        XCTAssertFalse(deduper.paneChanged(to: .home))
        XCTAssertTrue(deduper.visibilityChanged(to: true, pane: .home))
        // SwiftUI may deliver this pane onChange after the visibility event;
        // it must not duplicate the reopened screen impression.
        XCTAssertFalse(deduper.paneChanged(to: .home))

        XCTAssertFalse(deduper.visibilityChanged(to: false, pane: .home))
        XCTAssertTrue(deduper.visibilityChanged(to: true, pane: .home))
    }
}
