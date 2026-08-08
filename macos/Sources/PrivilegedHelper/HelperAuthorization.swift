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
//  ── Where the prompt is raised, and why it moved ────────────────────────
//  This originally had the ROOT DAEMON raise the prompt, on the reasoning that
//  a GUI-side prompt is cosmetic: the daemon would be trusting an
//  unauthenticated message, and a caller that skipped the prompt would be
//  indistinguishable from one that passed it.
//
//  That reasoning is right about what must be VERIFIED, and wrong about where
//  the prompt can be RAISED. Measured behaviour: the daemon reached
//  AuthorizationCopyRights and every operation came back not-authorized. A
//  launchd system daemon has no session to draw an authentication UI in, so
//  asking it to raise one fails no matter how the right is defined.
//
//  So the flow is now Apple's documented split, which puts the prompt where a
//  session exists and the CHECK where the privilege is:
//
//    1. GUI  — AuthorizationCreate, then AuthorizationCopyRights for
//              `rightName` with interaction allowed. THIS raises the system
//              prompt, in the user's own session, where SecurityAgent can
//              offer Touch ID and fall back to the password.
//    2. GUI  — AuthorizationMakeExternalForm; the bytes ride with the request.
//    3. Root — AuthorizationCreateFromExternalForm, then
//              AuthorizationCopyRights WITHOUT interaction. This does not
//              prompt; it asks the Security framework whether this reference
//              genuinely holds the right.
//
//  Step 3 is what makes step 1 more than decoration. The daemon never trusts
//  the client's word: the credential lives in the security session, not in the
//  message, so a caller that skipped the prompt produces a reference that
//  fails step 3. Forging it means forging a Security-framework credential, not
//  editing an XPC payload.
//
//  ── The cost, stated plainly ────────────────────────────────────────────
//  The credential must survive the hop from step 1 to step 3, so `timeout`
//  cannot be 0. It is set to the smallest value that leaves room for the XPC
//  round trip. Within that window a SECOND operation could be authorized by
//  the first authentication.
//
//  What that does NOT open: `HelperReplayGuard` still serves each operation ID
//  once, so a captured payload cannot be resent, and `shared: false` keeps the
//  credential out of other processes. What it DOES open: an app that has
//  already authenticated could start another operation within the window
//  without a second prompt. That is a real relaxation of "a fresh
//  authentication for every root operation", and it is the price of the
//  prompt working at all.
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
    /// The window, in seconds, in which the credential from the GUI's
    /// authentication is still valid when the daemon checks it.
    ///
    /// This exists only to cover one XPC round trip. It is NOT a convenience
    /// grace period, and it is deliberately far too short to span a user
    /// deciding to run a second operation by hand — but see the header: within
    /// it, a programmatic second operation would not re-prompt.
    static let credentialWindowSeconds = 10

    static let rightDefinition: [String: Any] = [
        "class": "user",
        "group": "admin",
        "authenticate-user": true,
        // Just long enough for the authenticated reference to reach the daemon
        // and be checked. `timeout: 0` is the ideal and was tried first: it
        // kills the credential before it crosses XPC, so the daemon's check
        // always fails.
        "timeout": credentialWindowSeconds,
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
    /// `extendRights` is mandatory — without it the call reports whether the
    /// right COULD be granted and grants nothing, which a careless caller
    /// reads as success.
    ///
    /// `interactionAllowed` is deliberately ABSENT. The daemon must never
    /// prompt: it has no session to draw in (which is what broke the previous
    /// design), and more importantly a daemon that can prompt is a daemon that
    /// can be made to prompt by anything that reaches it. Without the flag
    /// this call is a pure question — does this reference hold the right —
    /// and an unauthenticated reference simply fails.
    static let daemonFlags: AuthorizationFlags = [.extendRights]

    /// The client's flags. This is where the human is asked.
    ///
    /// `interactionAllowed` raises the system prompt in the user's own
    /// session, so SecurityAgent can offer Touch ID and fall back to the
    /// password. `preAuthorize` is what makes the credential available to the
    /// daemon's later check rather than only to this process.
    static let clientFlags: AuthorizationFlags = [.extendRights, .interactionAllowed, .preAuthorize]

    // MARK: - Outcome

    /// Conforms to `Error` so the client can carry a refusal through a
    /// `Result` without inventing a parallel error type that would drift.
    enum Outcome: Equatable, Sendable, Error {
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

    /// What the GUI's authentication attempt produced, and — critically — the
    /// owner of the underlying `AuthorizationRef`.
    ///
    /// The externalized form is NOT a self-contained token. It is a handle to
    /// an authorization instance living in the Security Server, and that
    /// instance only exists while the creating process holds its
    /// `AuthorizationRef`. Free the ref and the daemon's
    /// `AuthorizationCreateFromExternalForm` fails with `errAuthorizationDenied`
    /// — which reads exactly like the user being refused, and sent this
    /// implementation chasing the wrong layer entirely.
    ///
    /// So this is a class, not a struct: it owns the ref and releases it in
    /// `deinit`. Callers must keep it alive across the whole round trip, which
    /// `PrivilegedHelperClient.run` does with `withExtendedLifetime`.
    final class ClientAuthorization {
        let externalForm: Data
        private let ref: AuthorizationRef

        init(ref: AuthorizationRef, externalForm: Data) {
            self.ref = ref
            self.externalForm = externalForm
        }

        deinit {
            // No `kAuthorizationFlagDestroyRights`: the credential's lifetime
            // is the right's `timeout`, not ours to cut short — and cutting it
            // short here is precisely the bug this type exists to prevent.
            AuthorizationFree(ref, [])
        }
    }

    /// GUI side. Ask the user to authenticate, then externalize the resulting
    /// reference so the daemon can verify it.
    ///
    /// THIS is the call that shows the prompt. It blocks until the user
    /// authenticates or dismisses, so it must not run on the main thread.
    ///
    /// Returns `nil` on cancellation or failure, and the caller must then
    /// abandon the operation — never fall through to sending an
    /// unauthenticated request, which the daemon would reject anyway but which
    /// would blur the distinction between "declined" and "broken".
    static func authenticate() -> Result<ClientAuthorization, Outcome> {
        var reference: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &reference) == errAuthorizationSuccess,
              let ref = reference else {
            return .failure(.failed(errAuthorizationInternal))
        }

        // Freed on every failure path, and ONLY on failure. On success the ref
        // is handed to ClientAuthorization, which must outlive the daemon's
        // internalization of the external form — see that type.
        func fail(_ outcome: Outcome) -> Result<ClientAuthorization, Outcome> {
            AuthorizationFree(ref, [])
            return .failure(outcome)
        }

        // Non-empty rights array. Passing NULL here is the documented way to
        // accidentally authorize everybody.
        let status: OSStatus = rightName.withCString { name -> OSStatus in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPointer -> OSStatus in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                return AuthorizationCopyRights(ref, &rights, nil, clientFlags, nil)
            }
        }
        let result = outcome(from: status)
        guard result.permitsExecution else { return fail(result) }

        var form = AuthorizationExternalForm()
        guard AuthorizationMakeExternalForm(ref, &form) == errAuthorizationSuccess else {
            return fail(.failed(errAuthorizationInternal))
        }
        return .success(ClientAuthorization(ref: ref,
                                            externalForm: withUnsafeBytes(of: &form) { Data($0) }))
    }

    /// Which step produced the result. Kept because "authorization failed" was
    /// indistinguishable across three very different causes — a malformed
    /// payload, a reference the Security framework wouldn't rebuild, and an
    /// actual refusal by the user — and only the last of those is normal.
    enum Stage: String, Sendable {
        case malformedExternalForm
        case createFromExternalForm
        case copyRights
    }

    struct Decision: Sendable {
        let outcome: Outcome
        let stage: Stage
        /// The raw `OSStatus`, preserved even when the outcome collapses
        /// several codes into `.denied`.
        let status: OSStatus

        var permitsExecution: Bool { outcome.permitsExecution }

        /// Safe to log: a stage name from a closed enum plus a numeric status.
        /// No paths, no credentials, no free-form error text.
        var diagnostic: String { "\(stage.rawValue) status=\(status) outcome=\(outcome)" }
    }

    /// Daemon side. Rebuild the client's reference and check that it genuinely
    /// holds `rightName`. Does NOT prompt — see `daemonFlags`. The returned
    /// decision is the gate: only `.granted` may be followed by privileged
    /// work.
    ///
    /// The rights array is always non-empty — passing NULL here is the
    /// documented way to accidentally authorize everybody.
    static func authorize(externalForm data: Data) -> Decision {
        guard isPlausibleExternalForm(data) else {
            return Decision(outcome: .denied, stage: .malformedExternalForm, status: errAuthorizationInvalidRef)
        }

        var form = AuthorizationExternalForm()
        let copied: Bool = withUnsafeMutableBytes(of: &form) { raw -> Bool in
            guard raw.count == data.count else { return false }
            _ = data.copyBytes(to: raw.bindMemory(to: UInt8.self))
            return true
        }
        guard copied else {
            return Decision(outcome: .denied, stage: .malformedExternalForm, status: errAuthorizationInvalidRef)
        }

        var ref: AuthorizationRef?
        let restored = AuthorizationCreateFromExternalForm(&form, &ref)
        guard restored == errAuthorizationSuccess, let ref else {
            return Decision(outcome: .denied, stage: .createFromExternalForm, status: restored)
        }
        defer { AuthorizationFree(ref, []) }

        return rightName.withCString { name -> Decision in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPointer -> Decision in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                let status = AuthorizationCopyRights(ref, &rights, nil, daemonFlags, nil)
                return Decision(outcome: outcome(from: status), stage: .copyRights, status: status)
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
