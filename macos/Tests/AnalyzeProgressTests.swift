//
//  AnalyzeProgressTests.swift
//  BurrowTests
//
//  Pins the `burrow analyze --progress` NDJSON parse — the verified core a live-filling treemap
//  (#12) builds on. The stream reader + UI rework aren't here (that restructures AnalyzeView's
//  synchronous scan flow and can't be CI-driven); these cover the pure parsing it depends on.
//

import XCTest
@testable import Burrow

final class AnalyzeProgressTests: XCTestCase {

    func testParsesProgressTick() {
        let event = AnalyzeProgressEvent.parse(
            line: #"{"type":"progress","files":10,"dirs":2,"bytes":4096,"path":"/x"}"#)
        XCTAssertEqual(event, .progress(files: 10, dirs: 2, bytes: 4096, path: "/x"))
    }

    func testProgressToleratesMissingCounters() {
        // A tick missing a counter defaults it to 0 rather than dropping the whole event.
        let event = AnalyzeProgressEvent.parse(line: #"{"type":"progress","files":5}"#)
        XCTAssertEqual(event, .progress(files: 5, dirs: 0, bytes: 0, path: ""))
    }

    func testResultCarriesAnalysisPayloadAsData() throws {
        let event = AnalyzeProgressEvent.parse(
            line: #"{"type":"result","data":{"total_size":123,"total_files":4,"entries":[]}}"#)
        guard case .result(let data)? = event else { return XCTFail("expected .result, got \(String(describing: event))") }
        // The payload round-trips for DiskScanner.parse, ints intact.
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(payload["total_size"] as? Int, 123)
        XCTAssertEqual(payload["total_files"] as? Int, 4)
    }

    func testIgnoresBlankUnknownAndGarbage() {
        // Robust stream: blank keep-alives, forward-compatible new types, and non-JSON are skipped.
        XCTAssertNil(AnalyzeProgressEvent.parse(line: ""))
        XCTAssertNil(AnalyzeProgressEvent.parse(line: "   "))
        XCTAssertNil(AnalyzeProgressEvent.parse(line: #"{"type":"heartbeat"}"#))
        XCTAssertNil(AnalyzeProgressEvent.parse(line: "not json at all"))
        XCTAssertNil(AnalyzeProgressEvent.parse(line: #"{"no":"type"}"#))
    }
}
