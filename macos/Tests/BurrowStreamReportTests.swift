//
//  BurrowStreamReportTests.swift
//  BurrowTests
//
//  Locks the NDJSON → TaskRunReport contract that OperationFlow uses for streamed
//  clean/optimize. The engine emits one JSON object per line; the reducer must build the
//  same (groups, summary) shape the views render.
//

import XCTest
@testable import Burrow

final class BurrowStreamReportTests: XCTestCase {
    func testCleanPreview_yieldsCleanedSummary() {
        let lines = [
            #"{"event":"would_remove","path":"/Users/x/Library/Caches/npm","bytes":201129000}"#,
            #"{"event":"done","dry_run":true,"would_free_bytes":402438000,"would_free_human":"383.8MB","count":372}"#,
        ]
        let report = BurrowStreamReport.reduce(lines)
        XCTAssertEqual(report.groups.count, 1)
        XCTAssertEqual(report.groups.first?.items.count, 1)
        XCTAssertEqual(report.summary?.space, "383.8MB")
        XCTAssertEqual(report.summary?.items, "372")
        // No freeChange on a preview → "Cleaned", not "Freed".
        XCTAssertEqual(report.summary?.completionLine, "Cleaned 383.8MB · 372 items")
    }

    func testCleanLive_yieldsFreedSummary() {
        let lines = [
            #"{"event":"removed","path":"/a/x","bytes":10}"#,
            #"{"event":"failed","path":"/a/y","error":"denied"}"#,
            #"{"event":"protected","path":"/a/keep"}"#,
            #"{"event":"done","freed_bytes":2048,"freed_human":"2.0KB","removed":1,"failed":1,"protected":1}"#,
        ]
        let report = BurrowStreamReport.reduce(lines)
        XCTAssertEqual(report.groups.first?.items.count, 3, "removed + failed + protected are shown")
        // `freed_human` is the PLANNER's queued-for-removal tally (summed before deletion), not a
        // measured before/after disk delta — it belongs in `space` ("Cleaned"), not `freeChange`
        // ("Freed", reserved for an actual "Free space change:" reading the engine doesn't emit).
        XCTAssertEqual(report.summary?.completionLine, "Cleaned 2.0KB · 1 items")
        XCTAssertEqual(report.summary?.freeChange, "", "freeChange is reserved for a real free-space-change reading")
    }

    func testOptimize_taskEvents() {
        let lines = [
            #"{"event":"task","name":"flush_dns","ok":true,"error":null}"#,
            #"{"event":"task","name":"restart_dock","ok":false,"error":"no proc"}"#,
            #"{"event":"done","ok":false,"tasks":2,"failed":1}"#,
        ]
        let report = BurrowStreamReport.reduce(lines)
        XCTAssertEqual(report.groups.first?.items.count, 2)
        XCTAssertEqual(report.summary?.items, "2", "task count")
    }

    func testGarbageLinesAreIgnored() {
        // A stray non-JSON line (e.g. a warning) must not break the reduce.
        let lines = [
            "warning: something on stderr",
            #"{"event":"removed","path":"/a","bytes":1}"#,
            "",
            #"{"event":"done","freed_bytes":1,"freed_human":"1B","removed":1,"failed":0,"protected":0}"#,
        ]
        let report = BurrowStreamReport.reduce(lines)
        XCTAssertEqual(report.groups.first?.items.count, 1)
        XCTAssertNotNil(report.summary)
    }

    func testHudLine_extractsReadableLabel() {
        XCTAssertEqual(
            BurrowStreamReport.hudLine(#"{"event":"removed","path":"/a/b/npm cache","bytes":1}"#),
            "npm cache")
        XCTAssertEqual(
            BurrowStreamReport.hudLine(#"{"event":"task","name":"flush_dns","ok":true}"#),
            "flush_dns")
        XCTAssertEqual(BurrowStreamReport.hudLine("not json"), "")
    }

    // MARK: - streamedBytes (CleanView's live count-up hero number)

    func testStreamedBytes_readsRemovedAndWouldRemove_ignoresEverythingElse() {
        XCTAssertEqual(
            BurrowStreamReport.streamedBytes(#"{"event":"would_remove","path":"/a","bytes":1024}"#),
            1024)
        XCTAssertEqual(
            BurrowStreamReport.streamedBytes(#"{"event":"removed","path":"/a","bytes":2048}"#),
            2048)
        XCTAssertEqual(
            BurrowStreamReport.streamedBytes(#"{"event":"failed","path":"/a","error":"denied"}"#),
            0, "a failed item freed nothing")
        XCTAssertEqual(
            BurrowStreamReport.streamedBytes(#"{"event":"done","freed_bytes":999,"freed_human":"999B"}"#),
            0, "the terminal line's own total is read from summary.space, not accumulated here")
        XCTAssertEqual(BurrowStreamReport.streamedBytes("not json"), 0)
    }

    func testStreamedBytes_summedAcrossLines_matchesTheRunningTotal() {
        let lines = [
            #"{"event":"would_remove","path":"/a","bytes":100}"#,
            #"{"event":"would_remove","path":"/b","bytes":250}"#,
            #"{"event":"protected","path":"/c"}"#,
        ]
        let total = lines.reduce(Int64(0)) { $0 + BurrowStreamReport.streamedBytes($1) }
        XCTAssertEqual(total, 350)
    }
}
