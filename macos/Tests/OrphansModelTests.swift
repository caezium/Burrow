//
//  OrphansModelTests.swift
//  BurrowTests
//
//  The pure parser behind the Leftovers pane: `burrow orphans <dir> --json`
//  returns an envelope whose `data` carries the scan — `roots`,
//  `installed_count`, `count`, and `orphans[]` rows shaped
//  {name, path, confidence, evidence[], default_selected}. The GUI reads only
//  that spine; extra fields (e.g. `inventory_sources`) may drift upstream
//  without breaking us. Garbage or a non-object payload parses to nil,
//  never a crash.
//

import XCTest
@testable import Burrow

final class OrphansModelTests: XCTestCase {

    /// A canned orphans report, shaped like burrow-cli's `run_orphans` output:
    /// two hits (one medium, one weak), a root, and the inventory count.
    private let canned = """
    {
      "roots": ["/Users/dev/Library/Caches"],
      "installed_count": 42,
      "inventory_sources": {"applications_dir": 42},
      "count": 2,
      "orphans": [
        {
          "name": "OldAppLeftovers",
          "path": "/Users/dev/Library/Caches/OldAppLeftovers",
          "confidence": "weak",
          "evidence": ["app-artifact-shaped", "not-matched-to-installed-inventory"],
          "default_selected": false
        },
        {
          "name": "com.deadvendor.oldapp",
          "path": "/Users/dev/Library/Caches/com.deadvendor.oldapp",
          "confidence": "medium",
          "evidence": ["app-artifact-shaped", "not-matched-to-installed-inventory"],
          "default_selected": false
        }
      ]
    }
    """.data(using: .utf8)!

    func testParse_readsSpineAndSortsMediumFirst() throws {
        let report = try XCTUnwrap(OrphansReport.parse(canned))
        XCTAssertEqual(report.roots, ["/Users/dev/Library/Caches"])
        XCTAssertEqual(report.installedCount, 42)
        XCTAssertEqual(report.count, 2)
        XCTAssertEqual(report.orphans.count, 2)

        // Medium-confidence hits lead the list — the CLI emits name-sorted,
        // the pane wants strongest evidence first.
        XCTAssertEqual(report.orphans[0].name, "com.deadvendor.oldapp")
        XCTAssertEqual(report.orphans[0].confidence, "medium")
        XCTAssertEqual(report.orphans[0].evidence,
                       ["app-artifact-shaped", "not-matched-to-installed-inventory"])
        XCTAssertFalse(report.orphans[0].defaultSelected)
        XCTAssertEqual(report.orphans[1].confidence, "weak")
        XCTAssertEqual(report.orphans[1].path, "/Users/dev/Library/Caches/OldAppLeftovers")
    }

    func testParse_emptyOrphansIsAValidCleanReport() throws {
        let data = """
        {"roots": ["/tmp"], "installed_count": 10, "count": 0, "orphans": []}
        """.data(using: .utf8)!
        let report = try XCTUnwrap(OrphansReport.parse(data))
        XCTAssertTrue(report.orphans.isEmpty)
        XCTAssertEqual(report.count, 0)
    }

    func testParse_dropsRowsMissingTheSpineKeepsGoodOnes() throws {
        // A hit missing name or path is dropped; the rest still parses.
        // Missing confidence/evidence degrade to "weak"/[] (loose everywhere
        // except the spine).
        let data = """
        {"roots": ["/tmp"], "installed_count": 1, "count": 3, "orphans": [
          {"confidence": "medium"},
          {"name": "ghost", "path": "/tmp/ghost"},
          {"name": "x", "confidence": "weak"}
        ]}
        """.data(using: .utf8)!
        let report = try XCTUnwrap(OrphansReport.parse(data))
        XCTAssertEqual(report.orphans.count, 1)
        XCTAssertEqual(report.orphans[0].name, "ghost")
        XCTAssertEqual(report.orphans[0].confidence, "weak", "missing confidence degrades to weak")
        XCTAssertTrue(report.orphans[0].evidence.isEmpty)
    }

    func testParse_windowsLowTierSortsBetweenMediumAndWeak() throws {
        // burrow-cli's Windows scanner also emits "low" — it must rank below
        // medium but above weak, and never crash the macOS pane.
        let data = """
        {"roots": ["/tmp"], "installed_count": 0, "count": 3, "orphans": [
          {"name": "a-weak",   "path": "/t/a", "confidence": "weak"},
          {"name": "b-low",    "path": "/t/b", "confidence": "low"},
          {"name": "c-medium", "path": "/t/c", "confidence": "medium"}
        ]}
        """.data(using: .utf8)!
        let report = try XCTUnwrap(OrphansReport.parse(data))
        XCTAssertEqual(report.orphans.map(\.confidence), ["medium", "low", "weak"])
    }

    func testParse_sortIsStableWithinATier() throws {
        // Same tier -> the CLI's (name-sorted) order is preserved.
        let data = """
        {"roots": ["/tmp"], "installed_count": 0, "count": 3, "orphans": [
          {"name": "alpha", "path": "/t/alpha", "confidence": "weak"},
          {"name": "beta",  "path": "/t/beta",  "confidence": "weak"},
          {"name": "gamma", "path": "/t/gamma", "confidence": "weak"}
        ]}
        """.data(using: .utf8)!
        let report = try XCTUnwrap(OrphansReport.parse(data))
        XCTAssertEqual(report.orphans.map(\.name), ["alpha", "beta", "gamma"])
    }

    func testParse_missingCountsFallBackToComputed() throws {
        // No count / installed_count -> count falls back to the parsed rows,
        // installedCount to 0 (rendered as "unknown inventory", not a crash).
        let data = """
        {"orphans": [{"name": "ghost", "path": "/tmp/ghost", "confidence": "medium"}]}
        """.data(using: .utf8)!
        let report = try XCTUnwrap(OrphansReport.parse(data))
        XCTAssertEqual(report.count, 1)
        XCTAssertEqual(report.installedCount, 0)
        XCTAssertTrue(report.roots.isEmpty)
    }

    func testParse_garbageIsNilNotACrash() {
        XCTAssertNil(OrphansReport.parse(Data("not json".utf8)))
        XCTAssertNil(OrphansReport.parse(Data()))
        // Valid JSON but not an object — orphans reports are objects.
        XCTAssertNil(OrphansReport.parse(Data("[1, 2, 3]".utf8)))
    }
}
