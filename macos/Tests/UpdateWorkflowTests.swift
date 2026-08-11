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
        // These used to assert the name did not contain the literal source text
        // "UUID().uuidString", which no filesystem path could ever contain — so
        // they passed no matter what create() produced. Assert the real mkdtemp
        // shape instead: the fixed prefix and six substituted characters.
        for url in [first, second] {
            let name = url.lastPathComponent
            XCTAssertTrue(name.hasPrefix("BurrowUpdate."),
                          "unexpected staging name: \(name)")
            let suffix = name.dropFirst("BurrowUpdate.".count)
            XCTAssertEqual(suffix.count, 6, "mkdtemp substitutes exactly the six Xs: \(name)")
            // NOT "contains no X": mkdtemp draws the replacement characters from
            // an alphanumeric set that includes 'X', so a legitimate name like
            // BurrowUpdate.YmzfxX failed that check roughly one run in eight.
            // The real failure being guarded against is the template surviving
            // whole, so test for that and for the charset.
            XCTAssertNotEqual(suffix, "XXXXXX", "the template was never substituted: \(name)")
            XCTAssertTrue(suffix.allSatisfy { $0.isLetter || $0.isNumber },
                          "mkdtemp suffix must be alphanumeric: \(name)")
        }
        var firstStat = stat()
        var secondStat = stat()
        XCTAssertEqual(lstat(first.path, &firstStat), 0)
        XCTAssertEqual(lstat(second.path, &secondStat), 0)
        XCTAssertEqual(firstStat.st_mode & mode_t(0o777), mode_t(0o700))
        XCTAssertEqual(secondStat.st_mode & mode_t(0o777), mode_t(0o700))
    }

    func testStagedDiscardRemovesOnlyThePinnedStagingRoot() throws {
        let root = try PrivateUpdateDirectory.create()
        let identity = try XCTUnwrap(ElectronReplacementInstaller.stagingDirectoryIdentity(at: root))
        let marker = root.appendingPathComponent("marker")
        try Data("owned".utf8).write(to: marker)
        let staged = stagedUpdateForCleanup(root: root, identity: identity)

        staged.discard()

        XCTAssertFalse(ElectronReplacementInstaller.pathEntryExists(at: root))
    }

    func testStagedDiscardPreservesReplacementTreeAfterRootSwap() throws {
        let root = try PrivateUpdateDirectory.create()
        let movedRoot = root.deletingLastPathComponent().appendingPathComponent("Moved Cleanup \(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: movedRoot)
        }
        let identity = try XCTUnwrap(ElectronReplacementInstaller.stagingDirectoryIdentity(at: root))
        let staged = stagedUpdateForCleanup(root: root, identity: identity)
        try FileManager.default.moveItem(at: root, to: movedRoot)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let replacementMarker = root.appendingPathComponent("replacement-marker")
        try Data("must survive".utf8).write(to: replacementMarker)

        staged.discard()

        XCTAssertTrue(FileManager.default.fileExists(atPath: replacementMarker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedRoot.path))
    }

    func testDescriptorBoundDiscardPreservesTreeSwappedAfterRootFstat() throws {
        let root = try PrivateUpdateDirectory.create()
        let capturedRoot = root.deletingLastPathComponent().appendingPathComponent(
            "Captured Cleanup \(UUID().uuidString)"
        )
        var replacementQuarantine: URL?
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: capturedRoot)
            if let replacementQuarantine {
                try? FileManager.default.removeItem(at: replacementQuarantine)
            }
        }
        let identity = try XCTUnwrap(ElectronReplacementInstaller.stagingDirectoryIdentity(at: root))
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Nested"),
            withIntermediateDirectories: false
        )
        try Data("owned".utf8).write(to: root.appendingPathComponent("Nested/file"))

        PrivateUpdateDirectory.discard(
            at: root,
            expectedIdentity: identity,
            expectedCanonicalURL: canonicalRoot,
            afterOpeningPinnedRoot: { quarantineURL in
                replacementQuarantine = quarantineURL
                try! FileManager.default.moveItem(at: quarantineURL, to: capturedRoot)
                try! FileManager.default.createDirectory(at: quarantineURL, withIntermediateDirectories: false)
                try! Data("must survive".utf8).write(
                    to: quarantineURL.appendingPathComponent("replacement-marker")
                )
            }
        )

        let quarantineURL = try XCTUnwrap(replacementQuarantine)
        XCTAssertEqual(
            try Data(contentsOf: quarantineURL.appendingPathComponent("replacement-marker")),
            Data("must survive".utf8)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: capturedRoot.path))
    }

    func testDescriptorBoundDiscardRemovesNestedTreeWithoutFollowingSymlinks() throws {
        let root = try PrivateUpdateDirectory.create()
        let outside = try PrivateUpdateDirectory.create()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let identity = try XCTUnwrap(ElectronReplacementInstaller.stagingDirectoryIdentity(at: root))
        let nested = root.appendingPathComponent("One/Two", isDirectory: true)
        let outsideMarker = outside.appendingPathComponent("outside-marker")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: nested.appendingPathComponent("inside-file"))
        try Data("outside".utf8).write(to: outsideMarker)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("outside-link"),
            withDestinationURL: outside
        )

        PrivateUpdateDirectory.discard(
            at: root,
            expectedIdentity: identity,
            expectedCanonicalURL: root.resolvingSymlinksInPath().standardizedFileURL
        )

        XCTAssertFalse(ElectronReplacementInstaller.pathEntryExists(at: root))
        XCTAssertEqual(try Data(contentsOf: outsideMarker), Data("outside".utf8))
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
        let expected = pinnedIdentity(version: "1.0.0", build: "100", hash: "target", inode: 10)
        let candidate = pinnedIdentity(version: "2.0.0", build: "200", hash: "candidate", inode: 20)
        let staged = stagedUpdate(target: expected, candidate: candidate)
        var reads: [URL] = []

        let failure = ElectronReplacementInstaller.boundaryVerificationFailure(
            for: staged,
            validateCandidateLocation: { _ in nil }
        ) { url in
            reads.append(url)
            if url == staged.targetURL { return expected }
            return BundleUpdateIdentity(
                bundleID: expected.bundleID,
                signingIdentifier: expected.signingIdentifier,
                teamIdentifier: "ATTACKER",
                signatureValid: true,
                version: candidate.version,
                build: candidate.build,
                codeDirectoryHash: candidate.codeDirectoryHash,
                fileIdentity: candidate.fileIdentity
            )
        }

        XCTAssertEqual(reads, [staged.targetURL, staged.candidateURL])
        XCTAssertEqual(failure, .verification(.signingIdentityChanged))
    }

    func testReplacementBoundaryRejectsTargetChangedToNewerSameSignerBuild() {
        let target = BundleUpdateIdentity(
            bundleID: "com.example.App",
            signingIdentifier: "com.example.App",
            teamIdentifier: "TEAM123",
            signatureValid: true,
            version: "1.0.0",
            build: "100",
            codeDirectoryHash: Data("target-v1".utf8),
            fileIdentity: .init(device: 1, inode: 10)
        )
        let candidate = BundleUpdateIdentity(
            bundleID: target.bundleID,
            signingIdentifier: target.signingIdentifier,
            teamIdentifier: target.teamIdentifier,
            signatureValid: true,
            version: "2.0.0",
            build: "200",
            codeDirectoryHash: Data("candidate-v2".utf8),
            fileIdentity: .init(device: 1, inode: 20)
        )
        let staged = stagedUpdate(target: target, candidate: candidate)
        let newerTarget = BundleUpdateIdentity(
            bundleID: target.bundleID,
            signingIdentifier: target.signingIdentifier,
            teamIdentifier: target.teamIdentifier,
            signatureValid: true,
            version: "3.0.0",
            build: "300",
            codeDirectoryHash: Data("target-v3".utf8),
            fileIdentity: .init(device: 1, inode: 30)
        )
        var reads: [URL] = []

        let failure = ElectronReplacementInstaller.boundaryVerificationFailure(
            for: staged,
            validateCandidateLocation: { _ in nil }
        ) { url in
            reads.append(url)
            return url == staged.targetURL ? newerTarget : candidate
        }

        XCTAssertEqual(reads, [staged.targetURL])
        XCTAssertEqual(failure, .verification(.artifactIdentityChanged))
    }

    func testReplacementBoundaryRejectsCandidateChangedToOlderSameSignerBuild() {
        let target = pinnedIdentity(version: "1.0.0", build: "100", hash: "target-v1", inode: 10)
        let candidate = pinnedIdentity(version: "2.0.0", build: "200", hash: "candidate-v2", inode: 20)
        let staged = stagedUpdate(target: target, candidate: candidate)
        let olderCandidate = pinnedIdentity(
            version: "1.5.0",
            build: "150",
            hash: "candidate-v1.5",
            inode: 30
        )
        var reads: [URL] = []

        let failure = ElectronReplacementInstaller.boundaryVerificationFailure(
            for: staged,
            validateCandidateLocation: { _ in nil }
        ) { url in
            reads.append(url)
            return url == staged.targetURL ? target : olderCandidate
        }

        XCTAssertEqual(reads, [staged.targetURL, staged.candidateURL])
        XCTAssertEqual(failure, .verification(.artifactIdentityChanged))
    }

    func testReplacementBoundaryRejectsByteIdenticalCandidateAtDifferentFileIdentity() {
        let target = pinnedIdentity(version: "1.0.0", build: "100", hash: "target-v1", inode: 10)
        let candidate = pinnedIdentity(version: "2.0.0", build: "200", hash: "candidate-v2", inode: 20)
        let staged = stagedUpdate(target: target, candidate: candidate)
        let replacementFile = pinnedIdentity(
            version: "2.0.0",
            build: "200",
            hash: "candidate-v2",
            inode: 21
        )

        let failure = ElectronReplacementInstaller.boundaryVerificationFailure(
            for: staged,
            validateCandidateLocation: { _ in nil }
        ) { url in
            url == staged.targetURL ? target : replacementFile
        }

        XCTAssertEqual(failure, .verification(.artifactIdentityChanged))
    }

    func testStagingCandidateLocationRejectsSymlinksAndNonDirectoryAppCandidates() throws {
        let root = try PrivateUpdateDirectory.create()
        let outside = try PrivateUpdateDirectory.create()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let extracted = root.appendingPathComponent("Extracted", isDirectory: true)
        let outsideApp = outside.appendingPathComponent("External.app", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outsideApp, withIntermediateDirectories: false)
        let finalLink = extracted.appendingPathComponent("Linked.app")
        try FileManager.default.createSymbolicLink(at: finalLink, withDestinationURL: outsideApp)
        let intermediateLink = root.appendingPathComponent("Linked Directory")
        try FileManager.default.createSymbolicLink(at: intermediateLink, withDestinationURL: outside)
        let throughIntermediateLink = intermediateLink.appendingPathComponent("External.app")
        let nonDirectoryApp = extracted.appendingPathComponent("Payload.app")
        try Data("not a bundle directory".utf8).write(to: nonDirectoryApp)
        let rootIdentity = try XCTUnwrap(ElectronReplacementInstaller.stagingDirectoryIdentity(at: root))
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL

        for candidateURL in [finalLink, throughIntermediateLink, nonDirectoryApp] {
            XCTAssertEqual(
                ElectronReplacementInstaller.candidateLocationVerificationFailure(
                    candidateURL: candidateURL,
                    stagingDirectory: root,
                    expectedStagingIdentity: rootIdentity,
                    expectedCanonicalStagingDirectory: canonicalRoot
                ),
                .verification(.artifactIdentityChanged)
            )
        }
    }

    func testReplacementBoundaryRejectsReplacedStagingRootBeforeReadingBundles() throws {
        let root = try PrivateUpdateDirectory.create()
        let movedRoot = root.deletingLastPathComponent().appendingPathComponent("Moved \(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: movedRoot)
        }
        let candidateURL = root.appendingPathComponent("Extracted/Example.app", isDirectory: true)
        try FileManager.default.createDirectory(at: candidateURL, withIntermediateDirectories: true)
        let rootIdentity = try XCTUnwrap(ElectronReplacementInstaller.stagingDirectoryIdentity(at: root))
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let target = pinnedIdentity(version: "1.0.0", build: "100", hash: "target-v1", inode: 10)
        let candidate = pinnedIdentity(version: "2.0.0", build: "200", hash: "candidate-v2", inode: 20)
        let staged = StagedElectronUpdate(
            targetURL: URL(fileURLWithPath: "/Applications/Example.app"),
            candidateURL: candidateURL,
            stagingDirectory: root,
            stagingDirectoryIdentity: rootIdentity,
            canonicalStagingDirectoryURL: canonicalRoot,
            expectedIdentity: target,
            expectedCandidateIdentity: candidate,
            descriptorVersion: candidate.version!
        )
        try FileManager.default.moveItem(at: root, to: movedRoot)
        try FileManager.default.createDirectory(at: candidateURL, withIntermediateDirectories: true)
        var didReadBundleIdentity = false

        let failure = ElectronReplacementInstaller.boundaryVerificationFailure(
            for: staged,
            readIdentity: { _ in
                didReadBundleIdentity = true
                return target
            }
        )

        XCTAssertFalse(didReadBundleIdentity)
        XCTAssertEqual(failure, .verification(.artifactIdentityChanged))
    }

    func testStagingRejectsCandidateVersionThatDoesNotMatchDescriptor() {
        let target = pinnedIdentity(version: "1.0.0", build: "100", hash: "target-v1", inode: 10)
        let candidate = pinnedIdentity(version: "1.5.0", build: "150", hash: "candidate-v1.5", inode: 20)

        let failure = ElectronReplacementInstaller.stagingVerificationFailure(
            expectedIdentity: target,
            candidateIdentity: candidate,
            descriptorVersion: "2.0.0"
        )

        XCTAssertEqual(failure, .verification(.artifactIdentityChanged))
    }

    func testPostReplacementRejectsCandidateSwappedAfterBoundaryCheck() {
        let target = pinnedIdentity(version: "1.0.0", build: "100", hash: "target-v1", inode: 10)
        let candidate = pinnedIdentity(version: "2.0.0", build: "200", hash: "candidate-v2", inode: 20)
        let staged = stagedUpdate(target: target, candidate: candidate)
        let backupURL = URL(fileURLWithPath: "/Applications/.Burrow Backup.app")
        let swappedCandidate = pinnedIdentity(
            version: "1.5.0",
            build: "150",
            hash: "candidate-v1.5",
            inode: 30
        )

        let failure = ElectronReplacementInstaller.postReplacementVerificationFailure(
            for: staged,
            backupURL: backupURL,
            readIdentity: { url in url == staged.targetURL ? swappedCandidate : target }
        )

        XCTAssertEqual(failure, .verification(.artifactIdentityChanged))
    }

    func testPostReplacementRejectsBackupThatIsNotPinnedTarget() {
        let target = pinnedIdentity(version: "1.0.0", build: "100", hash: "target-v1", inode: 10)
        let candidate = pinnedIdentity(version: "2.0.0", build: "200", hash: "candidate-v2", inode: 20)
        let staged = stagedUpdate(target: target, candidate: candidate)
        let backupURL = URL(fileURLWithPath: "/Applications/.Burrow Backup.app")
        let newerTarget = pinnedIdentity(version: "3.0.0", build: "300", hash: "target-v3", inode: 30)

        let failure = ElectronReplacementInstaller.postReplacementVerificationFailure(
            for: staged,
            backupURL: backupURL,
            readIdentity: { url in url == staged.targetURL ? candidate : newerTarget }
        )

        XCTAssertEqual(failure, .verification(.artifactIdentityChanged))
    }

    func testPostReplacementReadsBackupAfterCandidateMismatchAndSelectsPinnedRollback() {
        let target = pinnedIdentity(version: "1.0.0", build: "100", hash: "target-v1", inode: 10)
        let candidate = pinnedIdentity(version: "2.0.0", build: "200", hash: "candidate-v2", inode: 20)
        let staged = stagedUpdate(target: target, candidate: candidate)
        let backupURL = URL(fileURLWithPath: "/Applications/.Burrow Backup.app")
        let swappedCandidate = pinnedIdentity(
            version: "1.5.0",
            build: "150",
            hash: "candidate-v1.5",
            inode: 30
        )
        var reads: [URL] = []

        let decision = ElectronReplacementInstaller.postReplacementDecision(
            for: staged,
            backupURL: backupURL,
            readIdentity: { url in
                reads.append(url)
                return url == staged.targetURL ? swappedCandidate : target
            }
        )

        XCTAssertEqual(reads, [staged.targetURL, backupURL])
        XCTAssertEqual(
            decision,
            .restore(
                installedIdentity: swappedCandidate,
                backupIdentity: target,
                failure: .verification(.artifactIdentityChanged)
            )
        )
    }

    func testPostReplacementDoesNotSelectUntrustedBackupForRollback() {
        let target = pinnedIdentity(version: "1.0.0", build: "100", hash: "target-v1", inode: 10)
        let candidate = pinnedIdentity(version: "2.0.0", build: "200", hash: "candidate-v2", inode: 20)
        let staged = stagedUpdate(target: target, candidate: candidate)
        let backupURL = URL(fileURLWithPath: "/Applications/.Burrow Backup.app")
        let untrustedBackup = BundleUpdateIdentity(
            bundleID: target.bundleID,
            signingIdentifier: target.signingIdentifier,
            teamIdentifier: "ATTACKER",
            signatureValid: true,
            version: "3.0.0",
            build: "300",
            codeDirectoryHash: Data("attacker-v3".utf8),
            fileIdentity: .init(device: 1, inode: 30)
        )

        let decision = ElectronReplacementInstaller.postReplacementDecision(
            for: staged,
            backupURL: backupURL,
            readIdentity: { url in url == staged.targetURL ? candidate : untrustedBackup }
        )

        guard case let .fail(.installation(message)) = decision else {
            return XCTFail("An untrusted backup must fail closed without being selected for rollback")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("restore"))
    }

    func testPostReplacementDoesNotSelectAuthenticOlderSwappedBackup() {
        let target = pinnedIdentity(version: "1.0.0", build: "100", hash: "target-v1", inode: 10)
        let candidate = pinnedIdentity(version: "2.0.0", build: "200", hash: "candidate-v2", inode: 20)
        let staged = stagedUpdate(target: target, candidate: candidate)
        let backupURL = URL(fileURLWithPath: "/Applications/.Burrow Backup.app")
        let authenticOlderBackup = pinnedIdentity(
            version: "0.9.0",
            build: "90",
            hash: "authentic-v0.9",
            inode: 30
        )

        let decision = ElectronReplacementInstaller.postReplacementDecision(
            for: staged,
            backupURL: backupURL,
            readIdentity: { url in url == staged.targetURL ? candidate : authenticOlderBackup }
        )

        guard case .fail(.installation(_)) = decision else {
            return XCTFail("An older backup that is not the pinned original must not be restored")
        }
    }

    func testPostReplacementSelectsPinnedBackupWhenInstalledTargetIsUnreadable() {
        let target = pinnedIdentity(version: "1.0.0", build: "100", hash: "target-v1", inode: 10)
        let candidate = pinnedIdentity(version: "2.0.0", build: "200", hash: "candidate-v2", inode: 20)
        let staged = stagedUpdate(target: target, candidate: candidate)
        let backupURL = URL(fileURLWithPath: "/Applications/.Burrow Backup.app")

        let decision = ElectronReplacementInstaller.postReplacementDecision(
            for: staged,
            backupURL: backupURL,
            readIdentity: { url in url == staged.targetURL ? nil : target }
        )

        XCTAssertEqual(
            decision,
            .restore(
                installedIdentity: nil,
                backupIdentity: target,
                failure: .verification(.artifactIdentityChanged)
            )
        )
    }

    func testPostReplacementSelectsAuthenticatedNewerBackupInsteadOfDowngradingIt() {
        let target = pinnedIdentity(version: "1.0.0", build: "100", hash: "target-v1", inode: 10)
        let candidate = pinnedIdentity(version: "2.0.0", build: "200", hash: "candidate-v2", inode: 20)
        let staged = stagedUpdate(target: target, candidate: candidate)
        let backupURL = URL(fileURLWithPath: "/Applications/.Burrow Backup.app")
        let newerBackup = pinnedIdentity(version: "3.0.0", build: "300", hash: "target-v3", inode: 30)

        let decision = ElectronReplacementInstaller.postReplacementDecision(
            for: staged,
            backupURL: backupURL,
            readIdentity: { url in url == staged.targetURL ? candidate : newerBackup }
        )

        XCTAssertEqual(
            decision,
            .restore(
                installedIdentity: candidate,
                backupIdentity: newerBackup,
                failure: .verification(.artifactIdentityChanged)
            )
        )
    }

    func testPostReplacementTreatsNewerElectronPrereleaseAsSafeRollback() {
        let target = pinnedIdentity(version: "1.0.0", build: "100", hash: "target-v1", inode: 10)
        let candidate = pinnedIdentity(
            version: "2.0.0-beta.1",
            build: "200",
            hash: "candidate-beta1",
            inode: 20
        )
        let staged = stagedUpdate(target: target, candidate: candidate)
        let backupURL = URL(fileURLWithPath: "/Applications/.Burrow Backup.app")
        let newerPrerelease = pinnedIdentity(
            version: "2.0.0-beta.2",
            build: "200",
            hash: "candidate-beta2",
            inode: 30
        )

        let decision = ElectronReplacementInstaller.postReplacementDecision(
            for: staged,
            backupURL: backupURL,
            readIdentity: { url in url == staged.targetURL ? candidate : newerPrerelease }
        )

        XCTAssertEqual(
            decision,
            .restore(
                installedIdentity: candidate,
                backupIdentity: newerPrerelease,
                failure: .verification(.artifactIdentityChanged)
            )
        )
    }

    func testRestoreVerifiedBackupReplacesAndReverifiesCapturedIdentity() {
        let target = pinnedIdentity(version: "1.0.0", build: "100", hash: "target-v1", inode: 10)
        let candidate = pinnedIdentity(version: "2.0.0", build: "200", hash: "candidate-v2", inode: 20)
        let staged = stagedUpdate(target: target, candidate: candidate)
        let backupURL = URL(fileURLWithPath: "/Applications/.Burrow Backup.app")
        var replacements: [(target: URL, backup: URL, backupName: String)] = []
        var reads: [URL] = []
        var didReplace = false
        var displacedURL: URL?

        let failure = ElectronReplacementInstaller.restoreVerifiedBackup(
            for: staged,
            backupURL: backupURL,
            capturedInstalledIdentity: candidate,
            capturedBackupIdentity: target,
            replaceItem: { targetURL, backupURL, backupName in
                replacements.append((targetURL, backupURL, backupName))
                displacedURL = targetURL.deletingLastPathComponent().appendingPathComponent(backupName)
                didReplace = true
            },
            readIdentity: { url in
                reads.append(url)
                if url == backupURL { return target }
                if url == displacedURL { return candidate }
                return didReplace ? target : candidate
            }
        )

        XCTAssertNil(failure)
        XCTAssertEqual(replacements.count, 1)
        XCTAssertEqual(replacements.first?.target, staged.targetURL)
        XCTAssertEqual(replacements.first?.backup, backupURL)
        XCTAssertFalse(replacements.first?.backupName.isEmpty ?? true)
        XCTAssertEqual(reads, [staged.targetURL, backupURL, staged.targetURL, displacedURL!])
    }

    func testRestoreVerifiedBackupDoesNotReplaceWhenBackupPathChangedAfterDecision() {
        let target = pinnedIdentity(version: "1.0.0", build: "100", hash: "target-v1", inode: 10)
        let candidate = pinnedIdentity(version: "2.0.0", build: "200", hash: "candidate-v2", inode: 20)
        let staged = stagedUpdate(target: target, candidate: candidate)
        let backupURL = URL(fileURLWithPath: "/Applications/.Burrow Backup.app")
        let swappedBackup = pinnedIdentity(
            version: target.version!,
            build: target.build!,
            hash: "target-v1",
            inode: 11
        )
        var didReplace = false
        var reads: [URL] = []

        let failure = ElectronReplacementInstaller.restoreVerifiedBackup(
            for: staged,
            backupURL: backupURL,
            capturedInstalledIdentity: candidate,
            capturedBackupIdentity: target,
            replaceItem: { _, _, _ in didReplace = true },
            readIdentity: { url in
                reads.append(url)
                return url == staged.targetURL ? candidate : swappedBackup
            }
        )

        XCTAssertFalse(didReplace)
        XCTAssertEqual(reads, [staged.targetURL, backupURL])
        guard case .installation = failure else {
            return XCTFail("A swapped backup must fail before replacement")
        }
    }

    func testRestoreVerifiedBackupDoesNotReplaceWhenTargetChangedAfterDecision() {
        let target = pinnedIdentity(version: "1.0.0", build: "100", hash: "target-v1", inode: 10)
        let candidate = pinnedIdentity(version: "2.0.0", build: "200", hash: "candidate-v2", inode: 20)
        let staged = stagedUpdate(target: target, candidate: candidate)
        let backupURL = URL(fileURLWithPath: "/Applications/.Burrow Backup.app")
        let newerTarget = pinnedIdentity(version: "3.0.0", build: "300", hash: "target-v3", inode: 30)
        var didReplace = false
        var reads: [URL] = []

        let failure = ElectronReplacementInstaller.restoreVerifiedBackup(
            for: staged,
            backupURL: backupURL,
            capturedInstalledIdentity: candidate,
            capturedBackupIdentity: target,
            replaceItem: { _, _, _ in didReplace = true },
            readIdentity: { url in
                reads.append(url)
                return url == staged.targetURL ? newerTarget : target
            }
        )

        XCTAssertFalse(didReplace)
        XCTAssertEqual(reads, [staged.targetURL, backupURL])
        guard case .installation = failure else {
            return XCTFail("A changed target must fail before rollback")
        }
    }

    func testRestoreVerifiedBackupRestoresPinnedBackupOverStillUnreadableTarget() {
        let target = pinnedIdentity(version: "1.0.0", build: "100", hash: "target-v1", inode: 10)
        let candidate = pinnedIdentity(version: "2.0.0", build: "200", hash: "candidate-v2", inode: 20)
        let staged = stagedUpdate(target: target, candidate: candidate)
        let backupURL = URL(fileURLWithPath: "/Applications/.Burrow Backup.app")
        var didReplace = false

        let failure = ElectronReplacementInstaller.restoreVerifiedBackup(
            for: staged,
            backupURL: backupURL,
            capturedInstalledIdentity: nil,
            capturedBackupIdentity: target,
            replaceItem: { _, _, _ in didReplace = true },
            moveItemExclusively: { _, _ in didReplace = true },
            pathExists: { _ in false },
            readIdentity: { url in
                if url == backupURL { return target }
                return didReplace ? target : nil
            }
        )

        XCTAssertTrue(didReplace)
        XCTAssertNil(failure)
    }

    func testRestoreVerifiedBackupFailsWhenRestoredArtifactDoesNotMatchCapturedBackup() {
        let target = pinnedIdentity(version: "1.0.0", build: "100", hash: "target-v1", inode: 10)
        let candidate = pinnedIdentity(version: "2.0.0", build: "200", hash: "candidate-v2", inode: 20)
        let staged = stagedUpdate(target: target, candidate: candidate)
        let backupURL = URL(fileURLWithPath: "/Applications/.Burrow Backup.app")
        let swappedDuringRestore = pinnedIdentity(
            version: target.version!,
            build: target.build!,
            hash: "target-v1",
            inode: 11
        )
        var replacementCount = 0
        var displacedURL: URL?

        let failure = ElectronReplacementInstaller.restoreVerifiedBackup(
            for: staged,
            backupURL: backupURL,
            capturedInstalledIdentity: candidate,
            capturedBackupIdentity: target,
            replaceItem: { targetURL, _, backupName in
                replacementCount += 1
                displacedURL = targetURL.deletingLastPathComponent().appendingPathComponent(backupName)
            },
            readIdentity: { url in
                if url == backupURL { return target }
                if url == staged.targetURL { return replacementCount == 0 ? candidate : swappedDuringRestore }
                if url == displacedURL { return candidate }
                return swappedDuringRestore
            }
        )

        guard case let .installation(message) = failure else {
            return XCTFail("A changed restored artifact must surface an explicit recovery failure")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("restore"))
        XCTAssertEqual(replacementCount, 2)
    }

    func testRestoreVerifiedBackupRecoversPreservedCandidateAfterPostUseMismatch() {
        let target = pinnedIdentity(version: "1.0.0", build: "100", hash: "target-v1", inode: 10)
        let candidate = pinnedIdentity(version: "2.0.0", build: "200", hash: "candidate-v2", inode: 20)
        let staged = stagedUpdate(target: target, candidate: candidate)
        let backupURL = URL(fileURLWithPath: "/Applications/.Burrow Backup.app")
        let swappedBackup = pinnedIdentity(version: "0.9.0", build: "90", hash: "swapped-v0.9", inode: 30)
        var identities: [URL: BundleUpdateIdentity] = [
            staged.targetURL: candidate,
            backupURL: target,
        ]
        var replacementCount = 0

        let failure = ElectronReplacementInstaller.restoreVerifiedBackup(
            for: staged,
            backupURL: backupURL,
            capturedInstalledIdentity: candidate,
            capturedBackupIdentity: target,
            replaceItem: { targetURL, replacementURL, backupName in
                replacementCount += 1
                let displacedURL = targetURL.deletingLastPathComponent().appendingPathComponent(backupName)
                identities[displacedURL] = identities[targetURL]
                if replacementCount == 1 {
                    // Model a swap after the immediate backup check but before
                    // the atomic replacement consumes the path.
                    identities[targetURL] = swappedBackup
                } else {
                    identities[targetURL] = identities[replacementURL]
                }
                identities[replacementURL] = nil
            },
            readIdentity: { identities[$0] }
        )

        XCTAssertEqual(replacementCount, 2)
        XCTAssertEqual(identities[staged.targetURL], candidate)
        guard case .installation = failure else {
            return XCTFail("A post-use mismatch must restore the preserved known candidate and report recovery")
        }
    }

    func testRestoreVerifiedBackupRestoresNewerTargetDisplacedAfterPrecheck() {
        let original = pinnedIdentity(version: "1.0.0", build: "100", hash: "target-v1", inode: 10)
        let candidate = pinnedIdentity(version: "2.0.0", build: "200", hash: "candidate-v2", inode: 20)
        let staged = stagedUpdate(target: original, candidate: candidate)
        let backupURL = URL(fileURLWithPath: "/Applications/.Burrow Backup.app")
        let capturedBackup = pinnedIdentity(version: "3.0.0", build: "300", hash: "target-v3", inode: 30)
        let racedTarget = pinnedIdentity(version: "4.0.0", build: "400", hash: "target-v4", inode: 40)
        var identities: [URL: BundleUpdateIdentity] = [
            staged.targetURL: candidate,
            backupURL: capturedBackup,
        ]
        var replacementCount = 0

        let failure = ElectronReplacementInstaller.restoreVerifiedBackup(
            for: staged,
            backupURL: backupURL,
            capturedInstalledIdentity: candidate,
            capturedBackupIdentity: capturedBackup,
            replaceItem: { targetURL, replacementURL, backupName in
                replacementCount += 1
                let displacedURL = targetURL.deletingLastPathComponent().appendingPathComponent(backupName)
                identities[displacedURL] = replacementCount == 1 ? racedTarget : identities[targetURL]
                identities[targetURL] = identities[replacementURL]
                identities[replacementURL] = nil
            },
            readIdentity: { identities[$0] }
        )

        XCTAssertNil(failure)
        XCTAssertEqual(replacementCount, 2)
        XCTAssertEqual(identities[staged.targetURL], racedTarget)
    }

    func testRestoreVerifiedBackupNeverRecoversUnpinnedInstalledArtifact() {
        let target = pinnedIdentity(version: "1.0.0", build: "100", hash: "target-v1", inode: 10)
        let candidate = pinnedIdentity(version: "2.0.0", build: "200", hash: "candidate-v2", inode: 20)
        let staged = stagedUpdate(target: target, candidate: candidate)
        let backupURL = URL(fileURLWithPath: "/Applications/.Burrow Backup.app")
        let wrongInstalled = pinnedIdentity(version: "1.5.0", build: "150", hash: "wrong-v1.5", inode: 25)
        let swappedDuringRollback = pinnedIdentity(
            version: "0.9.0",
            build: "90",
            hash: "swapped-v0.9",
            inode: 30
        )
        var identities: [URL: BundleUpdateIdentity] = [
            staged.targetURL: wrongInstalled,
            backupURL: target,
        ]
        var replacementCount = 0

        let failure = ElectronReplacementInstaller.restoreVerifiedBackup(
            for: staged,
            backupURL: backupURL,
            capturedInstalledIdentity: wrongInstalled,
            capturedBackupIdentity: target,
            replaceItem: { targetURL, replacementURL, backupName in
                replacementCount += 1
                let displacedURL = targetURL.deletingLastPathComponent().appendingPathComponent(backupName)
                identities[displacedURL] = identities[targetURL]
                identities[targetURL] = swappedDuringRollback
                identities[replacementURL] = nil
            },
            readIdentity: { identities[$0] }
        )

        XCTAssertEqual(replacementCount, 1)
        XCTAssertNotEqual(identities[staged.targetURL], wrongInstalled)
        guard case .installation = failure else {
            return XCTFail("An unpinned installed artifact must never be restored during recovery")
        }
    }

    func testReplacementPreservesBackupUntilExplicitCleanup() throws {
        let root = try PrivateUpdateDirectory.create()
        defer { try? FileManager.default.removeItem(at: root) }
        let targetURL = root.appendingPathComponent("Example.app", isDirectory: true)
        let candidateURL = root.appendingPathComponent("Candidate.app", isDirectory: true)
        let backupName = "Backup.app"
        let backupURL = root.appendingPathComponent(backupName, isDirectory: true)
        try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: candidateURL, withIntermediateDirectories: false)
        try Data("old".utf8).write(to: targetURL.appendingPathComponent("payload"))
        try Data("new".utf8).write(to: candidateURL.appendingPathComponent("payload"))

        try ElectronReplacementInstaller.replacePreservingBackup(
            targetURL: targetURL,
            candidateURL: candidateURL,
            backupName: backupName
        )

        XCTAssertEqual(try Data(contentsOf: targetURL.appendingPathComponent("payload")), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: backupURL.appendingPathComponent("payload")), Data("old".utf8))

        try ElectronReplacementInstaller.removePreservedBackup(at: backupURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
    }

    func testExclusiveMoveRestoresMissingTargetAndNeverOverwritesCompetitor() throws {
        let root = try PrivateUpdateDirectory.create()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Verified Backup.app", isDirectory: true)
        let targetURL = root.appendingPathComponent("Example.app", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: false)
        try Data("verified".utf8).write(to: sourceURL.appendingPathComponent("payload"))

        try ElectronReplacementInstaller.moveItemExclusively(from: sourceURL, to: targetURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(try Data(contentsOf: targetURL.appendingPathComponent("payload")), Data("verified".utf8))

        let competingSourceURL = root.appendingPathComponent("Second Backup.app", isDirectory: true)
        try FileManager.default.createDirectory(at: competingSourceURL, withIntermediateDirectories: false)
        try Data("second".utf8).write(to: competingSourceURL.appendingPathComponent("payload"))

        XCTAssertThrowsError(
            try ElectronReplacementInstaller.moveItemExclusively(from: competingSourceURL, to: targetURL)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: competingSourceURL.path))
        XCTAssertEqual(try Data(contentsOf: targetURL.appendingPathComponent("payload")), Data("verified".utf8))
    }

    func testUnreadableDanglingSymlinkUsesQuarantineReplacementInsteadOfMissingPathMove() throws {
        let root = try PrivateUpdateDirectory.create()
        defer { try? FileManager.default.removeItem(at: root) }
        let targetURL = root.appendingPathComponent("Example.app")
        let backupURL = root.appendingPathComponent("Verified Backup.app")
        let missingDestination = root.appendingPathComponent("Missing.app")
        try FileManager.default.createSymbolicLink(at: targetURL, withDestinationURL: missingDestination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL.path))

        let target = pinnedIdentity(version: "1.0.0", build: "100", hash: "target-v1", inode: 10)
        let candidate = pinnedIdentity(version: "2.0.0", build: "200", hash: "candidate-v2", inode: 20)
        let staged = StagedElectronUpdate(
            targetURL: targetURL,
            candidateURL: root.appendingPathComponent("Candidate.app"),
            stagingDirectory: root,
            stagingDirectoryIdentity: try XCTUnwrap(
                ElectronReplacementInstaller.stagingDirectoryIdentity(at: root)
            ),
            canonicalStagingDirectoryURL: root.resolvingSymlinksInPath().standardizedFileURL,
            expectedIdentity: target,
            expectedCandidateIdentity: candidate,
            descriptorVersion: candidate.version!
        )
        var usedQuarantineReplacement = false
        var usedMissingPathMove = false

        let failure = ElectronReplacementInstaller.restoreVerifiedBackup(
            for: staged,
            backupURL: backupURL,
            capturedInstalledIdentity: nil,
            capturedBackupIdentity: target,
            replaceItem: { _, _, _ in usedQuarantineReplacement = true },
            moveItemExclusively: { _, _ in usedMissingPathMove = true },
            readIdentity: { url in
                if url == backupURL { return target }
                if url == staged.targetURL { return usedQuarantineReplacement ? target : nil }
                return nil
            }
        )

        XCTAssertNil(failure)
        XCTAssertTrue(usedQuarantineReplacement)
        XCTAssertFalse(usedMissingPathMove)
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

    private func pinnedIdentity(
        version: String,
        build: String,
        hash: String,
        inode: UInt64
    ) -> BundleUpdateIdentity {
        BundleUpdateIdentity(
            bundleID: "com.example.App",
            signingIdentifier: "com.example.App",
            teamIdentifier: "TEAM123",
            signatureValid: true,
            version: version,
            build: build,
            codeDirectoryHash: Data(hash.utf8),
            fileIdentity: .init(device: 1, inode: inode)
        )
    }

    private func stagedUpdate(
        target: BundleUpdateIdentity,
        candidate: BundleUpdateIdentity
    ) -> StagedElectronUpdate {
        StagedElectronUpdate(
            targetURL: URL(fileURLWithPath: "/Applications/Example.app"),
            candidateURL: URL(fileURLWithPath: "/tmp/private/Candidate.app"),
            stagingDirectory: URL(fileURLWithPath: "/tmp/private"),
            stagingDirectoryIdentity: .init(device: 1, inode: 1),
            canonicalStagingDirectoryURL: URL(fileURLWithPath: "/tmp/private"),
            expectedIdentity: target,
            expectedCandidateIdentity: candidate,
            descriptorVersion: candidate.version!
        )
    }

    private func stagedUpdateForCleanup(
        root: URL,
        identity: BundleFileIdentity
    ) -> StagedElectronUpdate {
        StagedElectronUpdate(
            targetURL: URL(fileURLWithPath: "/Applications/Example.app"),
            candidateURL: root.appendingPathComponent("Candidate.app"),
            stagingDirectory: root,
            stagingDirectoryIdentity: identity,
            canonicalStagingDirectoryURL: root.resolvingSymlinksInPath().standardizedFileURL,
            expectedIdentity: pinnedIdentity(
                version: "1.0.0",
                build: "100",
                hash: "target-v1",
                inode: 10
            )
        )
    }
}
