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
    /// The engine's maintenance pass.
    case optimize

    /// The exact argv the helper passes to the bundled engine. Fixed per case
    /// and assembled here rather than by the caller, so no client input ever
    /// reaches the child process's argument vector.
    ///
    /// These reproduce what the GUI runs today through osascript — CleanView's
    /// `["clean"]`, OptimizeView's `["optimize"]`, and the dry-run preview —
    /// so the helper changes HOW the command is elevated, never WHAT runs.
    var engineArguments: [String] {
        switch self {
        case .scan: return ["clean", "--dry-run"]
        case .clean: return ["clean"]
        case .optimize: return ["optimize"]
        }
    }

    /// Whether this operation mutates the disk. `scan` is read-only, but it
    /// still authenticates: it reads privileged locations, and the product
    /// decision was that anything running AS ROOT prompts.
    var mutatesDisk: Bool {
        switch self {
        case .scan: return false
        case .clean, .optimize: return true
        }
    }

    /// Recognise an existing elevated call site's argv as a typed operation,
    /// or `nil` if it isn't one of the three.
    ///
    /// This is the migration seam. The GUI still describes elevated work as
    /// `["clean"]` / `["optimize"]` through `OperationFlow`, and this maps
    /// those onto the helper WITHOUT letting anything else through: argv the
    /// helper doesn't recognise returns nil and keeps the existing osascript
    /// route, rather than being forwarded as some approximate operation.
    init?(engineArguments: [String]) {
        guard let match = HelperOperation.allCases.first(where: { $0.engineArguments == engineArguments })
        else { return nil }
        self = match
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
}

/// One privileged operation, fully described. Three fields, none of which can
/// carry a command.
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

    /// `nil` when the request is well formed. Runs on the PRIVILEGED side —
    /// the client's own validation is a courtesy, this one is the boundary.
    func validate(expectedBuild: String) -> HelperRequestRejection? {
        guard UUID(uuidString: operationID) != nil else { return .malformedOperationID }
        guard HelperVersionSkew.evaluate(appBuild: expectedBuild, helperBuild: clientBuild) == .matched else {
            return .buildMismatch
        }
        return nil
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
