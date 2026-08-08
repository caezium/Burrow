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
        let identity: PinnedFileIdentity
        /// Every name below `identity`, captured without following symlinks.
        /// Irreversible execution consumes this exact set deepest-first; it
        /// never recursively deletes whatever happens to be below the top
        /// directory later.
        let descendants: [PinnedFileIdentity]
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
              items.allSatisfy({ item in
                  item.identity.matchesCurrent() &&
                      item.descendants.allSatisfy { $0.matchesCurrent() }
              }) else { return false }
        return items.allSatisfy { item in
            approvedRoots.contains { root in
                item.identity.device == root.device &&
                    item.identity.path != root.path &&
                    item.identity.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
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

    /// Materialize the exact reviewed tree into a digest-pinned manifest.
    /// The privileged shell copies and verifies that manifest beneath its
    /// private root before consuming it, so the command stays bounded even
    /// when a cache contains thousands of reviewed descendants.
    func prepareIrreversibleCleanup() throws -> CleanupIrreversibleExecution {
        try prepareIrreversibleCleanup(preCaptureDelaySeconds: 0,
                                       postCaptureDelaySeconds: 0)
    }

#if DEBUG
    func prepareIrreversibleCleanupForTesting(preCaptureDelaySeconds: UInt = 0,
                                               postCaptureDelaySeconds: UInt = 0) throws
        -> CleanupIrreversibleExecution {
        try prepareIrreversibleCleanup(preCaptureDelaySeconds: preCaptureDelaySeconds,
                                       postCaptureDelaySeconds: postCaptureDelaySeconds)
    }
#endif

    private func prepareIrreversibleCleanup(preCaptureDelaySeconds: UInt,
                                            postCaptureDelaySeconds: UInt) throws
        -> CleanupIrreversibleExecution {
        guard preCaptureDelaySeconds <= 5, postCaptureDelaySeconds <= 5,
              validateForLaunch() else {
            throw CleanupIrreversibleExecution.ExecutionError.invalidPlan
        }
        var identitiesByPath: [String: PinnedFileIdentity] = [:]
        for item in items {
            for identity in item.descendants + [item.identity] {
                if let existing = identitiesByPath[identity.path], existing != identity {
                    throw CleanupIrreversibleExecution.ExecutionError.invalidPlan
                }
                identitiesByPath[identity.path] = identity
            }
        }
        let identities = identitiesByPath.values.sorted { lhs, rhs in
            let lhsDepth = lhs.path.reduce(into: 0) { if $1 == "/" { $0 += 1 } }
            let rhsDepth = rhs.path.reduce(into: 0) { if $1 == "/" { $0 += 1 } }
            return lhsDepth == rhsDepth ? lhs.path < rhs.path : lhsDepth > rhsDepth
        }
        return try CleanupIrreversibleExecution(snapshotID: snapshotID,
                                                identities: identities,
                                                preCaptureDelaySeconds: preCaptureDelaySeconds,
                                                postCaptureDelaySeconds: postCaptureDelaySeconds)
    }

    private static func makeSeal(snapshotID: UUID, createdAt: Date, expiresAt: Date,
                                 roots: [PinnedFileIdentity], items: [Item]) -> Data {
        func line(_ i: PinnedFileIdentity) -> String {
            "\(i.path.utf8.count):\(i.path)|\(i.shellStatToken)"
        }
        var itemLines: [String] = []
        for item in items {
            itemLines.append("item:\(line(item.identity))")
            itemLines.append(contentsOf: item.descendants.map { "descendant:\(line($0))" })
            itemLines.append("--")
        }
        let payload = ([snapshotID.uuidString,
                        String(createdAt.timeIntervalSince1970.bitPattern),
                        String(expiresAt.timeIntervalSince1970.bitPattern)]
            + roots.map { "root:\(line($0))" } + ["--items--"] + itemLines)
            .joined(separator: "\n")
        return Data(SHA256.hash(data: Data(payload.utf8)))
    }
}

/// Owns the unprivileged source manifest until the elevated process exits.
/// The root shell never trusts this path directly: it copies the bytes into a
/// fresh 0700 directory and validates their SHA-256 digest before parsing.
final class CleanupIrreversibleExecution: @unchecked Sendable {
    enum ExecutionError: Error {
        case invalidPlan
        case cannotCreateManifest(Int32)
        case cannotWriteManifest(Int32)
    }

    let snapshotID: UUID
    let shell: String
    let quarantineRootPath: String

    private let manifestPath: String
    private let lock = NSLock()
    private var removed = false

    fileprivate init(snapshotID: UUID,
                     identities: [PinnedFileIdentity],
                     preCaptureDelaySeconds: UInt,
                     postCaptureDelaySeconds: UInt) throws {
        guard !identities.isEmpty,
              identities.allSatisfy({ identity in
                  !identity.path.unicodeScalars.contains {
                      CharacterSet.controlCharacters.contains($0)
                  }
              }) else { throw ExecutionError.invalidPlan }

        let manifest = identities.map { identity in
            let kind = identity.isDirectory ? "d" : "n"
            return "\(identity.shellStatToken)\t\(kind)\t\(identity.path)\n"
        }.joined()
        let data = Data(manifest.utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let writtenManifest = try Self.writeManifest(data)
        let privateRoot = "/private/var/tmp/dev.caezium.burrow.cleanup-\(snapshotID.uuidString)"
        manifestPath = writtenManifest.path
        self.snapshotID = snapshotID
        quarantineRootPath = privateRoot
        shell = Self.makeShell(manifestPath: writtenManifest.path,
                               manifestIdentity: writtenManifest.identity,
                               digest: digest,
                               quarantineRootPath: privateRoot,
                               preCaptureDelaySeconds: preCaptureDelaySeconds,
                               postCaptureDelaySeconds: postCaptureDelaySeconds)
    }

    func remove() {
        lock.lock()
        guard !removed else { lock.unlock(); return }
        removed = true
        lock.unlock()
        _ = Darwin.unlink(manifestPath)
    }

    deinit { remove() }

    private struct WrittenManifest {
        let path: String
        let identity: PinnedFileIdentity
    }

    private static func writeManifest(_ data: Data) throws -> WrittenManifest {
        var template = Array("/private/var/tmp/dev.caezium.burrow.cleanup-manifest.XXXXXX".utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { bytes in
            mkstemp(bytes.baseAddress)
        }
        guard descriptor >= 0 else { throw ExecutionError.cannotCreateManifest(errno) }
        let path = String(cString: template)
        var keep = false
        defer {
            Darwin.close(descriptor)
            if !keep { _ = Darwin.unlink(path) }
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw ExecutionError.cannotWriteManifest(errno)
        }
        let wroteAll = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
        var fileStat = stat()
        guard wroteAll, fsync(descriptor) == 0,
              fstat(descriptor, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG else {
            throw ExecutionError.cannotWriteManifest(errno)
        }
        keep = true
        return WrittenManifest(
            path: path,
            identity: PinnedFileIdentity(path: path,
                                         device: UInt64(fileStat.st_dev),
                                         inode: UInt64(fileStat.st_ino),
                                         owner: UInt32(fileStat.st_uid),
                                         mode: UInt16(fileStat.st_mode)))
    }

    private static func makeShell(manifestPath: String,
                                  manifestIdentity: PinnedFileIdentity,
                                  digest: String,
                                  quarantineRootPath: String,
                                  preCaptureDelaySeconds: UInt,
                                  postCaptureDelaySeconds: UInt) -> String {
        let source = MoleCLI.shellQuote(manifestPath)
        let root = MoleCLI.shellQuote(quarantineRootPath)
        let expectedDigest = MoleCLI.shellQuote(digest)
        var statements = [
            "burrow_root=\(root)",
            "burrow_source=\(source)",
            "burrow_source_capture=\"$burrow_root/source-manifest\"",
            "burrow_manifest=\"$burrow_root/manifest\"",
            "burrow_abort() { /bin/rm -f -- \"$burrow_manifest\" 2>/dev/null || true; /bin/rmdir -- \"$burrow_root\" 2>/dev/null || true; exit 124; }",
            "burrow_source_mismatch() { if [ ! -e \"$burrow_source\" ] && [ ! -L \"$burrow_source\" ]; then /bin/mv -n -- \"$burrow_source_capture\" \"$burrow_source\" 2>/dev/null || true; fi; burrow_abort; }",
            "burrow_verified_source_abort() { /bin/rm -f -- \"$burrow_source_capture\" 2>/dev/null || true; burrow_abort; }",
            "burrow_restore_abort() { if [ ! -e \"$burrow_original\" ] && [ ! -L \"$burrow_original\" ]; then /bin/mv -n -- \"$burrow_capture\" \"$burrow_original\" 2>/dev/null || true; fi; /bin/rmdir -- \"$burrow_node\" 2>/dev/null || true; burrow_abort; }",
            "/bin/mkdir -m 0700 -- \"$burrow_root\" || exit 124",
            "/bin/mv -- \"$burrow_source\" \"$burrow_source_capture\" || burrow_abort",
            "[ \"$(/usr/bin/stat -f '%d:%i:%u:%p' -- \"$burrow_source_capture\" 2>/dev/null)\" = '\(manifestIdentity.shellStatToken)' ] || burrow_source_mismatch",
            "/bin/cp -- \"$burrow_source_capture\" \"$burrow_manifest\" || burrow_verified_source_abort",
            "[ \"$(/usr/bin/shasum -a 256 -- \"$burrow_manifest\" | /usr/bin/cut -d ' ' -f 1)\" = \(expectedDigest) ] || burrow_verified_source_abort",
            "/bin/rm -f -- \"$burrow_source_capture\" || burrow_verified_source_abort",
            "burrow_index=0",
            "while IFS=\"$(/usr/bin/printf '\\t')\" read -r burrow_expected burrow_kind burrow_original; do [ -n \"$burrow_expected\" ] && [ -n \"$burrow_original\" ] || burrow_abort",
            "burrow_node=\"$burrow_root/node-$burrow_index\"",
            "burrow_capture=\"$burrow_node/captured\"",
            "/bin/mkdir -m 0700 -- \"$burrow_node\" || burrow_abort",
            "burrow_device=${burrow_expected%%:*}",
            "[ \"$(/usr/bin/stat -f '%d' -- \"$burrow_node\" 2>/dev/null)\" = \"$burrow_device\" ] || { /bin/rmdir -- \"$burrow_node\" 2>/dev/null || true; burrow_abort; }",
        ]
        if preCaptureDelaySeconds > 0 {
            statements.append("/bin/sleep \(preCaptureDelaySeconds)")
        }
        statements += [
            "/bin/mv -- \"$burrow_original\" \"$burrow_capture\" || { /bin/rmdir -- \"$burrow_node\" 2>/dev/null || true; burrow_abort; }",
            "[ \"$(/usr/bin/stat -f '%d:%i:%u:%p' -- \"$burrow_capture\" 2>/dev/null)\" = \"$burrow_expected\" ] || burrow_restore_abort",
        ]
        if postCaptureDelaySeconds > 0 {
            statements.append("/bin/sleep \(postCaptureDelaySeconds)")
        }
        statements += [
            "if [ \"$burrow_kind\" = d ]; then /bin/rmdir -- \"$burrow_capture\" || burrow_restore_abort; else /bin/rm -f -- \"$burrow_capture\" || burrow_restore_abort; fi",
            "/bin/rmdir -- \"$burrow_node\" || burrow_abort",
            "burrow_index=$((burrow_index + 1))",
            "done < \"$burrow_manifest\"",
            "/bin/rm -f -- \"$burrow_manifest\" || exit 124",
            "/bin/rmdir -- \"$burrow_root\" || exit 124",
        ]
        return statements.joined(separator: "; ")
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
            case .outsideApprovedRoots(let p): return "The cleanup preview escaped its approved roots: \(p)"
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
        for item in list.categories.flatMap(\.items) {
            let raw = item.path
            guard !raw.isEmpty, raw.hasPrefix("/"),
                  !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !raw.hasPrefix("{"), !raw.hasPrefix("[") else {
                throw SnapshotError.malformedPath(raw)
            }
            var lst = stat()
            guard lstat(raw, &lst) == 0 else { throw SnapshotError.missingPath(raw) }
            guard (lst.st_mode & S_IFMT) != S_IFLNK else { throw SnapshotError.symbolicLink(raw) }
            guard let canonical = InvokingUserIdentity.canonicalPath(raw), canonical == raw else {
                throw SnapshotError.symbolicLink(raw)
            }
            guard seen.insert(canonical).inserted else { continue }
            let identity = try PinnedFileIdentity.capture(canonical)
            _ = try approvedRoot(for: canonical, device: identity.device, roots: roots)
            let descendants = try captureDescendants(of: identity)
            captured.append(.init(identity: identity, descendants: descendants))
        }
        guard !captured.isEmpty else { throw SnapshotError.selectionMismatch }
        return Self(id: UUID(), createdAt: now, expiresAt: now.addingTimeInterval(lifetime),
                    list: list, approvedRoots: roots, items: captured)
    }

    /// Enumerate without following symlinks and then revalidate every captured
    /// identity. The enumeration need not be an atomic filesystem snapshot:
    /// anything missed by a concurrent addition is absent from the execution
    /// manifest, so the later `rmdir` fails instead of deleting it.
    private static func captureDescendants(of root: PinnedFileIdentity) throws
        -> [PinnedFileIdentity] {
        guard root.isDirectory else { return [] }
        let rootURL = URL(fileURLWithPath: root.path, isDirectory: true)
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL, includingPropertiesForKeys: nil, options: [],
            errorHandler: { _, _ in enumerationFailed = true; return false }) else {
            throw SnapshotError.staleOrChanged
        }

        var descendants: [PinnedFileIdentity] = []
        while let value = enumerator.nextObject() as? URL {
            if enumerationFailed { throw SnapshotError.staleOrChanged }
            let path = value.path
            guard path.hasPrefix(root.path + "/"),
                  !path.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }) else { throw SnapshotError.malformedPath(path) }
            let identity: PinnedFileIdentity
            do {
                identity = try PinnedFileIdentity.capture(path, rejectSymlink: false)
            } catch {
                throw SnapshotError.staleOrChanged
            }
            guard identity.device == root.device else {
                enumerator.skipDescendants()
                throw SnapshotError.unexpectedVolume(path)
            }
            if identity.isSymbolicLink { enumerator.skipDescendants() }
            descendants.append(identity)
        }
        guard !enumerationFailed, root.matchesCurrent(),
              descendants.allSatisfy({ $0.matchesCurrent() }) else {
            throw SnapshotError.staleOrChanged
        }
        return descendants
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
