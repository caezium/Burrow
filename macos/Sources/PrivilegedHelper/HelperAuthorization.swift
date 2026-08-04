//
//  HelperAuthorization.swift
//  Burrow / BurrowHelper (shared)
//
//  The authorization policy for every root operation, in one place.
//
//  ── The product decision this file encodes ──────────────────────────────
//  Every operation that actually runs as root requires a FRESH user
//  authentication. No grace period, no cached credential, no "authenticate
//  once for this launch". Installing the helper is a separate, one-time
//  macOS approval and does NOT authorize any later operation.
//
//  Two words of that are literally keys in the right's definition:
//    timeout: 0     the credential expires immediately, so the next
//                   privileged request authenticates again from scratch
//    shared: false  the credential is never visible to another process or
//                   satisfiable by a different right
//
//  ── Where the prompt is raised, and why it matters ──────────────────────
//  The obvious design — prompt with LAContext in the GUI, then send the XPC
//  request — is not an authorization at all. The daemon would be trusting an
//  unauthenticated message from a process it cannot vouch for; a caller that
//  skipped the prompt entirely would be indistinguishable from one that
//  passed it. Whatever the GUI shows is cosmetic unless the ROOT side is what
//  demands the right.
//
//  So the flow is the documented Authorization Services one, with the
//  authenticating call deliberately on the privileged side:
//
//    1. GUI  — AuthorizationCreate (empty environment, NO flags). This makes
//              an empty reference bound to the user's session. It does not
//              authenticate and shows no UI.
//    2. GUI  — AuthorizationMakeExternalForm, and the bytes ride with the
//              request over XPC.
//    3. Root — AuthorizationCreateFromExternalForm, then AuthorizationCopyRights
//              for `rightName` with interaction allowed. THIS raises the
//              system prompt, and its result is what gates execution.
//
//  Because the reference carries the client's session, the prompt appears in
//  that session and is attributed to Burrow rather than to a faceless root
//  process. Because the right is defined with timeout 0 / shared false, step 3
//  authenticates every single time.
//
//  The authentication UI is the system's, so it offers Touch ID where the
//  hardware has it and falls back to the Mac login password otherwise. Burrow
//  receives a granted/denied/cancelled result and never sees, handles, or
//  stores a credential.
//
//  ── The two classic ways to make this a no-op ───────────────────────────
//  Both are real, both are one line, both are covered by tests:
//    * calling AuthorizationCopyRights with a NULL rights set — it returns
//      success regardless of who is calling;
//    * passing kAuthorizationFlagPreAuthorize on the daemon side — that asks
//      whether authorization would be POSSIBLE later, which is not the same
//      as requiring it now.
//

import Foundation
import Security

enum HelperAuthorization {

    // MARK: - The right

    /// Namespaced under the app's bundle identifier so it can never collide
    /// with, or be satisfied by, a system right the user may already hold for
    /// something else.
    static let rightName = "dev.caezium.Burrow.privileged-operation"

    /// The right's definition in the system authorization policy database.
    ///
    /// `allow-root: false` is the entry that matters most and is the easiest
    /// to get wrong. The daemon evaluating this right IS root; if root callers
    /// were allowed to satisfy it implicitly, the daemon would authorize
    /// itself and the prompt would quietly stop appearing.
    static let rightDefinition: [String: Any] = [
        "class": "user",
        "group": "admin",
        "authenticate-user": true,
        // No credential survives the call, and none is shared with anything
        // else. Together these are "a fresh authentication every time".
        "timeout": 0,
        "shared": false,
        // Root is not a shortcut past the prompt.
        "allow-root": false,
        // Not the console user's session by default — an administrator has to
        // authenticate explicitly.
        "session-owner": false,
        "comment": "Burrow is about to run a privileged maintenance operation (scan, clean, or optimize) as root.",
    ]

    // MARK: - Flags

    /// The daemon's `AuthorizationCopyRights` flags.
    ///
    /// `extendRights` is what actually grants the right — without it the call
    /// reports whether the right COULD be granted and grants nothing, which a
    /// careless caller reads as success. `interactionAllowed` lets the system
    /// raise the prompt, which is the entire point of doing this on the
    /// privileged side.
    static let daemonFlags: AuthorizationFlags = [.extendRights, .interactionAllowed]

    /// The client's flags: none. The GUI externalizes an empty reference and
    /// leaves authentication to root. If the client ever starts
    /// pre-authorizing, the prompt migrates out of the privileged process and
    /// the daemon's own check degrades into decoration.
    static let clientFlags: AuthorizationFlags = []

    // MARK: - Outcome

    enum Outcome: Equatable, Sendable {
        case granted
        case denied
        case cancelled
        case failed(OSStatus)

        /// The ONE predicate the daemon branches on. Kept as a single property
        /// so "granted" can never drift into "not an outright failure".
        var permitsExecution: Bool { self == .granted }
    }

    /// Classify the `OSStatus` from `AuthorizationCopyRights`. Pure, so it is
    /// exhaustively table-tested. Anything unrecognised fails CLOSED, carrying
    /// the raw status for diagnosis rather than guessing.
    static func outcome(from status: OSStatus) -> Outcome {
        switch status {
        case errAuthorizationSuccess:
            return .granted
        case errAuthorizationCanceled:
            return .cancelled
        case errAuthorizationDenied, OSStatus(errAuthorizationInteractionNotAllowed):
            return .denied
        default:
            return .failed(status)
        }
    }

    // MARK: - External form

    /// `AuthorizationExternalForm` is a fixed-size C struct. Anything of a
    /// different length is malformed and is refused HERE, before the bytes are
    /// handed to the Security framework — a hostile client should not get to
    /// choose the length of a buffer that lands in a C API.
    static func isPlausibleExternalForm(_ data: Data) -> Bool {
        data.count == MemoryLayout<AuthorizationExternalForm>.size
    }

    // MARK: - System witnesses
    //
    // Thin wrappers over the Security framework: the decisions above are pure
    // and tested, these just perform the calls.

    /// GUI side. Create an empty authorization reference and externalize it.
    /// Shows no UI and authenticates nothing — the daemon does that.
    /// Returns `nil` if a reference can't be made, in which case the caller
    /// must abandon the operation rather than proceed unauthorized.
    static func makeExternalForm() -> Data? {
        var ref: AuthorizationRef?
        let created = AuthorizationCreate(nil, nil, clientFlags, &ref)
        guard created == errAuthorizationSuccess, let ref else { return nil }
        defer { AuthorizationFree(ref, []) }

        var form = AuthorizationExternalForm()
        guard AuthorizationMakeExternalForm(ref, &form) == errAuthorizationSuccess else { return nil }
        return withUnsafeBytes(of: &form) { Data($0) }
    }

    /// Daemon side. Rebuild the client's reference and REQUIRE `rightName`,
    /// raising the system prompt. The returned outcome is the gate: only
    /// `.granted` may be followed by privileged work.
    ///
    /// The rights array is always non-empty — passing NULL here is the
    /// documented way to accidentally authorize everybody.
    static func authorize(externalForm data: Data) -> Outcome {
        guard isPlausibleExternalForm(data) else { return .denied }

        var form = AuthorizationExternalForm()
        let copied: Bool = withUnsafeMutableBytes(of: &form) { raw -> Bool in
            guard raw.count == data.count else { return false }
            _ = data.copyBytes(to: raw.bindMemory(to: UInt8.self))
            return true
        }
        guard copied else { return .denied }

        var ref: AuthorizationRef?
        let restored = AuthorizationCreateFromExternalForm(&form, &ref)
        guard restored == errAuthorizationSuccess, let ref else { return .denied }
        defer { AuthorizationFree(ref, []) }

        return rightName.withCString { name -> Outcome in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPointer -> Outcome in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                let status = AuthorizationCopyRights(ref, &rights, nil, daemonFlags, nil)
                return outcome(from: status)
            }
        }
    }

    /// Daemon side, once at startup. Publish the right's definition so the
    /// system prompts with Burrow's own wording and policy instead of falling
    /// back to a generic default for an unknown right.
    ///
    /// Rewritten every launch on purpose: the daemon's compiled-in definition
    /// is the source of truth, so a stale or tampered policy entry from an
    /// earlier install cannot weaken a newer helper.
    @discardableResult
    static func installRightDefinition() -> Bool {
        var authRef: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authRef) == errAuthorizationSuccess,
              let authRef else { return false }
        defer { AuthorizationFree(authRef, []) }

        let comment = (rightDefinition["comment"] as? String).map { $0 as CFString }
        let status = AuthorizationRightSet(authRef, rightName,
                                           rightDefinition as CFDictionary,
                                           comment, nil, nil)
        return status == errAuthorizationSuccess
    }
}
