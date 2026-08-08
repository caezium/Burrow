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

    private static func makeSeal(snapshotID: UUID, createdAt: Date, expiresAt: Date,
                                 roots: [PinnedFileIdentity], items: [Item]) -> Data {
        func line(_ i: PinnedFileIdentity) -> String {
            "\(i.path.utf8.count):\(i.path)|\(i.shellStatToken)"
        }
        let payload = ([snapshotID.uuidString,
                        String(createdAt.timeIntervalSince1970.bitPattern),
                        String(expiresAt.timeIntervalSince1970.bitPattern)]
            + roots.map(line) + ["--items--"] + items.map { line($0.identity) })
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
            captured.append(.init(identity: identity))
        }
        guard !captured.isEmpty else { throw SnapshotError.selectionMismatch }
        return Self(id: UUID(), createdAt: now, expiresAt: now.addingTimeInterval(lifetime),
                    list: list, approvedRoots: roots, items: captured)
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
                            fileManager: FileManager = .default) -> Result {
        guard plan.validateForLaunch() else { return Result(moved: 0, failed: plan.items.count) }
        var moved = 0, failed = 0
        for item in plan.items {
            guard item.identity.matchesCurrent() else { failed += 1; continue }
            do {
                try fileManager.trashItem(at: URL(fileURLWithPath: item.identity.path),
                                          resultingItemURL: nil)
                moved += 1
            } catch {
                failed += 1
            }
        }
        return Result(moved: moved, failed: failed)
    }
}
