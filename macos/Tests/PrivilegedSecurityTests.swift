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

    /// The layout every shipped copy of Burrow actually has.
    ///
    /// `/Applications` is `root:admin` mode 0775 on stock macOS and an app
    /// dragged there (or installed by a Homebrew cask) is owned by the account
    /// that installed it. A rule demanding root ownership of the engine and
    /// every ancestor is therefore unsatisfiable in production, and the only
    /// place it shows up is at runtime, as a refusal with no prompt.
    private func makeApplicationsLayout() throws -> (bundle: String, engine: String) {
        let applications = temp.appendingPathComponent("Applications", isDirectory: true)
        let bundle = applications.appendingPathComponent("Burrow.app", isDirectory: true)
        let engineDirectory = bundle.appendingPathComponent("Contents/Resources/engine",
                                                            isDirectory: true)
        try FileManager.default.createDirectory(at: engineDirectory,
                                                withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o775],
                                              ofItemAtPath: applications.path)
        let engine = engineDirectory.appendingPathComponent("mole")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: engine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: engine.path)
        return (bundle.path, engine.path)
    }

    private var currentUser: InvokingUserIdentity {
        InvokingUserIdentity(uid: getuid(), username: NSUserName(),
                             canonicalHome: NSHomeDirectory())
    }

    func testBundledEngineIsAcceptedUnderAGroupWritableApplicationsDirectory() throws {
        let layout = try makeApplicationsLayout()
        let command = try ValidatedElevatedCommand.prepare(
            executable: layout.engine, invokingUser: currentUser,
            requireCurrentBundle: true, bundlePath: layout.bundle)

        XCTAssertEqual(command.signedBundlePath, layout.bundle)
        // Ownership stopped being the guarantee, so the resource seal has to
        // be checked at the boundary — without it nothing is verifying this.
        let script = MoleCLI.elevatedScript(command: command, args: ["optimize"])
        XCTAssertTrue(script.contains("/usr/bin/codesign --verify --strict"),
                      "the signed-bundle policy is only safe with the seal check")
        XCTAssertTrue(script.contains("/usr/bin/stat -f '%d:%i:%u:%p'"),
                      "every ancestor stays pinned regardless of who owns it")
    }

    func testBundledEngineIsRefusedWhenAnAncestorIsWorldWritable() throws {
        let layout = try makeApplicationsLayout()
        // Group-writable is normal; world-writable would let an unrelated
        // account do the swapping, and no install layout needs that.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: temp.appendingPathComponent("Applications").path)

        XCTAssertThrowsError(try ValidatedElevatedCommand.prepare(
            executable: layout.engine, invokingUser: currentUser,
            requireCurrentBundle: true, bundlePath: layout.bundle))
    }

    func testBundledEnginePolicyDoesNotLeakToExecutablesOutsideTheBundle() throws {
        let layout = try makeApplicationsLayout()
        // The same user-owned file, asked for WITHOUT the bundle seal, must
        // still be refused: relaxing ownership is only paid for by the seal.
        XCTAssertThrowsError(try ValidatedElevatedCommand.prepare(
            executable: layout.engine, invokingUser: currentUser,
            requireCurrentBundle: false, bundlePath: layout.bundle))
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

        // A well-formed entry that simply can't be represented is SKIPPED, not
        // fatal — see testOneUnrepresentableEntryDoesNotKillTheWholePreview.
        // Alone in a list it leaves nothing to clean, which is still an error.
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

    /// The bug that broke Clean for essentially everyone.
    ///
    /// The engine's export writer collapses siblings to their common PARENT,
    /// so a category removing two or more loose files directly inside an
    /// approved root records the ROOT. `find "$HOME" -name .DS_Store` over a
    /// home folder with more than one match writes `/Users/<you>`, and almost
    /// every Mac has that. Accepting it would have meant deleting the home
    /// directory, so refusing is right — but refusing the whole preview took
    /// the Clean button with it and blocked gigabytes of valid cleanup.
    func testOneUnrepresentableEntryDoesNotKillTheWholePreview() throws {
        let good = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: false)

        // `root.path` is the approved root itself — exactly what the collapse
        // produces for a home-directory sweep.
        let snapshot = try CleanupSnapshot.capture(list: list([root.path, good.path]),
                                                   approvedRootURLs: [root])

        XCTAssertEqual(snapshot.items.map(\.identity.path), [good.path],
                       "the usable entry survives")
        XCTAssertEqual(snapshot.skipped.map(\.path), [root.path],
                       "the root-collapsed entry is refused and reported")

        // And it must never reach a plan: this is the difference between
        // deleting a cache directory and deleting someone's home folder.
        let plan = try snapshot.plan(selectedPaths: [good.path])
        XCTAssertEqual(plan.items.map(\.identity.path), [good.path])
        XCTAssertThrowsError(try snapshot.plan(selectedPaths: [root.path, good.path]),
                             "a refused entry cannot be selected back in")
    }

    /// Skipping must not become a way to launder a corrupt list. A path the
    /// engine's writer cannot produce means the list isn't the engine's, and
    /// partially executing it would be the wrong call.
    func testStructurallyCorruptPreviewsAreStillFatalRatherThanSkipped() {
        for corrupt in ["relative/cache", "{\"path\":\"/tmp/x\"}", "/tmp/bad\npath"] {
            XCTAssertThrowsError(try CleanupSnapshot.capture(
                list: list([corrupt, root.appendingPathComponent("cache").path]),
                approvedRootURLs: [root]), corrupt)
        }
    }

    /// Why a fully successful clean reported "exit 1".
    ///
    /// The engine's export list routinely names a parent AND its own children
    /// as separate entries. Delete the parent first and every nested entry is
    /// already gone when its turn comes, so `find` exits nonzero with "No such
    /// file or directory" for work that succeeded. Deepest-first means each
    /// entry still exists when it is reached — and both elevation routes have
    /// to use this order, since the helper path skipping it is what produced
    /// the failure.
    func testNestedEntriesAreOrderedDeepestFirstSoNoneVanishesBeforeItsTurn() throws {
        let caches = root.appendingPathComponent("Caches")
        let nested = caches.appendingPathComponent("GeoServices")
        let deeper = nested.appendingPathComponent("tiles")
        try FileManager.default.createDirectory(at: deeper, withIntermediateDirectories: true)

        // Parent first in the list, exactly as the engine emits it.
        let snapshot = try CleanupSnapshot.capture(
            list: list([caches.path, nested.path, deeper.path]), approvedRootURLs: [root])
        let plan = try snapshot.plan(
            selectedPaths: [caches.path, nested.path, deeper.path])

        XCTAssertEqual(plan.orderedReviewedPaths(), [deeper.path, nested.path, caches.path],
                       "a parent must never be deleted before its own listed children")
        // The shell the osascript route runs is built from the same order.
        // Only the delete loop matters — the boundary checks ahead of it stat
        // every root and item, so searching the whole script finds those first.
        let shell = plan.irreversibleCleanupShell()
        let loop = String(shell[try XCTUnwrap(shell.range(of: "for p in")).lowerBound...])
        let deepIndex = try XCTUnwrap(loop.range(of: deeper.path)).lowerBound
        let parentIndex = try XCTUnwrap(loop.range(of: caches.path + "'")).lowerBound
        XCTAssertLessThan(deepIndex, parentIndex)
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

    func testTrashMoveRestoresAnUnreviewedObjectCapturedByAPathRace() throws {
        let reviewed = root.appendingPathComponent("reviewed")
        let original = root.appendingPathComponent("original-reviewed")
        let fakeTrash = root.appendingPathComponent("fake-trash")
        try FileManager.default.createDirectory(at: reviewed, withIntermediateDirectories: false)
        try Data("reviewed".utf8).write(to: reviewed.appendingPathComponent("marker"))
        let snapshot = try CleanupSnapshot.capture(list: list([reviewed.path]),
                                                   approvedRootURLs: [root])
        let plan = try snapshot.plan(selectedPaths: [reviewed.path])

        let result = CleanupExecutor.moveToTrash(plan) { source in
            // Simulate a same-user process replacing the reviewed name in the
            // instant after launch validation but before the Trash rename.
            try FileManager.default.moveItem(at: source, to: original)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            try Data("unreviewed".utf8).write(to: source.appendingPathComponent("marker"))
            try FileManager.default.moveItem(at: source, to: fakeTrash)
            return fakeTrash
        }

        XCTAssertEqual(result, .init(moved: 0, failed: 1))
        XCTAssertEqual(try String(contentsOf: reviewed.appendingPathComponent("marker")),
                       "unreviewed", "the raced object must be restored, not deleted")
        XCTAssertEqual(try String(contentsOf: original.appendingPathComponent("marker")),
                       "reviewed", "the reviewed inode remains untouched when its name changes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fakeTrash.path))
    }

    func testIrreversibleCleanupDeletesTheReviewedTreeAndReportsSuccess() throws {
        let item = root.appendingPathComponent("permanent cache")
        let nested = item.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: nested.appendingPathComponent("blob"))
        let snapshot = try CleanupSnapshot.capture(list: list([item.path]),
                                                   approvedRootURLs: [root])
        let plan = try snapshot.plan(selectedPaths: [item.path])

        let shell = plan.irreversibleCleanupShell()
        XCTAssertTrue(shell.contains("/usr/bin/find -x"))
        XCTAssertTrue(shell.contains("-depth -delete"))
        XCTAssertTrue(shell.contains("/usr/bin/stat -f '%d:%i:%u:%p'"),
                      "the reviewed identity must still be re-checked at the boundary")

        XCTAssertEqual(try runCleanupShell(shell), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.path))
    }

    func testIrreversibleCleanupRefusesWhenTheReviewedInodeWasSwapped() throws {
        let item = root.appendingPathComponent("swapped")
        let moved = root.appendingPathComponent("moved-away")
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
        try Data("reviewed".utf8).write(to: item.appendingPathComponent("marker"))
        let snapshot = try CleanupSnapshot.capture(list: list([item.path]),
                                                   approvedRootURLs: [root])
        let plan = try snapshot.plan(selectedPaths: [item.path])

        // Substitute a different directory at the reviewed NAME after review.
        try FileManager.default.moveItem(at: item, to: moved)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
        try Data("unreviewed".utf8).write(to: item.appendingPathComponent("marker"))

        XCTAssertEqual(try runCleanupShell(plan.irreversibleCleanupShell()),
                       ElevatedExitCode.boundaryCheckFailed)
        XCTAssertEqual(try String(contentsOf: item.appendingPathComponent("marker")),
                       "unreviewed", "the substituted inode must not be deleted")
        XCTAssertEqual(try String(contentsOf: moved.appendingPathComponent("marker")),
                       "reviewed", "the reviewed inode survives at its new name")
    }

    /// The deliberate trade behind deleting the tree rooted at the reviewed
    /// inode rather than an enumerated set of descendants pinned at review
    /// time.  The preview presents a cache ENTRY with a size, not a file list,
    /// so "everything under this exact directory" is what the user approved —
    /// and pinning the full set instead made a clean abort whenever the owning
    /// app wrote to its own cache between the preview and the confirmation.
    func testIrreversibleCleanupRemovesContentAddedUnderTheReviewedEntryAfterReview() throws {
        let item = root.appendingPathComponent("live cache")
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
        let snapshot = try CleanupSnapshot.capture(list: list([item.path]),
                                                   approvedRootURLs: [root])
        let plan = try snapshot.plan(selectedPaths: [item.path])

        try Data("written after review".utf8)
            .write(to: item.appendingPathComponent("added-later"))

        XCTAssertEqual(try runCleanupShell(plan.irreversibleCleanupShell()), 0,
                       "a cache written to between preview and confirmation still cleans")
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.path))
    }

    func testIrreversibleCleanupDeletesTheLinkNotItsTargetOutsideTheTree() throws {
        let item = root.appendingPathComponent("with-symlink")
        let outside = root.appendingPathComponent("outside-the-reviewed-tree")
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("precious".utf8).write(to: outside.appendingPathComponent("keep"))
        try FileManager.default.createSymbolicLink(
            at: item.appendingPathComponent("escape"), withDestinationURL: outside)

        let snapshot = try CleanupSnapshot.capture(list: list([item.path]),
                                                   approvedRootURLs: [root])
        let plan = try snapshot.plan(selectedPaths: [item.path])

        XCTAssertEqual(try runCleanupShell(plan.irreversibleCleanupShell()), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.path))
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("keep")),
                       "precious", "-delete must never follow a symlink out of the tree")
    }

    func testIrreversibleCleanupContinuesPastOneFailingEntryAndReportsFailure() throws {
        // The failure this test needs is a permission denial, and root has no
        // permissions to deny — as uid 0 the "undeletable" entry deletes fine
        // and the test would fail for a reason that isn't a defect.
        try XCTSkipIf(getuid() == 0, "the blocked entry is only blocked for a non-root user")

        let good = root.appendingPathComponent("removable")
        let blocked = root.appendingPathComponent("blocked")
        let locked = blocked.appendingPathComponent("locked")
        let child = locked.appendingPathComponent("undeletable")
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("stuck".utf8).write(to: child)
        // Clear the write bit on the NESTED directory so its entry cannot be
        // unlinked. This happens before capture: mutating a reviewed entry's
        // own mode afterwards would change its pinned identity and the
        // boundary check would refuse the whole run — a different outcome.
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: locked.path)
        }

        let snapshot = try CleanupSnapshot.capture(list: list([good.path, blocked.path]),
                                                   approvedRootURLs: [root])
        let plan = try snapshot.plan(selectedPaths: [good.path, blocked.path])

        let status = try runCleanupShell(plan.irreversibleCleanupShell())
        XCTAssertNotEqual(status, 0, "an entry that could not be removed must report failure")
        XCTAssertNotEqual(status, ElevatedExitCode.boundaryCheckFailed,
                          "a partial removal is not the same refusal as a changed review")
        XCTAssertFalse(FileManager.default.fileExists(atPath: good.path),
                       "one failing entry must not abandon the others")
        XCTAssertTrue(FileManager.default.fileExists(atPath: child.path))
    }


    private func runCleanupShell(_ shell: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", shell]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
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
