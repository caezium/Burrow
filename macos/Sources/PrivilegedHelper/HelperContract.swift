//
//  HelperContract.swift
//  Burrow / BurrowHelper (shared)
//
//  The wire contract between the GUI and the root helper. Compiled into BOTH
//  targets so the two can never disagree about what a request means.
//
//  Everything in this file is pure Foundation — no SwiftUI, no Sparkle, no
//  Sentry — because the helper is a bare launchd daemon that must stay small,
//  auditable, and free of anything that could pull UI or network code into a
//  root process.
//
//  ── Why the contract looks like this ────────────────────────────────────
//  The old elevation path handed osascript a SHELL STRING built from an
//  executable path plus argv (`MoleCLI.elevatedScript`). It was carefully
//  quoted and well tested, but its shape meant the privileged side had to
//  trust whatever command the caller composed.
//
//  This contract inverts that. A request names an OPERATION and nothing else.
//  The argv is derived from the enum on the privileged side, so the set of
//  commands the helper can ever run is fixed at compile time and visible in
//  one switch statement. There is deliberately no field for a path, a flag, a
//  binary, or a command string — a client that is fully compromised still
//  cannot express "run this".
//

import Foundation

// MARK: - The closed operation set

/// Every privileged thing Burrow can ask for. Adding a case here is a
/// security decision, not a feature decision: it widens what the root daemon
/// is capable of doing, permanently, for every installed copy.
enum HelperOperation: String, Codable, CaseIterable, Sendable {
    /// Enumerate what a clean WOULD remove. Reads privileged locations; the
    /// engine's `--dry-run` guarantees no mutation.
    case scan
    /// Remove the caches the engine's own rules select.
    case clean
    /// Remove exactly the entries the user reviewed and ticked.
    ///
    /// This is the only operation that accepts data from the caller beyond a
    /// verb, which deserves saying plainly. It does NOT weaken the rule that a
    /// compromised client cannot express "run this": the argv is still built
    /// here, the executable is still a fixed absolute path, and the paths are
    /// values passed to a delete, never anything executed.
    ///
    /// What stops a compromised client asking root to delete something it
    /// shouldn't is that the daemon does not trust the list. It rebuilds the
    /// approved roots from its OWN getpwuid record, and re-derives every fact
    /// it checks — existence, symlink-ness, canonical form, volume, owner —
    /// with its own lstat. The client proposes; the privileged side decides.
    case cleanReviewed
    /// The engine's maintenance pass.
    case optimize
    /// Enumerate what an optimize WOULD do. The optimize counterpart of
    /// `scan`, so the elevated preview of either operation behaves the same.
    case optimizeScan
    /// Flush the DNS cache and signal mDNSResponder to reload.
    case flushDNS
    /// Renew the DHCP lease on one network interface.
    case renewDHCP
    /// Dump the Background Task Management database — the modern Login and
    /// background items list.
    ///
    /// Read-only, but it needs root twice over: `sfltool dumpbtm` raises its
    /// OWN authentication dialog when run as a normal user, and returns only
    /// a partial list even then. Through the helper it is one authentication
    /// the user already understands, and the complete list.
    case readLoginItems

    /// The engine argv for the operations that drive the bundled engine, or
    /// nil for the ones that don't.
    ///
    /// These reproduce what the GUI runs today through osascript — CleanView's
    /// `["clean"]`, OptimizeView's `["optimize"]`, and the dry-run previews —
    /// so the helper changes HOW the command is elevated, never WHAT runs.
    var engineArguments: [String]? {
        switch self {
        case .scan: return ["clean", "--dry-run"]
        case .clean: return ["clean"]
        case .optimize: return ["optimize"]
        case .optimizeScan: return ["optimize", "--dry-run"]
        case .flushDNS, .renewDHCP, .readLoginItems, .cleanReviewed: return nil
        }
    }

    /// Whether this operation needs a network interface name.
    var needsInterface: Bool { self == .renewDHCP }

    /// Whether this operation is driven by a reviewed path list. Exactly one
    /// operation is, and it is required to be non-empty for that one and
    /// required to be absent for every other.
    var needsReviewedPaths: Bool { self == .cleanReviewed }

    /// The exact process steps the daemon runs, in order.
    ///
    /// Every executable is an absolute path from a closed set, and every
    /// argument is either a literal spelled here or an interface name that
    /// `HelperRequest.validate` has already proved is a real interface on this
    /// machine. Nothing is passed to a shell.
    ///
    /// That last point is a security improvement over the path this replaces:
    /// `Connectivity.run` currently elevates
    /// `/bin/sh -c "dscacheutil -flushcache; killall -HUP mDNSResponder"`,
    /// so a root shell parses a command string. Here the two commands are two
    /// separate `posix_spawn` calls with fixed argv and no shell in between.
    func steps(interface: String?, reviewedPaths: [String] = []) -> [HelperStep] {
        switch self {
        case .scan, .clean, .optimize, .optimizeScan:
            return [HelperStep(executable: .bundledEngine, arguments: engineArguments ?? [])]
        case .cleanReviewed:
            // One `find` per reviewed entry, each with fixed flags around a
            // path the daemon has already validated. `-x` holds it to the
            // entry's own volume, `-delete` implies depth-first and refuses to
            // follow symlinks, and BSD find chdir's as it descends so each
            // unlink is relative to the directory it is standing in rather
            // than a re-resolved path.
            return reviewedPaths.map {
                HelperStep(executable: .system(HelperSystemTool.find),
                           arguments: ["-x", $0, "-depth", "-delete"])
            }
        case .flushDNS:
            return [
                HelperStep(executable: .system(HelperSystemTool.dscacheutil), arguments: ["-flushcache"]),
                HelperStep(executable: .system(HelperSystemTool.killall), arguments: ["-HUP", "mDNSResponder"]),
            ]
        case .renewDHCP:
            guard let interface else { return [] }
            return [HelperStep(executable: .system(HelperSystemTool.ipconfig),
                               arguments: ["set", interface, "DHCP"])]
        case .readLoginItems:
            return [HelperStep(executable: .system(HelperSystemTool.sfltool),
                               arguments: ["dumpbtm"])]
        }
    }

    /// Whether this operation mutates the disk. `scan` is read-only, but it
    /// still authenticates: it reads privileged locations, and the product
    /// decision was that anything running AS ROOT prompts.
    var mutatesDisk: Bool {
        switch self {
        case .scan, .optimizeScan: return false
        case .clean, .optimize, .cleanReviewed: return true
        // These change system state or read privileged data rather than
        // touching the filesystem, but all run as root, so all authenticate.
        case .flushDNS, .renewDHCP: return false
        case .readLoginItems: return false
        }
    }

    /// Recognise an existing elevated call site's argv as a typed operation,
    /// or `nil` if it isn't one of them.
    ///
    /// This is the migration seam. The GUI still describes elevated work as
    /// `["clean"]` / `["optimize"]` through `OperationFlow`, and this maps
    /// those onto the helper WITHOUT letting anything else through: argv the
    /// helper doesn't recognise returns nil and keeps the existing osascript
    /// route, rather than being forwarded as some approximate operation.
    init?(engineArguments: [String]) {
        guard let match = HelperOperation.allCases.first(where: {
            guard let candidate = $0.engineArguments else { return false }
            return candidate == engineArguments
        }) else { return nil }
        self = match
    }
}

// MARK: - Execution model

/// The only system binaries the daemon may ever execute, by absolute path.
///
/// A closed set, spelled once. The daemon never resolves a name through
/// `PATH` and never accepts a path from a caller — those are the two ways a
/// root process ends up running somebody else's binary.
enum HelperSystemTool {
    static let dscacheutil = "/usr/bin/dscacheutil"
    static let killall = "/usr/bin/killall"
    static let ipconfig = "/usr/sbin/ipconfig"
    static let sfltool = "/usr/bin/sfltool"
    static let find = "/usr/bin/find"

    /// Every permitted absolute path. Used by the daemon to re-check an
    /// executable immediately before spawning it, so a step constructed by
    /// some future code path still cannot introduce a new binary.
    static let all: Set<String> = [dscacheutil, killall, ipconfig, sfltool, find]
}

/// What a step runs.
enum HelperExecutable: Equatable, Sendable {
    /// The signed engine inside our own app bundle, resolved by the daemon.
    case bundledEngine
    /// One of `HelperSystemTool.all`, by absolute path.
    case system(String)
}

/// One process the daemon spawns. An operation is an ordered list of these.
struct HelperStep: Equatable, Sendable {
    let executable: HelperExecutable
    let arguments: [String]
}

// MARK: - Invoking user

/// The non-privileged app's statement of who initiated the operation. This is
/// a consistency claim, never authority: the daemon binds it to the XPC
/// peer's effective uid and reconstructs the account from its own user
/// database before using either value.
struct HelperInvokingUserClaim: Codable, Equatable, Sendable {
    let uid: UInt32
    let canonicalHome: String
}

/// One account record from the daemon's user database. Kept as data so the
/// selection rule can be tested with several signed-in/local accounts without
/// consulting the test runner's real account.
struct HelperInvokingUserAccount: Equatable, Sendable {
    let uid: UInt32
    let username: String
    let homeDirectory: String
}

/// The daemon's descriptor-based inspection of the home named by getpwuid.
/// A path supplied by the client never creates this value.
struct HelperHomeInspection: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case directory
        case symbolicLink
        case other
        case missing
    }

    let kind: Kind
    let canonicalPath: String?
    let ownerUID: UInt32?
}

struct HelperResolvedInvokingUser: Equatable, Sendable {
    let uid: UInt32
    let username: String
    let canonicalHome: String

    /// A complete, deterministic environment for every root child. Nothing is
    /// inherited from launchd and no client-provided string is copied here.
    var childEnvironment: [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": canonicalHome,
            "USER": username,
            "LOGNAME": username,
            "SUDO_USER": username,
            "SUDO_UID": String(uid),
            "LC_ALL": "C",
        ]
    }
}

enum HelperInvokingUserResolutionError: Error, Equatable, Sendable {
    case rootPeer
    case claimUIDMismatch
    case missingAccount
    case invalidUsername
    case invalidAccountHome
    case missingHome
    case symbolicLinkHome
    case homeNotDirectory
    case homeOwnerMismatch
    case canonicalHomeMismatch
}

/// The fail-closed identity rule shared by the app tests and daemon. The
/// daemon supplies getpwuid data and a no-follow filesystem inspection; this
/// function decides whether those authoritative facts agree with the XPC peer
/// and the app's pre-authorization claim.
enum HelperInvokingUserResolver {
    static func resolve(
        peerUID: UInt32,
        claim: HelperInvokingUserClaim,
        accounts: [HelperInvokingUserAccount],
        inspectHome: (String) -> HelperHomeInspection
    ) throws -> HelperResolvedInvokingUser {
        guard peerUID != 0 else { throw HelperInvokingUserResolutionError.rootPeer }
        guard claim.uid == peerUID else { throw HelperInvokingUserResolutionError.claimUIDMismatch }
        guard let account = accounts.first(where: { $0.uid == peerUID }) else {
            throw HelperInvokingUserResolutionError.missingAccount
        }
        guard isSafeEnvironmentValue(account.username), account.username != "root" else {
            throw HelperInvokingUserResolutionError.invalidUsername
        }
        guard account.homeDirectory.hasPrefix("/"),
              isSafeEnvironmentValue(account.homeDirectory) else {
            throw HelperInvokingUserResolutionError.invalidAccountHome
        }

        let home = inspectHome(account.homeDirectory)
        switch home.kind {
        case .missing: throw HelperInvokingUserResolutionError.missingHome
        case .symbolicLink: throw HelperInvokingUserResolutionError.symbolicLinkHome
        case .other: throw HelperInvokingUserResolutionError.homeNotDirectory
        case .directory: break
        }
        guard let canonicalHome = home.canonicalPath,
              canonicalHome.hasPrefix("/"), canonicalHome != "/",
              canonicalHome != "/var/root", canonicalHome != "/private/var/root",
              isSafeEnvironmentValue(canonicalHome) else {
            throw HelperInvokingUserResolutionError.invalidAccountHome
        }
        guard home.ownerUID == peerUID else {
            throw HelperInvokingUserResolutionError.homeOwnerMismatch
        }
        guard claim.canonicalHome == canonicalHome else {
            throw HelperInvokingUserResolutionError.canonicalHomeMismatch
        }

        return HelperResolvedInvokingUser(uid: peerUID,
                                         username: account.username,
                                         canonicalHome: canonicalHome)
    }

    private static func isSafeEnvironmentValue(_ value: String) -> Bool {
        !value.isEmpty && !value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }
}

// MARK: - Reviewed cleanup targets

/// One approved root, as the DAEMON derives it. The invoking user's home comes
/// from getpwuid and the rest are fixed system cache locations; a client never
/// contributes to this list.
struct HelperReviewedRoot: Equatable, Sendable {
    let path: String
    let device: UInt64
    /// System cache trees are root-owned and shared, so their contents
    /// legitimately belong to other accounts. A per-user tree is not: deleting
    /// another account's files there would be a real escalation, since the
    /// invoking user could not do it themselves.
    let allowsForeignOwner: Bool

    var prefix: String { path.hasSuffix("/") ? path : path + "/" }
}

/// The daemon's own lstat of a proposed target. Injected so the rule below is
/// a pure function and can be tested against layouts the test host doesn't have.
struct HelperReviewedTarget: Equatable, Sendable {
    let exists: Bool
    let isSymbolicLink: Bool
    let canonicalPath: String?
    let device: UInt64
    let ownerUID: UInt32
}

enum HelperReviewedPathRejection: String, Error, Codable, Equatable, Sendable {
    case emptySelection
    case tooManyTargets
    case malformedPath
    case missingPath
    case symbolicLink
    case notCanonical
    case outsideApprovedRoots
    case foreignVolume
    case foreignOwner
}

/// What root is allowed to delete on a client's say-so.
///
/// Every rule here is enforced against facts the daemon gathered itself. The
/// client's list is a proposal; nothing in it is taken on trust, including
/// whether a path exists or where it points.
enum HelperReviewedPathPolicy {
    /// A reviewed clean is a handful of cache entries. A list far past that is
    /// not a user's selection, and an unbounded one is a way to make the root
    /// daemon do unbounded work.
    static let maximumTargets = 4096

    static func validate(paths: [String],
                         roots: [HelperReviewedRoot],
                         invokingUID: UInt32,
                         inspect: (String) -> HelperReviewedTarget)
        -> Result<[String], HelperReviewedPathRejection> {
        guard !paths.isEmpty else { return .failure(.emptySelection) }
        guard paths.count <= maximumTargets else { return .failure(.tooManyTargets) }
        guard !roots.isEmpty else { return .failure(.outsideApprovedRoots) }

        var accepted: [String] = []
        var seen = Set<String>()
        for path in paths {
            guard path.hasPrefix("/"), path != "/", !path.hasSuffix("/"),
                  !path.contains("/../"), !path.hasSuffix("/.."),
                  !path.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }) else { return .failure(.malformedPath) }

            let target = inspect(path)
            guard target.exists else { return .failure(.missingPath) }
            // A symlink would let the delete land on whatever it points at.
            guard !target.isSymbolicLink else { return .failure(.symbolicLink) }
            // realpath must agree with the literal path, so no component along
            // the way is a link either.
            guard let canonical = target.canonicalPath, canonical == path else {
                return .failure(.notCanonical)
            }
            // A root itself is never deletable — only things strictly below it.
            guard let root = roots.first(where: {
                path != $0.path && path.hasPrefix($0.prefix)
            }) else { return .failure(.outsideApprovedRoots) }
            guard target.device == root.device else { return .failure(.foreignVolume) }
            guard root.allowsForeignOwner || target.ownerUID == invokingUID else {
                return .failure(.foreignOwner)
            }
            // Duplicates are dropped rather than refused: the same entry twice
            // is harmless, and the second find would just fail on a missing path.
            if seen.insert(path).inserted { accepted.append(path) }
        }
        return .success(accepted)
    }
}

// MARK: - Request

/// Why a request never reached the authorization step. Named so the GUI can
/// explain the refusal instead of showing a bare failure, and so a rejection
/// is never confused with "the command ran and failed".
enum HelperRequestRejection: String, Codable, Equatable, Sendable {
    /// The payload wasn't decodable as a request at all.
    case malformedPayload
    /// The operation ID wasn't a UUID (see `HelperRequest.operationID`).
    case malformedOperationID
    /// The helper's build doesn't match the app's — see `HelperVersionSkew`.
    case buildMismatch
    /// This operation ID was already served. One authorization, one operation.
    case replayedOperationID
    /// The interface name was missing, malformed, or not a real interface on
    /// this machine — or was supplied for an operation that takes none.
    case invalidInterface
    /// The invoking-user claim was malformed or did not match the XPC peer,
    /// daemon account database, and inspected home directory.
    case invalidInvokingUser
    /// The reviewed path list was missing, oversized, or contained an entry
    /// the daemon's own inspection refused. See `HelperReviewedPathPolicy`.
    case invalidReviewedPaths
}

/// One privileged operation, fully described. None of its fields can carry a
/// command; the identity fields are consistency claims checked by the daemon.
struct HelperRequest: Codable, Equatable, Sendable {
    let operation: HelperOperation

    /// A fresh UUID per request. This is the replay key: the daemon serves any
    /// given ID at most once, so a captured payload — external authorization
    /// form and all — cannot be resent to buy a second root run out of one
    /// prompt. A client-chosen constant would defeat that, hence the format
    /// check rather than "any non-empty string".
    let operationID: String

    /// `CFBundleVersion` of the calling app, compared against the helper's own.
    /// A registered daemon outlives the app that installed it (Sparkle replaces
    /// Burrow.app underneath it), and a stale root helper holding an older idea
    /// of what `clean` does is exactly the drift worth refusing.
    let clientBuild: String

    /// The uid and canonical home resolved by the app before authentication.
    /// This is mandatory context for every privileged action, but only a
    /// claim: the daemon independently resolves and verifies both values.
    let invokingUser: HelperInvokingUserClaim

    /// The network interface for `renewDHCP`, and nil for everything else.
    ///
    /// This is the ONLY caller-supplied value that reaches a child process's
    /// argv, which is why it is checked twice: against a strict character
    /// shape, and against the interfaces that actually exist on this machine.
    /// A name that isn't a real interface is refused rather than passed on.
    var networkInterface: String? = nil

    /// The entries the user reviewed and ticked, for `cleanReviewed` and
    /// nothing else.
    ///
    /// These reach a child process's argv, but only as operands to a fixed
    /// `find … -delete` the daemon composes, and only after the daemon has
    /// re-derived every fact it checks about them. Empty for every other
    /// operation, and an operation that carries them when it shouldn't is
    /// refused rather than having them ignored.
    var reviewedPaths: [String] = []

    init(operation: HelperOperation,
         operationID: String,
         clientBuild: String,
         invokingUser: HelperInvokingUserClaim,
         networkInterface: String? = nil,
         reviewedPaths: [String] = []) {
        self.operation = operation
        self.operationID = operationID
        self.clientBuild = clientBuild
        self.invokingUser = invokingUser
        self.networkInterface = networkInterface
        self.reviewedPaths = reviewedPaths
    }

    /// `nil` when the request is well formed. Runs on the PRIVILEGED side —
    /// the client's own validation is a courtesy, this one is the boundary.
    ///
    /// `liveInterfaces` is injected so the rule stays pure and testable; the
    /// daemon passes the real list from the system.
    func validate(expectedBuild: String,
                  liveInterfaces: @autoclosure () -> Set<String> = []) -> HelperRequestRejection? {
        guard UUID(uuidString: operationID) != nil else { return .malformedOperationID }
        guard HelperVersionSkew.evaluate(appBuild: expectedBuild, helperBuild: clientBuild) == .matched else {
            return .buildMismatch
        }
        guard invokingUser.uid != 0,
              invokingUser.canonicalHome.hasPrefix("/"),
              invokingUser.canonicalHome != "/",
              invokingUser.canonicalHome != "/var/root",
              invokingUser.canonicalHome != "/private/var/root",
              !invokingUser.canonicalHome.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else { return .invalidInvokingUser }

        if operation.needsReviewedPaths {
            // Shape only. Whether these paths may actually be deleted is
            // decided by HelperReviewedPathPolicy against the daemon's own
            // lstat — this check just refuses obvious nonsense early.
            guard !reviewedPaths.isEmpty,
                  reviewedPaths.count <= HelperReviewedPathPolicy.maximumTargets
            else { return .invalidReviewedPaths }
        } else {
            // Paths on an operation that takes none means the caller and this
            // contract disagree about what is being asked for.
            guard reviewedPaths.isEmpty else { return .invalidReviewedPaths }
        }

        if operation.needsInterface {
            guard let name = networkInterface,
                  HelperRequest.isPlausibleInterfaceName(name),
                  liveInterfaces().contains(name) else { return .invalidInterface }
        } else {
            // An interface on an operation that takes none means the caller
            // and this contract disagree about what is being asked for.
            // Refuse rather than silently ignore it.
            guard networkInterface == nil else { return .invalidInterface }
        }
        return nil
    }

    /// BSD interface names are short, lowercase, and end in a unit number —
    /// `en0`, `utun3`, `bridge0`, `awdl0`. Anything else (a path, a flag, a
    /// space, a shell metacharacter) is refused outright rather than escaped:
    /// there is no legitimate interface name outside this shape, so rejecting
    /// costs nothing and removes the whole question.
    static func isPlausibleInterfaceName(_ name: String) -> Bool {
        guard (2...15).contains(name.count) else { return false }
        var sawDigit = false
        var letters = 0
        for scalar in name.unicodeScalars {
            if scalar >= "a" && scalar <= "z" {
                guard !sawDigit else { return false }   // letters must precede digits
                letters += 1
            } else if scalar >= "0" && scalar <= "9" {
                sawDigit = true
            } else {
                return false
            }
        }
        return letters >= 2 && sawDigit
    }
}

// MARK: - Response

/// What a privileged operation produced. The failure cases mirror the
/// osascript path's `ElevatedOutcome` so the GUI keeps ONE error taxonomy
/// across both elevation routes (the rule issue #48 established).
struct HelperResponse: Codable, Equatable, Sendable {
    enum Outcome: Codable, Equatable, Sendable {
        /// The engine ran and exited with this status.
        case exited(Int32)
        /// The user dismissed the authentication prompt.
        case authorizationCancelled
        /// Authentication was attempted and refused (wrong credentials, not an
        /// administrator, interaction unavailable).
        case authorizationDenied
        /// The request never reached authorization.
        case rejected(HelperRequestRejection)
        /// The signed, bundled engine could not be resolved or failed
        /// verification — so nothing was executed.
        case engineUnavailable

        /// Collapse to the `Int32` the existing call sites branch on. Every
        /// failure shape is nonzero: a dismissed prompt must never read as
        /// success.
        var exitCode: Int32 {
            switch self {
            case .exited(let code): return code
            case .authorizationCancelled, .authorizationDenied: return 1
            case .rejected: return 78          // EX_CONFIG: the request was refused, not run
            case .engineUnavailable: return 127
            }
        }

        // The bridge onto the GUI's existing `ElevatedOutcome` taxonomy lives
        // in PrivilegedHelperClient.swift — that type belongs to the app, and
        // this file also compiles into the daemon, which must stay free of
        // anything GUI-side.
    }

    let outcome: Outcome
}

// MARK: - Replay guard

/// Remembers which operation IDs have already been served, so one
/// authorization buys exactly one root operation.
///
/// Bounded on purpose: a daemon can stay resident for weeks, and an unbounded
/// set would grow with every request a client cared to send. Eviction is
/// oldest-first, which only ever forgets ancient IDs — the practical replay
/// window (seconds, between authenticating and executing) is always covered.
final class HelperReplayGuard: @unchecked Sendable {
    private let capacity: Int
    private var order: [String] = []
    private var seen: Set<String> = []
    private let lock = NSLock()

    init(capacity: Int = 512) {
        self.capacity = max(1, capacity)
    }

    /// Number of IDs currently remembered. Never exceeds `capacity`.
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return seen.count
    }

    /// `true` the first time an ID is presented, `false` for every repeat.
    func admit(_ operationID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !seen.contains(operationID) else { return false }
        seen.insert(operationID)
        order.append(operationID)
        while order.count > capacity {
            seen.remove(order.removeFirst())
        }
        return true
    }
}

// MARK: - Version skew

/// Whether the app and the installed helper are the same build.
enum HelperVersionSkew {
    enum Skew: Equatable, Sendable {
        case matched
        case mismatched
    }

    /// Exact equality, and an empty build on either side is a mismatch. There
    /// is no "close enough" here: the helper runs as root, and a version it
    /// can't name is a version nobody has reasoned about.
    static func evaluate(appBuild: String, helperBuild: String) -> Skew {
        guard !appBuild.isEmpty, !helperBuild.isEmpty, appBuild == helperBuild else { return .mismatched }
        return .matched
    }
}
