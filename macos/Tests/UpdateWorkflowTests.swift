//
//  UpdateWorkflowTests.swift
//  BurrowTests
//

import XCTest
import Foundation
import Darwin
@testable import Burrow

final class UpdateWorkflowTests: XCTestCase {
    func testHTTPFailuresRemainDistinctAndRetryableOnlyWhenRecoveryCanSucceed() {
        let offline = UpdateHTTP.classify(
            data: nil,
            response: nil,
            error: URLError(.notConnectedToInternet)
        )
        let timeout = UpdateHTTP.classify(
            data: nil,
            response: nil,
            error: URLError(.timedOut)
        )
        let forbidden = UpdateHTTP.classify(
            data: Data(),
            response: response(status: 403),
            error: nil
        )
        let server = UpdateHTTP.classify(
            data: Data(),
            response: response(status: 500),
            error: nil
        )

        XCTAssertEqual(offline, .failure(.offline))
        XCTAssertEqual(timeout, .failure(.timeout))
        XCTAssertEqual(forbidden, .failure(.http(status: 403, retryable: false)))
        XCTAssertEqual(server, .failure(.http(status: 500, retryable: true)))
    }

    func testNonHTTPAndEmptySuccessfulResponsesAreRejected() {
        XCTAssertEqual(
            UpdateHTTP.classify(
                data: Data("body".utf8),
                response: URLResponse(
                    url: URL(string: "file:///tmp/update")!,
                    mimeType: nil,
                    expectedContentLength: 4,
                    textEncodingName: nil
                ),
                error: nil
            ),
            .failure(.invalidResponse)
        )
        XCTAssertEqual(
            UpdateHTTP.classify(data: Data(), response: response(status: 200), error: nil),
            .failure(.decoding)
        )
    }

    func testElectronLatestYAMLRequiresVersionArchiveAndSHA512() {
        let yaml = """
        version: 4.2.0
        files:
          - url: Example-4.2.0-mac.zip
            sha512: YWJjZA==
        releaseDate: '2026-08-08T01:02:03.000Z'
        """

        let descriptor = ElectronUpdateDescriptor.parse(
            Data(yaml.utf8),
            relativeTo: URL(string: "https://updates.example.com/mac/latest-mac.yml")!
        )

        XCTAssertEqual(descriptor?.version, "4.2.0")
        XCTAssertEqual(descriptor?.archiveURL.absoluteString, "https://updates.example.com/mac/Example-4.2.0-mac.zip")
        XCTAssertEqual(descriptor?.sha512, Data("abcd".utf8))
        XCTAssertNil(ElectronUpdateDescriptor.parse(Data("version: 4.2.0".utf8), relativeTo: URL(string: "https://example.com/latest-mac.yml")!))
    }

    func testElectronGenericFeedConfigurationBuildsLatestMacURL() {
        let config = """
        provider: generic
        url: https://updates.example.com/releases/
        channel: latest
        """

        XCTAssertEqual(
            ElectronFeedConfiguration.parse(Data(config.utf8))?.latestYAMLURL.absoluteString,
            "https://updates.example.com/releases/latest-mac.yml"
        )
        XCTAssertNil(ElectronFeedConfiguration.parse(Data("provider: github\nowner: acme".utf8)))
        XCTAssertNil(ElectronFeedConfiguration.parse(Data("provider: generic\nurl: http://updates.example.com".utf8)))
    }

    func testElectronDescriptorRejectsPlainHTTPArchive() {
        let yaml = """
        version: 4.2.0
        path: http://updates.example.com/Example-4.2.0-mac.zip
        sha512: YWJjZA==
        """

        XCTAssertNil(ElectronUpdateDescriptor.parse(
            Data(yaml.utf8),
            relativeTo: URL(string: "https://updates.example.com/latest-mac.yml")!
        ))
    }

    func testPrivateStagingDirectoriesAreExclusiveUniqueAndOwnerOnly() throws {
        let first = try PrivateUpdateDirectory.create()
        let second = try PrivateUpdateDirectory.create()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.lastPathComponent.contains("UUID().uuidString"))
        XCTAssertFalse(second.lastPathComponent.contains("UUID().uuidString"))
        var firstStat = stat()
        var secondStat = stat()
        XCTAssertEqual(lstat(first.path, &firstStat), 0)
        XCTAssertEqual(lstat(second.path, &secondStat), 0)
        XCTAssertEqual(firstStat.st_mode & mode_t(0o777), mode_t(0o700))
        XCTAssertEqual(secondStat.st_mode & mode_t(0o777), mode_t(0o700))
    }

    func testReplacementIdentityRejectsBundleOrSigningIdentityChanges() {
        let expected = BundleUpdateIdentity(
            bundleID: "com.example.App",
            signingIdentifier: "com.example.App",
            teamIdentifier: "TEAM123",
            signatureValid: true
        )

        XCTAssertEqual(expected.verificationFailure(comparedWith: expected), nil)
        XCTAssertEqual(
            expected.verificationFailure(comparedWith: .init(
                bundleID: "com.attacker.App",
                signingIdentifier: "com.attacker.App",
                teamIdentifier: "TEAM123",
                signatureValid: true
            )),
            .bundleIdentityChanged
        )
        XCTAssertEqual(
            expected.verificationFailure(comparedWith: .init(
                bundleID: "com.example.App",
                signingIdentifier: "com.example.App",
                teamIdentifier: "OTHER",
                signatureValid: true
            )),
            .signingIdentityChanged
        )
        XCTAssertEqual(
            expected.verificationFailure(comparedWith: .init(
                bundleID: "com.example.App",
                signingIdentifier: "com.example.App",
                teamIdentifier: "TEAM123",
                signatureValid: false
            )),
            .invalidSignature
        )
    }

    func testReplacementBoundaryRereadsAndRejectsSwappedCandidate() {
        let expected = BundleUpdateIdentity(
            bundleID: "com.example.App",
            signingIdentifier: "com.example.App",
            teamIdentifier: "TEAM123",
            signatureValid: true
        )
        let staged = StagedElectronUpdate(
            targetURL: URL(fileURLWithPath: "/Applications/Example.app"),
            candidateURL: URL(fileURLWithPath: "/tmp/private/Candidate.app"),
            stagingDirectory: URL(fileURLWithPath: "/tmp/private"),
            expectedIdentity: expected
        )
        var reads: [URL] = []

        let failure = ElectronReplacementInstaller.boundaryVerificationFailure(for: staged) { url in
            reads.append(url)
            if url == staged.targetURL { return expected }
            return BundleUpdateIdentity(
                bundleID: expected.bundleID,
                signingIdentifier: expected.signingIdentifier,
                teamIdentifier: "ATTACKER",
                signatureValid: true
            )
        }

        XCTAssertEqual(reads, [staged.targetURL, staged.candidateURL])
        XCTAssertEqual(failure, .verification(.signingIdentityChanged))
    }

    func testUpdatePhaseExposesRecoveryAndAccessibleProgress() {
        XCTAssertTrue(UpdatePhase.failed(.offline).canRetry)
        XCTAssertEqual(UpdatePhase.downloading(progress: 0.42).accessibilityValue, "Downloading, 42 percent")
        XCTAssertEqual(UpdatePhase.readyToInstall.accessibilityValue, "Ready to install and restart")
        XCTAssertFalse(UpdatePhase.failed(.verification(.invalidSignature)).canRetry)
    }

    private func response(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://updates.example.com")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}
