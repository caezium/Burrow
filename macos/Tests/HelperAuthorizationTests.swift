//
//  HelperAuthorizationTests.swift
//  BurrowTests
//
//  The authorization policy behind every root operation. The decision the
//  product made is narrow and unusually strict, so it is pinned here rather
//  than left to a comment:
//
//    every operation that actually runs as root requires a FRESH user
//    authentication — no grace period, no cached approval, no
//    "authenticate once for this launch", and registering the helper does
//    not itself authorize anything.
//
//  Two of those words are literally keys in the right's definition (`timeout`
//  and `shared`), so a regression that reintroduces a credential cache is a
//  one-line diff that these tests catch.
//
//  Nothing here prompts, authenticates, or touches the policy database: the
//  right definition is a dictionary and the OSStatus mapping is a pure
//  function, so both are checkable with no root and no UI.
//

import XCTest
import Security
@testable import Burrow

final class HelperAuthorizationTests: XCTestCase {

    // MARK: - The right's identity

    /// The right is namespaced under the app's bundle identifier so it can
    /// never collide with, or be satisfied by, a system right a user may have
    /// already been granted for something else.
    func testRightName_isNamespacedUnderTheBundleIdentifier() {
        XCTAssertTrue(HelperAuthorization.rightName.hasPrefix("dev.caezium.Burrow."),
                      "the right must live in Burrow's own namespace")
        XCTAssertFalse(HelperAuthorization.rightName.hasPrefix("system."),
                       "never reuse or shadow a system right")
    }

    // MARK: - No caching, ever (the decision, as policy keys)

    func testRightDefinition_expiresImmediatelySoEveryRunReauthenticates() {
        let definition = HelperAuthorization.rightDefinition
        XCTAssertEqual(definition["timeout"] as? Int, 0,
                       "timeout 0 = the credential is dead on arrival; the next root op prompts again")
    }

    func testRightDefinition_isNotSharedWithOtherProcessesOrRights() {
        let definition = HelperAuthorization.rightDefinition
        XCTAssertEqual(definition["shared"] as? Bool, false,
                       "a shared credential would let one prompt satisfy a later, different request")
    }

    /// The daemon runs as root. If the right allowed root callers to skip
    /// authentication, the daemon would authorize ITSELF and the prompt would
    /// silently disappear — the single most dangerous misconfiguration
    /// available here.
    func testRightDefinition_doesNotLetTheRootDaemonAuthorizeItself() {
        let definition = HelperAuthorization.rightDefinition
        XCTAssertEqual(definition["allow-root"] as? Bool, false,
                       "the root daemon must never satisfy this right by virtue of being root")
    }

    func testRightDefinition_requiresAnAdministratorToAuthenticate() {
        let definition = HelperAuthorization.rightDefinition
        XCTAssertEqual(definition["class"] as? String, "user")
        XCTAssertEqual(definition["group"] as? String, "admin")
        XCTAssertEqual(definition["authenticate-user"] as? Bool, true)
    }

    /// A human-readable reason ships with the right so the system prompt says
    /// what Burrow is about to do rather than showing a bare app name.
    func testRightDefinition_carriesAPromptDescription() {
        let definition = HelperAuthorization.rightDefinition
        let comment = definition["comment"] as? String ?? ""
        XCTAssertFalse(comment.isEmpty, "the right documents itself in the policy database")
    }

    // MARK: - Flags (the CopyRights call shape)
    //
    // Two documented ways to get this wrong, both of which turn the check into
    // a no-op:
    //   * omitting kAuthorizationFlagExtendRights — rights are never actually
    //     extended, and sloppy callers read the status as success;
    //   * passing kAuthorizationFlagPreAuthorize in the DAEMON — that only
    //     asks "could this be authorized later", which is not an authorization.

    func testDaemonFlags_extendRightsAndAllowInteraction() {
        let flags = HelperAuthorization.daemonFlags
        XCTAssertTrue(flags.contains(.extendRights), "without this no right is actually granted")
        XCTAssertTrue(flags.contains(.interactionAllowed), "the daemon raises the prompt itself")
    }

    func testDaemonFlags_neverPreAuthorizeOnly() {
        XCTAssertFalse(HelperAuthorization.daemonFlags.contains(.preAuthorize),
                       "pre-authorization asks whether auth is POSSIBLE; the daemon must require it")
    }

    /// The client does not authenticate — it only externalizes an empty
    /// authorization reference for the daemon to evaluate. If the client ever
    /// starts pre-authorizing, the prompt moves out of the privileged process
    /// and the daemon's own check becomes decorative.
    func testClientFlags_areInert() {
        XCTAssertEqual(HelperAuthorization.clientFlags, [],
                       "the GUI creates the reference; the root daemon is what demands the right")
    }

    // MARK: - OSStatus → outcome (pure, exhaustive)

    func testOutcome_successIsGranted() {
        XCTAssertEqual(HelperAuthorization.outcome(from: errAuthorizationSuccess), .granted)
    }

    func testOutcome_dismissedPromptIsCancelled() {
        XCTAssertEqual(HelperAuthorization.outcome(from: errAuthorizationCanceled), .cancelled)
    }

    func testOutcome_wrongPasswordOrRefusalIsDenied() {
        XCTAssertEqual(HelperAuthorization.outcome(from: errAuthorizationDenied), .denied)
        XCTAssertEqual(HelperAuthorization.outcome(from: OSStatus(errAuthorizationInteractionNotAllowed)), .denied)
    }

    /// Anything unrecognised fails CLOSED. A status this code has never seen
    /// must never fall through to "probably fine" — the operation is refused
    /// and the raw status is preserved for diagnosis.
    func testOutcome_unknownStatusFailsClosed() {
        XCTAssertEqual(HelperAuthorization.outcome(from: OSStatus(-60999)), .failed(-60999))
        XCTAssertNotEqual(HelperAuthorization.outcome(from: OSStatus(-60999)), .granted)
    }

    func testOutcome_onlyGrantedPermitsExecution() {
        // The single predicate the daemon branches on, so "granted" can't be
        // accidentally widened to "not an outright failure".
        XCTAssertTrue(HelperAuthorization.Outcome.granted.permitsExecution)
        for refused: HelperAuthorization.Outcome in [.denied, .cancelled, .failed(-1)] {
            XCTAssertFalse(refused.permitsExecution, "\(refused) must not run anything as root")
        }
    }

    // MARK: - External form sizing
    //
    // The external form is a fixed-size C struct. A payload of any other size
    // is malformed and is refused BEFORE it reaches
    // AuthorizationCreateFromExternalForm, so a hostile client cannot feed the
    // Security framework a short or oversized buffer.

    func testExternalForm_rejectsWrongSizedPayloads() {
        let correct = MemoryLayout<AuthorizationExternalForm>.size
        XCTAssertTrue(HelperAuthorization.isPlausibleExternalForm(Data(count: correct)))
        XCTAssertFalse(HelperAuthorization.isPlausibleExternalForm(Data()))
        XCTAssertFalse(HelperAuthorization.isPlausibleExternalForm(Data(count: correct - 1)))
        XCTAssertFalse(HelperAuthorization.isPlausibleExternalForm(Data(count: correct + 1)))
    }
}
