//
//  CleanPlanFileTests.swift
//  BurrowTests
//
//  The plan file `clean --apply --plan <file>` reads, as both the app and the helper write it.
//  Structural rules only — which paths may be deleted is the engine's rail and the daemon's
//  policy — but those rules are what keep a second line from being smuggled into a root run.
//

import XCTest
@testable import Burrow

final class CleanPlanFileTests: XCTestCase {

    func testRender_oneAbsolutePathPerLineUnderACommentHeader() throws {
        let body = try CleanPlanFile.render(paths: ["/Users/h/Library/Caches/a", "/Library/Caches/b c"])
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertTrue(lines[0].hasPrefix("#"), "the header is a comment the engine skips")
        XCTAssertEqual(Array(lines[1...]), ["/Users/h/Library/Caches/a", "/Library/Caches/b c", ""],
                       "one path per line, verbatim, trailing newline")
        XCTAssertTrue(body.hasSuffix("\n"))
    }

    func testRender_collapsesDuplicatesInOrder() throws {
        let body = try CleanPlanFile.render(paths: ["/a/x", "/a/y", "/a/x"])
        XCTAssertEqual(body.split(separator: "\n").dropFirst().map(String.init), ["/a/x", "/a/y"])
    }

    func testRender_refusesRelativeRootTraversalAndControlCharacters() {
        XCTAssertThrowsError(try CleanPlanFile.render(paths: ["Library/Caches/a"])) {
            XCTAssertEqual($0 as? CleanPlanFile.Rejection, .notAbsolute("Library/Caches/a"))
        }
        XCTAssertThrowsError(try CleanPlanFile.render(paths: ["/"])) {
            XCTAssertEqual($0 as? CleanPlanFile.Rejection, .notAbsolute("/"))
        }
        XCTAssertThrowsError(try CleanPlanFile.render(paths: ["/Users/h/Library/../Documents"])) {
            XCTAssertEqual($0 as? CleanPlanFile.Rejection, .traversal("/Users/h/Library/../Documents"))
        }
        XCTAssertThrowsError(try CleanPlanFile.render(paths: ["/Users/h/x/.."])) {
            XCTAssertEqual($0 as? CleanPlanFile.Rejection, .traversal("/Users/h/x/.."))
        }
        // A newline in a path is a second plan line — the one thing this format must never allow.
        XCTAssertThrowsError(try CleanPlanFile.render(paths: ["/Users/h/a\n/etc/passwd"])) {
            XCTAssertEqual($0 as? CleanPlanFile.Rejection, .controlCharacter("/Users/h/a\n/etc/passwd"))
        }
        XCTAssertThrowsError(try CleanPlanFile.render(paths: ["/Users/h/a\0"])) {
            XCTAssertEqual($0 as? CleanPlanFile.Rejection, .controlCharacter("/Users/h/a\0"))
        }
        XCTAssertThrowsError(try CleanPlanFile.render(paths: [])) {
            XCTAssertEqual($0 as? CleanPlanFile.Rejection, .empty)
        }
        // A path whose LAST component merely contains dots is fine: only a `..` component is traversal.
        XCTAssertNoThrow(try CleanPlanFile.render(paths: ["/Users/h/Library/Caches/..hidden", "/a/b...c"]))
    }

    func testRender_boundsTheCountToWhatTheHelperAccepts() {
        let many = (0..<(CleanPlanFile.maximumEntries + 1)).map { "/Users/h/Library/Caches/\($0)" }
        XCTAssertThrowsError(try CleanPlanFile.render(paths: many)) {
            XCTAssertEqual($0 as? CleanPlanFile.Rejection, .tooMany(CleanPlanFile.maximumEntries + 1))
        }
        XCTAssertEqual(CleanPlanFile.maximumEntries, HelperReviewedPathPolicy.maximumTargets,
                       "the writer refuses exactly what the daemon's policy would")
    }

    func testWrite_createsAnOwnerOnlyFileTheCallerCanDelete() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-plan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = try CleanPlanFile.write(paths: ["/Users/h/Library/Caches/a"], in: dir)
        XCTAssertEqual(file.pathExtension, "plan")
        XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL, dir.standardizedFileURL)
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attrs[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o600)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8),
                       try CleanPlanFile.render(paths: ["/Users/h/Library/Caches/a"]))
    }
}
