import XCTest
import Darwin
@testable import Burrow

final class PrivilegedIdentityTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow identity \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        temp = URL(fileURLWithPath: try XCTUnwrap(InvokingUserIdentity.canonicalPath(temp.path)))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    func testInvokingUser_selectsNumericUIDAmongSeveralAccountsAndPreservesSpaces() throws {
        let accounts = [
            InvokingUserIdentity.Account(uid: 502, name: "other", home: "/Users/other"),
            InvokingUserIdentity.Account(uid: 501, name: "henry", home: temp.path),
        ]
        let user = try InvokingUserIdentity.resolve(invokingUID: 501, accounts: accounts)
        XCTAssertEqual(user.uid, 501)
        XCTAssertEqual(user.username, "henry")
        XCTAssertEqual(user.canonicalHome, temp.path)
    }

    func testInvokingUser_canonicalizesSymlinkedHomeBeforeElevation() throws {
        let link = temp.deletingLastPathComponent().appendingPathComponent("home-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: temp)
        defer { try? FileManager.default.removeItem(at: link) }

        let user = try InvokingUserIdentity.resolve(
            invokingUID: 501,
            accounts: [.init(uid: 501, name: "henry", home: link.path)])
        XCTAssertEqual(user.canonicalHome, temp.path)
    }

    func testInvokingUser_refusesMissingRootAndVarRootMismatch() {
        XCTAssertThrowsError(try InvokingUserIdentity.resolve(invokingUID: 501, accounts: []))
        XCTAssertThrowsError(try InvokingUserIdentity.resolve(
            invokingUID: 0, accounts: [.init(uid: 0, name: "root", home: "/var/root")]))
        XCTAssertThrowsError(try InvokingUserIdentity.resolve(
            invokingUID: 501,
            accounts: [.init(uid: 501, name: "root", home: "/var/root")],
            canonicalize: { $0 }))
    }

    func testInvokingUser_refusesHomeOwnedByAnotherAccount() {
        let otherUID = getuid() &+ 1
        XCTAssertThrowsError(try InvokingUserIdentity.resolve(
            invokingUID: otherUID,
            accounts: [.init(uid: otherUID, name: "other", home: temp.path)])) { error in
            guard case InvokingUserIdentity.ResolutionError.mismatchedHomeOwner(
                expected: otherUID, actual: getuid()) = error else {
                return XCTFail("expected mismatched home ownership, got \(error)")
            }
        }
    }

    func testElevatedScriptPinsInvokingIdentityRatherThanRootHome() {
        let executable = PinnedFileIdentity(path: "/usr/bin/true", device: 1, inode: 2,
                                            owner: 0, mode: UInt16(S_IFREG | 0o755))
        let user = InvokingUserIdentity(uid: 501, username: "name with space",
                                        canonicalHome: "/Users/name with space")
        let command = ValidatedElevatedCommand(executable: executable, components: [],
                                               invokingUser: user, signedBundlePath: nil)
        let script = MoleCLI.elevatedScript(command: command, args: [])
        XCTAssertTrue(script.contains("'HOME=/Users/name with space'"))
        XCTAssertTrue(script.contains("'SUDO_UID=501'"))
        XCTAssertFalse(script.contains("HOME=/var/root"))
    }

    func testUserMutableExecutableIsRejectedAndReplacementBreaksPinnedIdentity() throws {
        let executable = temp.appendingPathComponent("mo")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let user = InvokingUserIdentity(uid: getuid(), username: NSUserName(), canonicalHome: NSHomeDirectory())
        XCTAssertThrowsError(try ValidatedElevatedCommand.prepare(
            executable: executable.path, invokingUser: user, requireCurrentBundle: false))

        let pinned = try PinnedFileIdentity.capture(executable.path)
        try FileManager.default.removeItem(at: executable)
        try Data("#!/bin/sh\nexit 9\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        XCTAssertFalse(pinned.matchesCurrent(), "a hostile same-path replacement must fail its inode check")
    }
}

final class CleanupAuthorizationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-clean-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: try XCTUnwrap(InvokingUserIdentity.canonicalPath(root.path)))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func list(_ paths: [String]) -> CleanList {
        CleanList(categories: [.init(name: "Test", items: paths.map {
            .init(path: $0, sizeBytes: 1, sizeText: "1B", itemCount: nil)
        })], summaryTotalText: "1B", summaryItemCount: paths.count)
    }

    func testSnapshotAcceptsCanonicalPathsWithSpacesAndPinsReviewedIdentity() throws {
        let item = root.appendingPathComponent("cache with spaces")
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
        let snapshot = try CleanupSnapshot.capture(list: list([item.path]),
                                                   approvedRootURLs: [root])
        let plan = try snapshot.plan(selectedPaths: [item.path])
        XCTAssertTrue(plan.validateForLaunch())
        XCTAssertEqual(plan.items.map(\.identity.path), [item.path])
    }

    func testSnapshotRejectsControlsNULJSONRelativeSymlinkAndOutsideRoots() throws {
        for malformed in ["relative/cache", "{\"path\":\"/tmp/x\"}",
                          "/tmp/bad\npath", "/tmp/bad\0suffix"] {
            XCTAssertThrowsError(try CleanupSnapshot.capture(
                list: list([malformed]), approvedRootURLs: [root]), malformed)
        }

        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: outside) }
        XCTAssertThrowsError(try CleanupSnapshot.capture(list: list([outside.path]),
                                                         approvedRootURLs: [root]))

        let real = root.appendingPathComponent("real")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertThrowsError(try CleanupSnapshot.capture(list: list([link.path]),
                                                         approvedRootURLs: [root]))
    }

    func testApprovedRootRejectsUnexpectedVolumeIdentity() throws {
        let rootIdentity = try PinnedFileIdentity.capture(root.path)
        XCTAssertThrowsError(try CleanupSnapshot.approvedRoot(
            for: root.path + "/cache", device: rootIdentity.device + 1, roots: [rootIdentity])) {
            XCTAssertEqual($0 as? CleanupSnapshot.SnapshotError,
                           .unexpectedVolume(root.path + "/cache"))
        }
    }

    func testPlanFailsClosedWhenStaleOrSymlinkSwapped() throws {
        let item = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
        let old = Date(timeIntervalSince1970: 1_000)
        let snapshot = try CleanupSnapshot.capture(list: list([item.path]),
                                                   approvedRootURLs: [root], now: old)
        XCTAssertThrowsError(try snapshot.plan(selectedPaths: [item.path],
                                               now: old.addingTimeInterval(301)))

        let moved = root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: item, to: moved)
        try FileManager.default.createSymbolicLink(at: item, withDestinationURL: moved)
        XCTAssertThrowsError(try snapshot.plan(selectedPaths: [item.path], now: old))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path),
                      "malformed/swapped directories are refused, never auto-deleted")
    }
}

final class PrivilegedLogSinkTests: XCTestCase {
    func testNamesAreUnguessableAndDistinct() throws {
        let a = try PrivilegedLogSink.make(), b = try PrivilegedLogSink.make()
        XCTAssertNotEqual(a.directoryPath, b.directoryPath)
        XCTAssertTrue(a.directoryPath.hasPrefix("/private/var/tmp/dev.caezium.burrow.operation-"))
    }

    func testHostileSymlinkCollisionFailsWithoutFollowingOrDeletingIt() throws {
        let token = "TESTCOLLISION" + String(repeating: "A", count: 32)
        let sink = try PrivilegedLogSink.make(token: token)
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-log-target-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: sink.directoryPath,
                                                   withDestinationPath: target.path)
        defer {
            try? FileManager.default.removeItem(atPath: sink.directoryPath)
            try? FileManager.default.removeItem(at: target)
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", sink.exclusiveCreationShell]
        try task.run(); task.waitUntilExit()
        XCTAssertNotEqual(task.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sink.directoryPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("output.log").path))
    }
}
