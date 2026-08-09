//
//  CleanupAuthorization.swift
//  Burrow
//
//  The dry-run file is untrusted input.  A review is backed by one immutable,
//  short-lived snapshot of canonical allow roots and lstat identities.  The
//  confirmation renders that snapshot and execution consumes a sealed subset
//  of the same value; it never re-reads clean-list.txt for authority.
//

import Foundation
import CryptoKit
import Darwin

struct CleanupExecutionPlan: Sendable, Equatable {
    struct Item: Sendable, Equatable {
        /// The reviewed entry itself — the unit the preview actually showed
        /// the user, with its size and item count. Execution deletes the tree
        /// rooted at THIS pinned inode; it does not enumerate and pin every
        /// descendant, because the review never presented them individually.
        let identity: PinnedFileIdentity
    }

    let snapshotID: UUID
    let createdAt: Date
    let expiresAt: Date
    let approvedRoots: [PinnedFileIdentity]
    let items: [Item]
    private let seal: Data

    fileprivate init(snapshotID: UUID, createdAt: Date, expiresAt: Date,
                     approvedRoots: [PinnedFileIdentity], items: [Item]) {
        self.snapshotID = snapshotID
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.approvedRoots = approvedRoots
        self.items = items
        self.seal = Self.makeSeal(snapshotID: snapshotID, createdAt: createdAt,
                                  expiresAt: expiresAt, roots: approvedRoots, items: items)
    }

    func validateForLaunch(now: Date = Date()) -> Bool {
        guard now <= expiresAt, !items.isEmpty,
              seal == Self.makeSeal(snapshotID: snapshotID, createdAt: createdAt,
                                    expiresAt: expiresAt, roots: approvedRoots, items: items),
              approvedRoots.allSatisfy({ $0.matchesCurrent() }),
              items.allSatisfy({ $0.identity.matchesCurrent() }) else { return false }
        let rootPrefixes: [(device: UInt64, path: String, prefix: String)] = approvedRoots.map {
            ($0.device, $0.path, $0.path.hasSuffix("/") ? $0.path : $0.path + "/")
        }
        return items.allSatisfy { item in
            let path = item.identity.path
            let device = item.identity.device
            return rootPrefixes.contains { root in
                device == root.device && path != root.path && path.hasPrefix(root.prefix)
            }
        }
    }

    /// Checks serialized into the administrator shell. They are intentionally
    /// repeated after the password dialog because that dialog is an unbounded
    /// attacker-controlled delay.
    func executionBoundaryChecks() -> [String] {
        let expiry = Int(expiresAt.timeIntervalSince1970)
        let identities = approvedRoots + items.map(\.identity)
        return ["[ \"$(/bin/date +%s)\" -le \(expiry) ]"] + identities.map { identity in
            let path = MoleCLI.shellQuote(identity.path)
            let token = MoleCLI.shellQuote(identity.shellStatToken)
            return "[ \"$(/usr/bin/stat -f '%d:%i:%u:%p' -- \(path) 2>/dev/null)\" = \(token) ]"
        }
    }

    /// The reviewed paths, deepest-first.
    ///
    /// Not cosmetic. The engine's export list routinely contains a parent and
    /// its own children as separate entries — `~/Library/Caches` alongside
    /// `~/Library/Caches/GeoServices` — because the writer collapses some
    /// categories to a parent while others name leaves. Deleting the parent
    /// first makes every nested entry vanish before its turn, and `find` then
    /// exits nonzero with "No such file or directory" for work that actually
    /// succeeded. Deepest-first removes the children before the parent, so
    /// each entry still exists when it is reached.
    ///
    /// Both elevation routes MUST use this order; the helper path skipping it
    /// is exactly how a fully successful clean reported "exit 1".
    func orderedReviewedPaths() -> [String] {
        func depth(_ path: String) -> Int { path.filter { $0 == "/" }.count }
        return items.map(\.identity.path).sorted { lhs, rhs in
            let l = depth(lhs), r = depth(rhs)
            return l == r ? lhs < rhs : l > r
        }
    }

    /// The shell-quoted form of `orderedReviewedPaths()`, for the delete loop.
    func quotedReviewedPaths() -> [String] {
        orderedReviewedPaths().map { MoleCLI.shellQuote($0) }
    }

    /// The complete irreversible cleanup: boundary checks, then the deletes.
    ///
    /// This lives beside the plan that authorizes it rather than inside the
    /// AppleScript builder, so a test can execute exactly the semantics that
    /// ship instead of reconstructing them from a quoted wrapper.
    ///
    /// `find -delete` is doing real safety work here, not just recursion.
    /// BSD `find` chdir's as it descends, so every unlink is relative to the
    /// directory it is standing in rather than a re-resolved path, and it
    /// refuses to delete any name whose path relative to "." contains a "/" —
    /// which is precisely the mid-walk directory-swap case.  Following
    /// symlinks is incompatible with `-delete`, so it cannot be redirected out
    /// of the tree, and `-x` holds it to the volume the boundary check pinned.
    ///
    /// A failing entry does not abandon the rest: the loop records it and the
    /// aggregate status reports it once.  `find` names each failing path on
    /// stderr, which the caller redirects into the run log, so the transcript
    /// says which entries survived.
    ///
    /// Success is decided by the POSTCONDITION, never by find's exit status.
    /// BSD `-delete` is documented to "always return true", so `find` exits 0
    /// having printed `unlink(...): Permission denied` and deleted nothing —
    /// trusting its status is how a cleanup that removed nothing reports
    /// "Done — caches cleared". Asking whether the entry is actually gone also
    /// covers the cases find never reports at all.
    func irreversibleCleanupShell() -> String {
        let checks = executionBoundaryChecks().map {
            $0 + " || exit \(ElevatedExitCode.boundaryCheckFailed)"
        }
        let paths = quotedReviewedPaths().joined(separator: " ")
        let loop = "failed=0; for p in \(paths); do "
            + "/usr/bin/find -x \"$p\" -depth -delete; "
            + "if [ -e \"$p\" ] || [ -L \"$p\" ]; then failed=1; fi; "
            + "done; [ \"$failed\" -eq 0 ]"
        return (checks + [loop]).joined(separator: "; ")
    }

    private static func makeSeal(snapshotID: UUID, createdAt: Date, expiresAt: Date,
                                 roots: [PinnedFileIdentity], items: [Item]) -> Data {
        func line(_ i: PinnedFileIdentity) -> String {
            "\(i.path.utf8.count):\(i.path)|\(i.shellStatToken)"
        }
        let payload = ([snapshotID.uuidString,
                        String(createdAt.timeIntervalSince1970.bitPattern),
                        String(expiresAt.timeIntervalSince1970.bitPattern)]
            + roots.map { "root:\(line($0))" } + ["--items--"]
            + items.map { "item:\(line($0.identity))" })
            .joined(separator: "\n")
        return Data(SHA256.hash(data: Data(payload.utf8)))
    }
}

struct CleanupSnapshot: Sendable, Equatable {
    enum SnapshotError: LocalizedError, Equatable {
        case noApprovedRoots
        case malformedPath(String)
        case symbolicLink(String)
        case outsideApprovedRoots(String)
        case unexpectedVolume(String)
        case missingPath(String)
        case selectionMismatch
        case staleOrChanged

        var errorDescription: String? {
            switch self {
            case .noApprovedRoots: return "No canonical cleanup roots are available."
            case .malformedPath(let p): return "The cleanup preview contained a malformed path: \(p)"
            case .symbolicLink(let p): return "The cleanup preview contained a symbolic link: \(p)"
            case .outsideApprovedRoots(let p):
                // Naming the offending path first: the old wording read as
                // though the listed path were the approved root, which sent
                // the reader looking in exactly the wrong place.
                return "\(p) is outside the folders Burrow is allowed to clean."
            case .unexpectedVolume(let p): return "The cleanup preview crossed onto an unexpected volume: \(p)"
            case .missingPath(let p): return "A reviewed cleanup item no longer exists: \(p)"
            case .selectionMismatch: return "The cleanup selection no longer matches the reviewed preview."
            case .staleOrChanged: return "The cleanup preview is stale or changed."
            }
        }
    }

    static let lifetime: TimeInterval = 300

    let id: UUID
    let createdAt: Date
    let expiresAt: Date
    let list: CleanList
    let approvedRoots: [PinnedFileIdentity]
    let items: [CleanupExecutionPlan.Item]
    /// Preview entries this snapshot refused, and why.
    ///
    /// These exist because the engine's export list collapses siblings to
    /// their common PARENT: a category that removes two or more loose files
    /// sitting directly inside an approved root records the root itself. The
    /// `.DS_Store` sweep does exactly that — `find "$HOME" -name .DS_Store`
    /// over a home folder with more than one match collapses to `$HOME` — so
    /// accepting the entry would mean deleting the user's home directory.
    ///
    /// Refusing it is right. Refusing the WHOLE preview because of it was not:
    /// one 471 KB entry blocked 1.79 GB of legitimate cleanup, and the Clean
    /// button vanished with no way to proceed. Entries are independent, so a
    /// refusal is now per-entry and reported rather than fatal.
    let skipped: [SkippedEntry]

    struct SkippedEntry: Equatable, Sendable {
        let path: String
        let reason: String
    }

    static func capture(list: CleanList,
                        approvedRootURLs: [URL],
                        now: Date = Date()) throws -> Self {
        let roots = try approvedRootURLs.compactMap { raw -> PinnedFileIdentity? in
            guard let canonical = InvokingUserIdentity.canonicalPath(raw.path) else { return nil }
            let identity = try PinnedFileIdentity.capture(canonical)
            guard identity.isDirectory else { return nil }
            return identity
        }
        guard !roots.isEmpty else { throw SnapshotError.noApprovedRoots }

        var seen = Set<String>()
        var captured: [CleanupExecutionPlan.Item] = []
        var skipped: [SkippedEntry] = []

        // Every refusal below is per-entry. Skipping can only ever REMOVE
        // something from the delete set, so failing this way is strictly safer
        // than the previous behaviour, which was to abandon the whole plan.
        func refuse(_ path: String, _ error: SnapshotError) {
            skipped.append(SkippedEntry(path: path,
                                        reason: error.errorDescription ?? "Refused."))
        }

        for item in list.categories.flatMap(\.items) {
            let raw = item.path
            // Structural corruption is still FATAL. A relative path, a NUL, a
            // newline or a JSON fragment is not something the engine's export
            // writer can produce, so the list isn't the list — and a preview
            // that isn't trustworthy shouldn't be partially executed. Every
            // check below this one is about an entry being unrepresentable,
            // which is an ordinary fact about a well-formed list.
            guard !raw.isEmpty, raw.hasPrefix("/"),
                  !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !raw.hasPrefix("{"), !raw.hasPrefix("[") else {
                throw SnapshotError.malformedPath(raw)
            }
            var lst = stat()
            guard lstat(raw, &lst) == 0 else { refuse(raw, .missingPath(raw)); continue }
            guard (lst.st_mode & S_IFMT) != S_IFLNK else {
                refuse(raw, .symbolicLink(raw)); continue
            }
            guard let canonical = InvokingUserIdentity.canonicalPath(raw), canonical == raw else {
                refuse(raw, .symbolicLink(raw)); continue
            }
            guard seen.insert(canonical).inserted else { continue }
            guard let identity = try? PinnedFileIdentity.capture(canonical) else {
                refuse(canonical, .missingPath(canonical)); continue
            }
            do {
                _ = try approvedRoot(for: canonical, device: identity.device, roots: roots)
            } catch let error as SnapshotError {
                refuse(canonical, error); continue
            }
            captured.append(.init(identity: identity))
        }
        // Only a preview with NOTHING usable is fatal. Anything else stays
        // cleanable, minus the entries named in `skipped`.
        guard !captured.isEmpty else { throw SnapshotError.selectionMismatch }
        return Self(id: UUID(), createdAt: now, expiresAt: now.addingTimeInterval(lifetime),
                    list: list, approvedRoots: roots, items: captured, skipped: skipped)
    }

    static func approvedRoot(for path: String, device: UInt64,
                             roots: [PinnedFileIdentity]) throws -> PinnedFileIdentity {
        guard let root = roots.first(where: {
            path != $0.path && path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/")
        }) else { throw SnapshotError.outsideApprovedRoots(path) }
        guard device == root.device else { throw SnapshotError.unexpectedVolume(path) }
        return root
    }

    func plan(selectedPaths: [String], now: Date = Date()) throws -> CleanupExecutionPlan {
        guard now <= expiresAt else { throw SnapshotError.staleOrChanged }
        let selected = Set(selectedPaths)
        let byPath = Dictionary(uniqueKeysWithValues: items.map { ($0.identity.path, $0) })
        guard !selected.isEmpty, selected.count == selectedPaths.count,
              selected.allSatisfy({ byPath[$0] != nil }) else {
            throw SnapshotError.selectionMismatch
        }
        let ordered = items.filter { selected.contains($0.identity.path) }
        let result = CleanupExecutionPlan(snapshotID: id, createdAt: createdAt,
                                          expiresAt: expiresAt,
                                          approvedRoots: approvedRoots, items: ordered)
        guard result.validateForLaunch(now: now) else { throw SnapshotError.staleOrChanged }
        return result
    }

    static func approvedRoots(for user: InvokingUserIdentity) -> [URL] {
        [URL(fileURLWithPath: user.canonicalHome, isDirectory: true),
         URL(fileURLWithPath: "/Library/Caches", isDirectory: true),
         URL(fileURLWithPath: "/Library/Logs", isDirectory: true),
         URL(fileURLWithPath: "/private/var/folders", isDirectory: true)]
    }
}

enum CleanupExecutor {
    struct Result: Sendable, Equatable { let moved: Int; let failed: Int }

    static func moveToTrash(_ plan: CleanupExecutionPlan,
                            move: (URL) throws -> URL = systemTrashMove) -> Result {
        guard plan.validateForLaunch() else { return Result(moved: 0, failed: plan.items.count) }
        var moved = 0, failed = 0
        for item in plan.items {
            guard item.identity.matchesCurrent() else { failed += 1; continue }
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC |
                (item.identity.isDirectory ? O_DIRECTORY : 0)
            let descriptor = Darwin.open(item.identity.path, flags)
            guard descriptor >= 0 else { failed += 1; continue }
            defer { Darwin.close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0,
                  UInt64(opened.st_dev) == item.identity.device,
                  UInt64(opened.st_ino) == item.identity.inode,
                  UInt32(opened.st_uid) == item.identity.owner,
                  UInt16(opened.st_mode) == item.identity.mode else {
                failed += 1
                continue
            }
            do {
                let source = URL(fileURLWithPath: item.identity.path)
                let destination = try move(source)
                guard let captured = try? PinnedFileIdentity.capture(destination.path),
                      captured.device == item.identity.device,
                      captured.inode == item.identity.inode,
                      captured.owner == item.identity.owner,
                      captured.mode == item.identity.mode else {
                    // FileManager's Trash operation is an atomic rename on the
                    // source volume, but its API is path-based. If another
                    // process swapped the name between our check and that
                    // rename, the returned destination contains the wrong
                    // vnode. Put that recoverable object back when possible;
                    // if its name was occupied again, leave it in Trash.
                    restoreUnreviewedItem(at: destination, to: source)
                    failed += 1
                    continue
                }
                moved += 1
            } catch {
                failed += 1
            }
        }
        return Result(moved: moved, failed: failed)
    }

    private static func systemTrashMove(_ source: URL) throws -> URL {
        var destination: NSURL?
        try FileManager.default.trashItem(at: source, resultingItemURL: &destination)
        guard let destination else { throw CocoaError(.fileWriteUnknown) }
        return destination as URL
    }

    private static func restoreUnreviewedItem(at captured: URL, to original: URL) {
        var current = stat()
        guard lstat(original.path, &current) != 0, errno == ENOENT else { return }
        // moveItem refuses an occupied destination, so a second race can only
        // make restoration fail closed and leave the object recoverable.
        try? FileManager.default.moveItem(at: captured, to: original)
    }
}
