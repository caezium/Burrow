//
//  PhotosModelTests.swift
//  BurrowTests
//
//  The pure parser behind the Similar Photos pane: `burrow photos <dir>
//  --json` returns an envelope whose `data` is {dir, threshold,
//  similar_groups: [{paths: [String]}]} — each group serialized by
//  burrow-cli's photos::Group as an OBJECT with a `paths` key, not a bare
//  array. The GUI reads only that spine. Garbage or a non-object payload
//  parses to nil, never a crash.
//

import XCTest
@testable import Burrow

final class PhotosModelTests: XCTestCase {

    /// A canned photos report shaped like burrow-cli's `run_photos` output:
    /// two similar groups at the default hamming threshold.
    private let canned = """
    {
      "dir": "/Users/dev/Pictures/Screenshots",
      "threshold": 10,
      "similar_groups": [
        {"paths": ["/Users/dev/Pictures/Screenshots/a.png", "/Users/dev/Pictures/Screenshots/a copy.png"]},
        {"paths": ["/Users/dev/Pictures/Screenshots/b.jpg", "/Users/dev/Pictures/Screenshots/b2.jpg", "/Users/dev/Pictures/Screenshots/b3.jpg"]}
      ]
    }
    """.data(using: .utf8)!

    func testParse_readsGroupsAndSortsLargestFirst() throws {
        let report = try XCTUnwrap(PhotosReport.parse(canned))
        XCTAssertEqual(report.dir, "/Users/dev/Pictures/Screenshots")
        XCTAssertEqual(report.threshold, 10)
        XCTAssertEqual(report.groups.count, 2)
        // Largest group first — the set with the most near-copies leads.
        XCTAssertEqual(report.groups[0].paths.count, 3)
        XCTAssertEqual(report.groups[0].paths.first, "/Users/dev/Pictures/Screenshots/b.jpg")
        XCTAssertEqual(report.groups[1].paths,
                       ["/Users/dev/Pictures/Screenshots/a.png",
                        "/Users/dev/Pictures/Screenshots/a copy.png"])
    }

    func testParse_emptyGroupsIsAValidCleanReport() throws {
        let data = """
        {"dir": "/tmp/pics", "threshold": 10, "similar_groups": []}
        """.data(using: .utf8)!
        let report = try XCTUnwrap(PhotosReport.parse(data))
        XCTAssertTrue(report.groups.isEmpty)
        XCTAssertEqual(report.dir, "/tmp/pics")
    }

    func testParse_dropsMalformedGroupsKeepsGoodOnes() throws {
        // A group that isn't {paths: [...]} — or holds fewer than two paths
        // (not "similar" to anything) — is dropped; the rest still parses.
        let data = """
        {"dir": "/tmp", "threshold": 5, "similar_groups": [
          {"hash": 42},
          {"paths": []},
          {"paths": ["/tmp/only-one.png"]},
          {"paths": ["/tmp/x.png", "/tmp/y.png"]}
        ]}
        """.data(using: .utf8)!
        let report = try XCTUnwrap(PhotosReport.parse(data))
        XCTAssertEqual(report.groups.count, 1)
        XCTAssertEqual(report.groups[0].paths, ["/tmp/x.png", "/tmp/y.png"])
    }

    func testParse_missingDirAndThresholdDegradeGently() throws {
        // Loose everywhere except the spine: absent dir -> "", absent
        // threshold -> 0. Groups still land.
        let data = """
        {"similar_groups": [{"paths": ["/tmp/x.png", "/tmp/y.png"]}]}
        """.data(using: .utf8)!
        let report = try XCTUnwrap(PhotosReport.parse(data))
        XCTAssertEqual(report.dir, "")
        XCTAssertEqual(report.threshold, 0)
        XCTAssertEqual(report.groups.count, 1)
    }

    func testParse_garbageIsNilNotACrash() {
        XCTAssertNil(PhotosReport.parse(Data("not json".utf8)))
        XCTAssertNil(PhotosReport.parse(Data()))
        // Valid JSON but not an object — photos reports are objects.
        XCTAssertNil(PhotosReport.parse(Data(#"[["a.png","b.png"]]"#.utf8)))
    }

    func testGroup_identityIsTheFirstPath() {
        // Stable SwiftUI identity: the first member path is unique per group
        // (greedy clustering never puts one path in two groups).
        let g = PhotoGroup(paths: ["/tmp/x.png", "/tmp/y.png"])
        XCTAssertEqual(g.id, "/tmp/x.png")
    }
}
