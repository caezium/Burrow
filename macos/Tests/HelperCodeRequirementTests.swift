//
//  HelperCodeRequirementTests.swift
//  BurrowTests
//
//  Who is allowed to talk to the root daemon at all.
//
//  Authorization answers "may this operation run"; this answers the question
//  that comes first — "is the process on the other end of this XPC connection
//  actually Burrow". Without it, any local process could open the Mach service
//  and at minimum drive the auth prompt, phishing the user for admin
//  credentials with a dialog the system itself renders.
//
//  The requirement string is built at RUNTIME from the daemon's own signing
//  information, so nothing personal (a team ID, a certificate, a developer
//  name) is ever hardcoded in the repository. These tests cover the pure
//  string builder and the fail-closed rules around it; the SecCode calls
//  themselves are a thin system witness.
//

import XCTest
import Darwin
@testable import Burrow

final class HelperCodeRequirementTests: XCTestCase {

    // MARK: - Distribution builds: identity is pinned to the signing team

    /// A Developer ID build pins THREE things: the exact bundle identifier,
    /// an Apple-issued chain, and the signing team. Dropping any one of them
    /// widens the caller set — identifier alone can be claimed by any ad-hoc
    /// build, and anchor alone admits every Developer ID app on the machine.
    func testRequirement_pinsIdentifierAnchorAndTeam() {
        let requirement = HelperCodeRequirement.string(bundleID: "dev.caezium.Burrow", teamID: "ABCDE12345")

        XCTAssertTrue(requirement.contains(#"identifier "dev.caezium.Burrow""#))
        XCTAssertTrue(requirement.contains("anchor apple generic"),
                      "the chain must terminate at Apple, not at an arbitrary self-signed root")
        XCTAssertTrue(requirement.contains(#"certificate leaf[subject.OU] = "ABCDE12345""#),
                      "same-team pinning is what stops another Developer ID app impersonating Burrow")
    }

    func testRequirement_joinsEveryClauseWithAnd() {
        let requirement = HelperCodeRequirement.string(bundleID: "dev.caezium.Burrow", teamID: "ABCDE12345")
        // Three clauses, all mandatory — an `or` anywhere would make one optional.
        XCTAssertEqual(requirement.components(separatedBy: " and ").count, 3)
        XCTAssertFalse(requirement.contains(" or "), "no clause may be optional")
    }

    // MARK: - Unsigned / ad-hoc builds fail closed

    /// A local Debug build is ad-hoc signed and has no team. It still gets a
    /// requirement (identifier only) so development works, but it is explicitly
    /// NOT distribution grade — and the release gate refuses to ship a helper
    /// whose requirement can't name a team.
    func testRequirement_adHocBuildFallsBackToIdentifierOnly() {
        let requirement = HelperCodeRequirement.string(bundleID: "dev.caezium.Burrow", teamID: nil)
        XCTAssertEqual(requirement, #"identifier "dev.caezium.Burrow""#)
    }

    func testDistributionGrade_requiresATeam() {
        XCTAssertTrue(HelperCodeRequirement.isDistributionGrade(teamID: "ABCDE12345"))
        XCTAssertFalse(HelperCodeRequirement.isDistributionGrade(teamID: nil),
                       "an ad-hoc helper must never pass the release gate")
        XCTAssertFalse(HelperCodeRequirement.isDistributionGrade(teamID: ""))
        XCTAssertFalse(HelperCodeRequirement.isDistributionGrade(teamID: "   "))
    }

    // MARK: - Injection into the requirement language
    //
    // The requirement string is parsed by the Security framework as a small
    // language. Identifiers and team IDs are interpolated into it, so a value
    // carrying a quote could close the literal early and append a clause —
    // `identifier "x" or anchor apple` would admit every Apple-signed process
    // on the machine. Values that cannot ride inertly are REFUSED, not escaped:
    // a legitimate bundle ID or team ID never contains these characters, so
    // rejecting is strictly safer than sanitising.

    func testSanitisation_rejectsQuotesAndRequirementOperators() {
        for hostile in [#"dev.caezium.Burrow" or anchor apple generic and identifier "x"#,
                        #"dev.caezium.Burrow""#,
                        "dev.caezium.Burrow\\",
                        "dev.caezium.Burrow and anchor apple",
                        "dev.caezium.Burrow\nidentifier",
                        "dev.caezium.Burrow\u{0}"] {
            XCTAssertNil(HelperCodeRequirement.validated(identifier: hostile),
                         "hostile identifier must be refused: \(hostile.debugDescription)")
        }
    }

    func testSanitisation_acceptsRealisticIdentifiersAndTeams() {
        XCTAssertEqual(HelperCodeRequirement.validated(identifier: "dev.caezium.Burrow"), "dev.caezium.Burrow")
        XCTAssertEqual(HelperCodeRequirement.validated(identifier: "dev.caezium.Burrow.helper"),
                       "dev.caezium.Burrow.helper")
        XCTAssertEqual(HelperCodeRequirement.validated(identifier: "ABCDE12345"), "ABCDE12345")
        XCTAssertEqual(HelperCodeRequirement.validated(identifier: "A-B_C.D"), "A-B_C.D")
    }

    func testSanitisation_rejectsEmptyAndOverlongValues() {
        XCTAssertNil(HelperCodeRequirement.validated(identifier: ""))
        XCTAssertNil(HelperCodeRequirement.validated(identifier: " "))
        XCTAssertNil(HelperCodeRequirement.validated(identifier: String(repeating: "a", count: 300)))
    }

    /// A hostile value must take the whole requirement down with it, not
    /// silently produce a weaker one. `string(bundleID:teamID:)` returns the
    /// fail-closed sentinel that matches NOTHING when it can't build safely.
    func testRequirement_hostileInputProducesAnUnsatisfiableRequirement() {
        let requirement = HelperCodeRequirement.string(bundleID: #"x" or anchor apple generic"#,
                                                       teamID: "ABCDE12345")
        XCTAssertEqual(requirement, HelperCodeRequirement.unsatisfiable)
        XCTAssertFalse(requirement.contains("or anchor apple generic"))
    }

    func testRequirement_hostileTeamProducesAnUnsatisfiableRequirement() {
        let requirement = HelperCodeRequirement.string(bundleID: "dev.caezium.Burrow",
                                                       teamID: #"A" or anchor apple"#)
        XCTAssertEqual(requirement, HelperCodeRequirement.unsatisfiable)
    }

    /// The sentinel must be a syntactically valid requirement that no code can
    /// satisfy — an empty string would be a parse error, and some call sites
    /// treat a parse error as "no requirement", which is the opposite of what
    /// we want.
    func testUnsatisfiableSentinel_isValidSyntaxThatMatchesNothing() {
        XCTAssertFalse(HelperCodeRequirement.unsatisfiable.isEmpty)
        XCTAssertTrue(HelperCodeRequirement.unsatisfiable.contains("identifier"))
        XCTAssertNil(HelperCodeRequirement.validated(identifier: HelperCodeRequirement.unsatisfiable))
    }

    // MARK: - Exact executable snapshot

    func testExecutableSnapshotIsTheVerifiedCopyNotTheLaterSourcePath() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-helper-snapshot-\(UUID().uuidString)")
        let app = temp.appendingPathComponent("Source.app")
        let engineDirectory = app.appendingPathComponent("Contents/Resources/engine")
        let engine = engineDirectory.appendingPathComponent("mole")
        try FileManager.default.createDirectory(at: engineDirectory,
                                                withIntermediateDirectories: true)
        try writeInfoPlist(to: app, build: "24")
        try Data("#!/bin/sh\nprintf original\\n".utf8).write(to: engine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: engine.path)
        defer { try? FileManager.default.removeItem(at: temp) }

        var verifiedURL: URL?
        let snapshot = try HelperExecutableSnapshot.prepare(
            appBundleURL: app,
            parentDirectory: temp.resolvingSymlinksInPath(),
            expectedOwner: geteuid(),
            expectedBundleID: HelperNames.clientBundleID,
            expectedBuild: "24",
            verify: { copiedApp in
                verifiedURL = copiedApp
                return true
            })

        try FileManager.default.removeItem(at: engine)
        try Data("#!/bin/sh\nprintf replaced\\n".utf8).write(to: engine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: engine.path)

        XCTAssertEqual(verifiedURL, snapshot.appBundleURL)
        XCTAssertTrue(snapshot.executableURL.path.hasPrefix(snapshot.rootURL.path + "/"))
        XCTAssertTrue(try String(contentsOf: snapshot.executableURL).contains("original"),
                      "the exact verified copy must be what the helper later executes")
    }

    func testExecutableSnapshotRejectsASymlinkedEngine() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-helper-snapshot-link-\(UUID().uuidString)")
        let app = temp.appendingPathComponent("Source.app")
        let engineDirectory = app.appendingPathComponent("Contents/Resources/engine")
        let outside = temp.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: engineDirectory,
                                                withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: engineDirectory.appendingPathComponent("mole"), withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: temp) }

        XCTAssertThrowsError(try HelperExecutableSnapshot.prepare(
            appBundleURL: app,
            parentDirectory: temp.resolvingSymlinksInPath(),
            expectedOwner: geteuid(),
            expectedBundleID: HelperNames.clientBundleID,
            expectedBuild: "24",
            verify: { _ in true }))
    }

    func testExecutableSnapshotRejectsAnOlderSameTeamBundle() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-helper-snapshot-old-\(UUID().uuidString)")
        let app = temp.appendingPathComponent("Source.app")
        let engine = app.appendingPathComponent("Contents/Resources/engine/mole")
        try FileManager.default.createDirectory(at: engine.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try writeInfoPlist(to: app, build: "23")
        try Data("#!/bin/sh\n".utf8).write(to: engine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: engine.path)
        defer { try? FileManager.default.removeItem(at: temp) }

        var sameTeamSignatureAccepted = false
        XCTAssertThrowsError(try HelperExecutableSnapshot.prepare(
            appBundleURL: app,
            parentDirectory: temp.resolvingSymlinksInPath(),
            expectedOwner: geteuid(),
            expectedBundleID: HelperNames.clientBundleID,
            expectedBuild: "24",
            verify: { _ in
                sameTeamSignatureAccepted = true
                return true
            }))
        XCTAssertTrue(sameTeamSignatureAccepted,
                      "the regression must reach the same-team-pass/build-mismatch boundary")
    }

    private func writeInfoPlist(to app: URL, build: String) throws {
        let info: [String: Any] = [
            "CFBundleIdentifier": HelperNames.clientBundleID,
            "CFBundleVersion": build,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info,
                                                       format: .binary, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
    }

    // MARK: - Version skew between app and helper
    //
    // The installed helper outlives the app that installed it: Sparkle can
    // replace Burrow.app underneath a registered daemon. A helper from an
    // older build runs as root with an older idea of what `clean` does, so
    // skew is refused rather than tolerated.

    func testVersionSkew_matchingBuildsAreCompatible() {
        XCTAssertEqual(HelperVersionSkew.evaluate(appBuild: "23", helperBuild: "23"), .matched)
    }

    func testVersionSkew_anyDifferenceRequiresReregistration() {
        XCTAssertEqual(HelperVersionSkew.evaluate(appBuild: "24", helperBuild: "23"), .mismatched)
        XCTAssertEqual(HelperVersionSkew.evaluate(appBuild: "23", helperBuild: "24"), .mismatched)
    }

    func testVersionSkew_missingOrUnreadableBuildIsMismatched() {
        // A helper that won't say what it is gets no root work. Fail closed.
        XCTAssertEqual(HelperVersionSkew.evaluate(appBuild: "23", helperBuild: ""), .mismatched)
        XCTAssertEqual(HelperVersionSkew.evaluate(appBuild: "", helperBuild: "23"), .mismatched)
        XCTAssertEqual(HelperVersionSkew.evaluate(appBuild: "", helperBuild: ""), .mismatched)
    }
}
