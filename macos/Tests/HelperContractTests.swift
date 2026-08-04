//
//  HelperContractTests.swift
//  BurrowTests
//
//  The typed-request boundary of the privileged helper. Everything asserted
//  here runs in memory: no daemon, no XPC, no root, no auth prompt.
//
//  The whole security argument for the helper rests on ONE claim — a client
//  cannot describe an arbitrary command, only pick from a closed set of
//  Burrow operations. These tests are what make that claim checkable:
//
//    * the operation set is closed and each member maps to a FIXED argv the
//      client never contributes a single token to;
//    * a request that fails validation produces a named rejection, never a
//      "best effort" run;
//    * an operation ID cannot be replayed.
//
//  If someone later widens the contract to carry a path, an argv element, or
//  a command string, the argv tests below stop compiling or fail. That is the
//  point.
//

import XCTest
@testable import Burrow

final class HelperContractTests: XCTestCase {

    // MARK: - The closed operation set
    //
    // The approved scope is exactly: privileged scan, clean, optimize. Not
    // "run this binary", not "run this shell string", not "run mo with these
    // args". A new case here is a deliberate security decision, so the count
    // is pinned — adding one without updating this test is a failing build.

    func testOperationSet_isExactlyScanCleanOptimize() {
        XCTAssertEqual(Set(HelperOperation.allCases.map(\.rawValue)),
                       ["scan", "clean", "optimize"],
                       "the helper's operation set is closed; widening it is a security decision")
    }

    // MARK: - Fixed argv (the client contributes nothing)
    //
    // These are the exact argv the GUI passes today through the osascript
    // path (CleanView `["clean"]`, OptimizeView `["optimize"]`, previews with
    // `--dry-run`). The helper reproduces them from the enum ALONE, so an
    // attacker who fully controls the XPC payload still cannot add a flag.

    func testEngineArguments_areFixedPerOperation() {
        XCTAssertEqual(HelperOperation.scan.engineArguments, ["clean", "--dry-run"])
        XCTAssertEqual(HelperOperation.clean.engineArguments, ["clean"])
        XCTAssertEqual(HelperOperation.optimize.engineArguments, ["optimize"])
    }

    func testEngineArguments_neverEmptyAndNeverShellMetacharacters() {
        // argv goes to posix_spawn, never a shell — but a stray metacharacter
        // would still signal that someone started templating strings in here.
        for op in HelperOperation.allCases {
            XCTAssertFalse(op.engineArguments.isEmpty, "\(op) must resolve to a real command")
            for token in op.engineArguments {
                XCTAssertFalse(token.contains(where: { ";|&`$<>\n\0".contains($0) }),
                               "\(op) argv token \(token) carries shell/NUL metacharacters")
            }
        }
    }

    /// Decoding is the ONLY way a request enters the daemon, and the operation
    /// is an enum — an unknown verb fails to decode rather than falling through
    /// to some default. This is the test that keeps "run" from ever being a
    /// smuggled operation.
    func testDecoding_rejectsUnknownOperation() throws {
        let payload = #"{"operation":"run","operationID":"\#(UUID().uuidString)","clientBuild":"23"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(HelperRequest.self, from: Data(payload.utf8)))
    }

    func testDecoding_roundTripsEveryOperation() throws {
        for op in HelperOperation.allCases {
            let request = HelperRequest(operation: op, operationID: UUID().uuidString, clientBuild: "23")
            let data = try JSONEncoder().encode(request)
            XCTAssertEqual(try JSONDecoder().decode(HelperRequest.self, from: data), request)
        }
    }

    // MARK: - Validation (named rejections, never a partial run)

    func testValidate_acceptsAWellFormedRequest() {
        let request = HelperRequest(operation: .clean, operationID: UUID().uuidString, clientBuild: "23")
        XCTAssertNil(request.validate(expectedBuild: "23"))
    }

    /// A non-UUID operation ID is rejected outright. The ID is the replay key,
    /// so a client-chosen constant ("1") would let a single authorization be
    /// reused; requiring a UUID makes every request distinguishable.
    func testValidate_rejectsNonUUIDOperationID() {
        for bad in ["", "1", "not-a-uuid", String(repeating: "a", count: 400)] {
            let request = HelperRequest(operation: .clean, operationID: bad, clientBuild: "23")
            XCTAssertEqual(request.validate(expectedBuild: "23"), .malformedOperationID,
                           "operation ID \(bad.prefix(12)) must be rejected")
        }
    }

    /// Version skew is a rejection, not a "try anyway". A stale helper paired
    /// with a new app could hold an older idea of what `clean` does, and it
    /// runs as root — so the mismatch stops the operation and the GUI
    /// re-registers instead.
    func testValidate_rejectsBuildMismatch() {
        let request = HelperRequest(operation: .clean, operationID: UUID().uuidString, clientBuild: "22")
        XCTAssertEqual(request.validate(expectedBuild: "23"), .buildMismatch)
    }

    func testValidate_rejectsEmptyBuild() {
        let request = HelperRequest(operation: .clean, operationID: UUID().uuidString, clientBuild: "")
        XCTAssertEqual(request.validate(expectedBuild: "23"), .buildMismatch)
    }

    // MARK: - Replay resistance
    //
    // One authorization authorizes ONE operation. The daemon remembers the IDs
    // it has already served so a captured payload (auth external form included)
    // cannot be re-sent to get a second root run out of one prompt.

    func testReplayGuard_admitsEachIDOnce() {
        let guardian = HelperReplayGuard()
        let id = UUID().uuidString
        XCTAssertTrue(guardian.admit(id), "first use of an ID is allowed")
        XCTAssertFalse(guardian.admit(id), "the same ID must never be served twice")
        XCTAssertFalse(guardian.admit(id))
    }

    func testReplayGuard_distinctIDsAllPass() {
        let guardian = HelperReplayGuard()
        for _ in 0..<50 {
            XCTAssertTrue(guardian.admit(UUID().uuidString))
        }
    }

    /// The guard is bounded so a long-lived daemon can't be grown without
    /// limit by a client that just keeps sending fresh IDs. Eviction is
    /// oldest-first, and the CURRENT id is always remembered — so the replay
    /// window can only ever shrink for ancient ids, never for a live one.
    func testReplayGuard_isBoundedAndEvictsOldestFirst() {
        let guardian = HelperReplayGuard(capacity: 3)
        let ids = (0..<4).map { _ in UUID().uuidString }
        for id in ids { XCTAssertTrue(guardian.admit(id)) }

        XCTAssertTrue(guardian.admit(ids[0]), "the oldest ID was evicted once capacity was exceeded")
        XCTAssertFalse(guardian.admit(ids[3]), "the newest ID is still remembered")
        XCTAssertEqual(guardian.count, 3, "the guard never grows past its capacity")
    }

    // MARK: - Response encoding
    //
    // The reply crosses XPC as bytes, so it round-trips like the request. The
    // failure cases are NAMED (matching the existing ElevatedOutcome taxonomy)
    // so the GUI shows the right message instead of re-deriving meaning from a
    // bare nonzero exit — the same rule issue #48 established for osascript.

    func testResponse_roundTripsEveryOutcome() throws {
        let outcomes: [HelperResponse.Outcome] = [
            .exited(0), .exited(2),
            .authorizationCancelled,
            .authorizationDenied,
            .rejected(.buildMismatch),
            .rejected(.replayedOperationID),
            .engineUnavailable,
        ]
        for outcome in outcomes {
            let data = try JSONEncoder().encode(HelperResponse(outcome: outcome))
            XCTAssertEqual(try JSONDecoder().decode(HelperResponse.self, from: data).outcome, outcome)
        }
    }

    /// The GUI still has call sites that branch on an Int32. Every failure
    /// shape must collapse to a NONZERO code, exactly as `ElevatedOutcome`
    /// does today — a cancelled prompt must never read as success.
    func testResponse_everyFailureIsNonzeroToLegacyCallers() {
        XCTAssertEqual(HelperResponse.Outcome.exited(0).exitCode, 0)
        XCTAssertEqual(HelperResponse.Outcome.exited(3).exitCode, 3)
        for failure: HelperResponse.Outcome in [.authorizationCancelled, .authorizationDenied,
                                                .rejected(.malformedPayload), .engineUnavailable] {
            XCTAssertNotEqual(failure.exitCode, 0, "\(failure) must not read as success")
        }
    }

    /// A cancelled authorization maps onto the SAME user-facing meaning as the
    /// osascript path's `.authCancelled`, so both elevation routes tell the
    /// user the same thing and the GUI needs no second taxonomy.
    func testResponse_mapsOntoTheExistingElevatedOutcomeTaxonomy() {
        XCTAssertEqual(HelperResponse.Outcome.exited(0).elevatedOutcome, .exited(0))
        XCTAssertEqual(HelperResponse.Outcome.exited(7).elevatedOutcome, .exited(7))
        XCTAssertEqual(HelperResponse.Outcome.authorizationCancelled.elevatedOutcome, .authCancelled)
        XCTAssertEqual(HelperResponse.Outcome.engineUnavailable.elevatedOutcome, .launchFailed)
        XCTAssertEqual(HelperResponse.Outcome.authorizationDenied.elevatedOutcome, .authCancelled)
    }
}
