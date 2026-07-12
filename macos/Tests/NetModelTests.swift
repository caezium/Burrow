//
//  NetModelTests.swift
//  BurrowTests
//
//  The pure parser behind the Network pane: `burrow net --json` returns an
//  envelope whose `data` is {count, by_total_bytes: [{name, pid, bytes_in,
//  bytes_out, total, metric_source, metric_note?}]}. On macOS the rows are
//  nettop BYTE counters (metric_source "macos_nettop_bytes", no note); on
//  Windows they degrade to connection counts and carry a metric_note the
//  pane must surface. Byte counts stay integer-exact (JSONSerialization,
//  like DupesModel). Garbage parses to nil, never a crash.
//

import XCTest
@testable import Burrow

final class NetModelTests: XCTestCase {

    /// A canned net report shaped like burrow-cli's `run_net` output on
    /// macOS: nettop byte counters, ranked by total descending.
    private let canned = """
    {
      "count": 3,
      "by_total_bytes": [
        {"name": "apsd", "pid": 573, "bytes_in": 28142, "bytes_out": 40592, "total": 68734,
         "metric_source": "macos_nettop_bytes"},
        {"name": "com.apple.WebKit.Networking", "pid": 123, "bytes_in": 5, "bytes_out": 7, "total": 12,
         "metric_source": "macos_nettop_bytes"},
        {"name": "launchd", "pid": 1, "bytes_in": 0, "bytes_out": 0, "total": 0,
         "metric_source": "macos_nettop_bytes"}
      ]
    }
    """.data(using: .utf8)!

    func testParse_readsRowsRankedByTotal() throws {
        let report = try XCTUnwrap(NetReport.parse(canned))
        XCTAssertEqual(report.rows.count, 3)
        XCTAssertEqual(report.rows[0].name, "apsd")
        XCTAssertEqual(report.rows[0].pid, 573)
        XCTAssertEqual(report.rows[0].bytesIn, 28142)
        XCTAssertEqual(report.rows[0].bytesOut, 40592)
        XCTAssertEqual(report.rows[0].total, 68734)
        XCTAssertEqual(report.rows[0].metricSource, "macos_nettop_bytes")
        XCTAssertNil(report.rows[0].metricNote)
        // Dotted helper names survive whole.
        XCTAssertEqual(report.rows[1].name, "com.apple.WebKit.Networking")
        XCTAssertEqual(report.rows[2].name, "launchd")
        XCTAssertNil(report.note, "byte-counter rows carry no caveat")
    }

    func testParse_resortsByTotalWhenTheCliOrderDrifts() throws {
        // The CLI ranks by total already, but the pane re-sorts defensively.
        let data = """
        {"count": 2, "by_total_bytes": [
          {"name": "small", "pid": 2, "bytes_in": 1, "bytes_out": 1, "total": 2, "metric_source": "macos_nettop_bytes"},
          {"name": "big",   "pid": 3, "bytes_in": 50, "bytes_out": 50, "total": 100, "metric_source": "macos_nettop_bytes"}
        ]}
        """.data(using: .utf8)!
        let report = try XCTUnwrap(NetReport.parse(data))
        XCTAssertEqual(report.rows.map(\.name), ["big", "small"])
    }

    func testParse_surfacesTheMetricNote() throws {
        // Windows fallback rows are connection COUNTS, not bytes — the note
        // explaining that must reach the pane (report.note = first note seen).
        let data = """
        {"count": 1, "by_total_bytes": [
          {"name": "chrome.exe", "pid": 42, "bytes_in": 0, "bytes_out": 0, "total": 3,
           "metric_source": "windows_netstat_connection_count",
           "metric_note": "Windows netstat fallback reports per-process connection counts; byte counters are unavailable in this fallback."}
        ]}
        """.data(using: .utf8)!
        let report = try XCTUnwrap(NetReport.parse(data))
        XCTAssertEqual(report.rows[0].metricNote?.isEmpty, false)
        XCTAssertEqual(report.note, report.rows[0].metricNote)
    }

    func testParse_dropsRowsMissingTheSpineKeepsGoodOnes() throws {
        // A row without a name is dropped; missing byte fields degrade to 0
        // (total recomputed from in+out when absent).
        let data = """
        {"count": 3, "by_total_bytes": [
          {"pid": 9, "total": 999},
          {"name": "quiet", "pid": 7},
          {"name": "busy", "pid": 8, "bytes_in": 10, "bytes_out": 20}
        ]}
        """.data(using: .utf8)!
        let report = try XCTUnwrap(NetReport.parse(data))
        XCTAssertEqual(report.rows.count, 2)
        XCTAssertEqual(report.rows[0].name, "busy")
        XCTAssertEqual(report.rows[0].total, 30, "absent total falls back to in+out")
        XCTAssertEqual(report.rows[1].name, "quiet")
        XCTAssertEqual(report.rows[1].total, 0)
    }

    func testParse_keepsInt64PrecisionAboveInt32() throws {
        // Multi-GB byte counters must survive exactly — the reason the parser
        // is JSONSerialization, matching DupesModel/DiskScanner.
        let data = """
        {"count": 1, "by_total_bytes": [
          {"name": "backupd", "pid": 4, "bytes_in": 5000000123, "bytes_out": 1,
           "total": 5000000124, "metric_source": "macos_nettop_bytes"}
        ]}
        """.data(using: .utf8)!
        let report = try XCTUnwrap(NetReport.parse(data))
        XCTAssertEqual(report.rows[0].bytesIn, 5_000_000_123)
        XCTAssertEqual(report.rows[0].total, 5_000_000_124)
    }

    func testParse_emptyRowsIsAValidQuietReport() throws {
        let data = #"{"count": 0, "by_total_bytes": []}"#.data(using: .utf8)!
        let report = try XCTUnwrap(NetReport.parse(data))
        XCTAssertTrue(report.rows.isEmpty)
    }

    func testParse_garbageIsNilNotACrash() {
        XCTAssertNil(NetReport.parse(Data("not json".utf8)))
        XCTAssertNil(NetReport.parse(Data()))
        // Valid JSON but not an object — net reports are objects.
        XCTAssertNil(NetReport.parse(Data("[1, 2, 3]".utf8)))
    }
}
