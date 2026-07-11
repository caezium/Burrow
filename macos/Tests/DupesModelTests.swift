//
//  DupesModelTests.swift
//  BurrowTests
//
//  The pure fclones-report parser behind the Duplicates pane (Phase 6.2):
//  `burrow dupes <dir> --json` returns an envelope whose `data` is fclones'
//  group report. The GUI only reads the spine — `header.stats.
//  redundant_file_size`, `groups[].file_len`, `groups[].files[]` — and must
//  keep byte counts integer-exact (JSONSerialization, not a Codable Double
//  bridge). Garbage or a non-object payload parses to nil, never a crash.
//

import XCTest
@testable import Burrow

final class DupesModelTests: XCTestCase {

    /// A canned fclones group report, shaped like burrow-cli's testdata:
    /// two groups, header stats carrying the redundant byte total.
    private let canned = """
    {
      "header": {
        "version": "0.34.0",
        "timestamp": "2026-07-11T10:00:00.000000000+00:00",
        "command": ["fclones", "group", "."],
        "base_dir": "/Users/dev/Downloads",
        "stats": {
          "group_count": 2,
          "total_file_count": 5,
          "total_file_size": 7168,
          "redundant_file_count": 3,
          "redundant_file_size": 5120
        }
      },
      "groups": [
        {
          "file_len": 1024,
          "file_hash": "aabbccdd",
          "files": ["/Users/dev/Downloads/a.zip", "/Users/dev/Downloads/copy of a.zip"]
        },
        {
          "file_len": 2048,
          "file_hash": "eeff0011",
          "files": ["/Users/dev/Downloads/b.dmg", "/Users/dev/Downloads/b (1).dmg", "/Users/dev/Downloads/b (2).dmg"]
        }
      ]
    }
    """.data(using: .utf8)!

    func testParse_readsGroupsAndStats() throws {
        let report = try XCTUnwrap(DupesReport.parse(canned))
        XCTAssertEqual(report.groups.count, 2)
        XCTAssertEqual(report.redundantBytes, 5120)

        // Groups come back largest-reclaim first: the 3-copy 2048 B group
        // wastes 4096 B, ahead of the 2-copy 1024 B group's 1024 B.
        XCTAssertEqual(report.groups[0].fileLen, 2048)
        XCTAssertEqual(report.groups[0].files.count, 3)
        XCTAssertEqual(report.groups[0].files.first, "/Users/dev/Downloads/b.dmg")
        XCTAssertEqual(report.groups[0].redundantBytes, 4096)
        XCTAssertEqual(report.groups[1].fileLen, 1024)
        XCTAssertEqual(report.groups[1].files,
                       ["/Users/dev/Downloads/a.zip", "/Users/dev/Downloads/copy of a.zip"])
        XCTAssertEqual(report.groups[1].redundantBytes, 1024)
    }

    func testParse_emptyGroupsIsAValidCleanReport() throws {
        let data = """
        {"header": {"stats": {"group_count": 0, "redundant_file_size": 0}}, "groups": []}
        """.data(using: .utf8)!
        let report = try XCTUnwrap(DupesReport.parse(data))
        XCTAssertTrue(report.groups.isEmpty)
        XCTAssertEqual(report.redundantBytes, 0)
    }

    func testParse_missingHeaderStatsFallsBackToComputedTotal() throws {
        // A stats-less report (or a drifted header) still yields an honest
        // total: sum of (copies − 1) × file_len over the groups.
        let data = """
        {"groups": [
          {"file_len": 100, "files": ["/tmp/x", "/tmp/y", "/tmp/z"]},
          {"file_len": 7,   "files": ["/tmp/p", "/tmp/q"]}
        ]}
        """.data(using: .utf8)!
        let report = try XCTUnwrap(DupesReport.parse(data))
        XCTAssertEqual(report.groups.count, 2)
        XCTAssertEqual(report.redundantBytes, 207)   // 2×100 + 1×7
    }

    func testParse_garbageIsNilNotACrash() {
        XCTAssertNil(DupesReport.parse(Data("not json".utf8)))
        XCTAssertNil(DupesReport.parse(Data()))
        // Valid JSON but not an object — fclones reports are objects.
        XCTAssertNil(DupesReport.parse(Data("[1, 2, 3]".utf8)))
    }

    func testParse_skipsMalformedGroupsKeepsGoodOnes() throws {
        // A group missing its spine (no files / no file_len) is dropped;
        // the rest of the report still parses.
        let data = """
        {"header": {"stats": {"redundant_file_size": 50}},
         "groups": [
           {"file_hash": "deadbeef"},
           {"file_len": 50, "files": ["/tmp/a", "/tmp/b"]}
         ]}
        """.data(using: .utf8)!
        let report = try XCTUnwrap(DupesReport.parse(data))
        XCTAssertEqual(report.groups.count, 1)
        XCTAssertEqual(report.groups[0].fileLen, 50)
    }

    // MARK: DupesSelection (the checklist — keep-one invariant)

    private var twoGroups: DupesReport {
        DupesReport(
            groups: [
                DupeGroup(fileLen: 100, files: ["/a/1", "/a/2", "/a/3"]),
                DupeGroup(fileLen: 50, files: ["/b/1", "/b/2"]),
            ],
            redundantBytes: 250)
    }

    func testSelection_defaultsToAllButFirstPerGroup() {
        let sel = DupesSelection(report: twoGroups)
        XCTAssertFalse(sel.isTicked("/a/1"), "each group's first copy starts kept")
        XCTAssertTrue(sel.isTicked("/a/2"))
        XCTAssertTrue(sel.isTicked("/a/3"))
        XCTAssertFalse(sel.isTicked("/b/1"))
        XCTAssertTrue(sel.isTicked("/b/2"))
        XCTAssertEqual(sel.selectedBytes(in: twoGroups), 250, "matches the report's redundant total")
    }

    func testSelection_keepOneGuardRefusesFullGroup() {
        var sel = DupesSelection(report: twoGroups)
        // /a/1 is the last unticked copy of group a — ticking it must be a no-op.
        sel.toggle("/a/1", in: twoGroups)
        XCTAssertFalse(sel.isTicked("/a/1"), "the guard must refuse selecting every copy")
        XCTAssertTrue(sel.isKeptCopy("/a/1", in: twoGroups.groups[0]))
        // Free a slot, then the first copy becomes selectable (the KEPT one moves).
        sel.toggle("/a/2", in: twoGroups)
        sel.toggle("/a/1", in: twoGroups)
        XCTAssertTrue(sel.isTicked("/a/1"), "keep-one is per-group, not first-copy-sacred")
        XCTAssertFalse(sel.isTicked("/a/2"))
    }

    func testSelection_groupTriStateAndToggle() {
        var sel = DupesSelection(report: twoGroups)
        let a = twoGroups.groups[0]
        XCTAssertEqual(sel.groupState(a), .all, "default = at selectable max")
        sel.toggleGroup(a)
        XCTAssertEqual(sel.groupState(a), .none)
        XCTAssertEqual(sel.selectedBytes(in: twoGroups), 50, "only group b remains")
        sel.toggle("/a/3", in: twoGroups)
        XCTAssertEqual(sel.groupState(a), .mixed)
        sel.toggleGroup(a)
        XCTAssertEqual(sel.groupState(a), .all, "mixed -> back to all-but-first")
        XCTAssertFalse(sel.isTicked("/a/1"))
    }

    func testSelection_selectedPathsFollowGroupOrder() {
        let sel = DupesSelection(report: twoGroups)
        XCTAssertEqual(sel.selectedPaths(in: twoGroups), ["/a/2", "/a/3", "/b/2"])
    }

    // MARK: DedupePreview (the act-from-GUI flow)

    func testDedupePreview_parsesPlanLines() throws {
        // `burrow dupes dedupe <dir>` (no --apply) returns fclones' own dry-run — the
        // exact commands --apply would execute. The confirm dialog shows these.
        let data = """
        {"preview": true, "action": "dedupe", "groups": 2,
         "plan": ["cp -c /tmp/a /tmp/b", "cp -c /tmp/c /tmp/d"]}
        """.data(using: .utf8)!
        let preview = try XCTUnwrap(DedupePreview.parse(data))
        XCTAssertFalse(preview.skipped)
        XCTAssertEqual(preview.groups, 2)
        XCTAssertEqual(preview.plan, ["cp -c /tmp/a /tmp/b", "cp -c /tmp/c /tmp/d"])
    }

    func testDedupePreview_parsesSkip() throws {
        let data = """
        {"skipped": true, "groups": 0, "reason": "no actionable duplicate groups"}
        """.data(using: .utf8)!
        let preview = try XCTUnwrap(DedupePreview.parse(data))
        XCTAssertTrue(preview.skipped)
        XCTAssertEqual(preview.groups, 0)
        XCTAssertTrue(preview.plan.isEmpty)
    }

    func testDedupePreview_garbageAndWrongShapesAreNil() {
        XCTAssertNil(DedupePreview.parse(Data("not json".utf8)))
        // A group REPORT (scan output) is not a preview — must not be mistaken for one.
        XCTAssertNil(DedupePreview.parse(Data(#"{"groups":[{"file_len":1}]}"#.utf8)))
    }

    func testParse_keepsInt64PrecisionAboveInt32() throws {
        // 5 GB-scale byte counts must survive exactly — the reason the
        // parser is JSONSerialization, matching DiskScanner.parse.
        let data = """
        {"header": {"stats": {"redundant_file_size": 5000000123}},
         "groups": [{"file_len": 5000000123, "files": ["/tmp/big1", "/tmp/big2"]}]}
        """.data(using: .utf8)!
        let report = try XCTUnwrap(DupesReport.parse(data))
        XCTAssertEqual(report.redundantBytes, 5_000_000_123)
        XCTAssertEqual(report.groups[0].fileLen, 5_000_000_123)
        XCTAssertEqual(report.groups[0].redundantBytes, 5_000_000_123)
    }
}
