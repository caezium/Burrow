//
//  MetricsStoreTests.swift
//  BurrowTests
//
//  Boundary tests for the one metrics query/aggregation layer, against a
//  temporary database (real SQLite, no mocks — the local-substitutable way).
//  MetricsStore absorbs SnapshotStore and becomes the single implementation
//  behind the MCP tools, the HTTP query server, and the chart view models;
//  these tests replace SnapshotStoreTests and pin the aggregation semantics
//  (peak/avg/cpu-time, the down-sample-aware interval estimate) that were
//  previously copy-pasted across three surfaces.
//

import XCTest
@testable import Burrow

final class MetricsStoreTests: XCTestCase {
    private var tempDir: URL!
    private var db: DB!
    private var store: MetricsStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-metrics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try DB(at: tempDir.appendingPathComponent("burrow.db"))
        store = MetricsStore(db: db)
    }

    override func tearDown() {
        store = nil
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Minimal valid `mo status --json` with a given CPU usage and optional
    /// top-processes rows (name, cpu, memory %, memory bytes).
    private func snapshotJSON(cpu: Double,
                              procs: [(name: String, cpu: Double, mem: Double, memBytes: UInt64)] = []) -> String {
        let top = procs.map {
            "{\"pid\":1,\"name\":\"\($0.name)\",\"command\":\"\($0.name)\",\"cpu\":\($0.cpu),\"memory\":\($0.mem),\"memory_bytes\":\($0.memBytes)}"
        }.joined(separator: ",")
        return """
        {"collected_at":"2026-06-08T03:16:25.068057-07:00","host":"h","platform":"darwin",
         "uptime_seconds":100,"procs":1,
         "hardware":{"model":"Mac","cpu_model":"M","total_ram":"24 GB","disk_size":"460 GB","os_version":"26"},
         "health_score":90,"health_score_msg":"Good",
         "cpu":{"usage":\(cpu),"load1":1,"load5":1,"load15":1,"core_count":10,"logical_cpu":10},
         "memory":{"used":1,"total":2,"used_percent":50,"swap_used":0,"swap_total":0,"pressure":""},
         "disk_io":{"read_rate":0,"write_rate":0},
         "top_processes":[\(top)]}
        """
    }

    // MARK: Latest

    func testLatest_returnsMostRecentDecoded() throws {
        XCTAssertNil(store.latest(), "empty store → nil")
        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: 100, json: snapshotJSON(cpu: 10))
        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: 200, json: snapshotJSON(cpu: 80))
        XCTAssertEqual(Int(store.latest()?.status.cpu.usage ?? -1), 80)
    }

    // MARK: Ranged snapshots

    func testSnapshots_decodesRowsInWindowAndExcludesOutside() throws {
        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: 100, json: snapshotJSON(cpu: 10))
        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: 200, json: snapshotJSON(cpu: 80))
        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: 5000, json: snapshotJSON(cpu: 99))

        let snaps = store.snapshots(MetricsStore.Window(since: 0, until: 1000))
        XCTAssertEqual(snaps.map(\.ts), [100, 200])
        XCTAssertEqual(snaps.map { Int($0.status.cpu.usage) }, [10, 80])
    }

    func testSnapshots_skipsMalformedRows() throws {
        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: 100, json: "not valid json")
        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: 200, json: snapshotJSON(cpu: 50))
        let snaps = store.snapshots(MetricsStore.Window(since: 0, until: 1000))
        XCTAssertEqual(snaps.count, 1)
        XCTAssertEqual(Int(snaps[0].status.cpu.usage), 50)
    }

    func testWindowLastMinutes_computesBounds() {
        let now = Date(timeIntervalSince1970: 10_000)
        let w = MetricsStore.Window.lastMinutes(30, now: now)
        XCTAssertEqual(w.since, 10_000 - 1800)
        XCTAssertEqual(w.until, 10_000)
    }

    // MARK: Raw passthrough — wire formats embed stored JSON verbatim

    func testLatestRaw_returnsVerbatimStoredText() throws {
        XCTAssertNil(store.latestRaw())
        let exact = "{\"anything\":\"even not a MoleStatus\"}"
        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: 42, json: exact)
        let row = try XCTUnwrap(store.latestRaw())
        XCTAssertEqual(row.ts, 42)
        XCTAssertEqual(row.json, exact, "byte-identical — no parse → re-encode roundtrip")
    }

    func testRawRows_fullVsSampled_anyPrefix() throws {
        for t in 1...10 {
            try db.insert(prefix: "other.reader", ts: t * 100, json: "{\"n\":\(t)}")
        }
        let w = MetricsStore.Window(since: 0, until: 2000)
        XCTAssertEqual(store.rawRows(prefix: "other.reader", w, maxPoints: nil).count, 10)
        XCTAssertLessThanOrEqual(store.rawRows(prefix: "other.reader", w, maxPoints: 5).count, 5)
        XCTAssertEqual(store.rawRows(prefix: "other.reader", w, maxPoints: nil).first?.json, "{\"n\":1}")
    }

    // MARK: Series projection — metric meaning stays at the call site

    func testSeries_projectsValuesWithTimestamps() throws {
        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: 100, json: snapshotJSON(cpu: 10))
        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: 200, json: snapshotJSON(cpu: 80))
        let pts = store.series(MetricsStore.Window(since: 0, until: 1000), maxPoints: 100) { $0.cpu.usage }
        XCTAssertEqual(pts.map(\.ts), [100, 200])
        XCTAssertEqual(pts.map { Int($0.value) }, [10, 80])
    }

    func testSeries_skipsNilProjections() throws {
        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: 100, json: snapshotJSON(cpu: 10))
        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: 200, json: snapshotJSON(cpu: 80))
        // The fixture has no GPU block, so a gpu read yields nil → no point,
        // instead of a fake zero polluting the chart.
        let pts = store.series(MetricsStore.Window(since: 0, until: 1000), maxPoints: 100) { $0.gpu?.first?.usage }
        XCTAssertTrue(pts.isEmpty)
    }

    // MARK: Process aggregation — computed once, ranked per caller

    /// Three snapshots, 60 s apart: chrome 50/100/30 %CPU, mds in one frame.
    private func seedProcessWindow() throws {
        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: 100, json: snapshotJSON(
            cpu: 10, procs: [("chrome", 50, 5, 100), ("mds", 10, 50, 900)]))
        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: 160, json: snapshotJSON(
            cpu: 10, procs: [("chrome", 100, 7, 300)]))
        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: 220, json: snapshotJSON(
            cpu: 10, procs: [("chrome", 30, 6, 200)]))
    }

    func testProcessWindow_aggregatesPeakAvgAndCPUTime() throws {
        try seedProcessWindow()
        let pw = store.processWindow(MetricsStore.Window(since: 0, until: 1000))

        XCTAssertEqual(pw.sampleCount, 3)
        XCTAssertEqual(pw.startTS, 100)
        XCTAssertEqual(pw.endTS, 220)
        // Effective spacing of the snapshots actually returned — the
        // down-sample-aware estimate, owned here exactly once.
        XCTAssertEqual(pw.intervalSeconds, 60, accuracy: 0.001)

        let chrome = try XCTUnwrap(pw.ranked(by: .peakCPU, limit: 10).first { $0.name == "chrome" })
        XCTAssertEqual(chrome.peakCPU, 100)
        XCTAssertEqual(chrome.avgCPU, 60, accuracy: 0.001)          // (50+100+30)/3
        XCTAssertEqual(chrome.estCPUSeconds, 108, accuracy: 0.001)  // 180/100 × 60s
        XCTAssertEqual(chrome.peakMem, 7)
        XCTAssertEqual(chrome.peakMemBytes, 300)
        XCTAssertEqual(chrome.samples, 3)
    }

    func testProcessWindow_rankedByEachMetric() throws {
        try seedProcessWindow()
        let pw = store.processWindow(MetricsStore.Window(since: 0, until: 1000))

        XCTAssertEqual(pw.ranked(by: .peakCPU, limit: 10).first?.name, "chrome")
        XCTAssertEqual(pw.ranked(by: .avgCPU, limit: 10).first?.name, "chrome")
        XCTAssertEqual(pw.ranked(by: .cpuTime, limit: 10).first?.name, "chrome")
        // mds peaked at 50% memory vs chrome's 7%.
        XCTAssertEqual(pw.ranked(by: .peakMem, limit: 10).first?.name, "mds")
        XCTAssertEqual(pw.ranked(by: .peakCPU, limit: 1).count, 1)
    }

    func testProcessRank_rawValuesAreTheMCPWireStrings() {
        // These four strings are the MCP tool contract — renaming a case
        // must break this test, not silently change the wire.
        XCTAssertEqual(MetricsStore.ProcessRank(rawValue: "cpu_time"), .cpuTime)
        XCTAssertEqual(MetricsStore.ProcessRank(rawValue: "peak_cpu"), .peakCPU)
        XCTAssertEqual(MetricsStore.ProcessRank(rawValue: "avg_cpu"), .avgCPU)
        XCTAssertEqual(MetricsStore.ProcessRank(rawValue: "peak_mem"), .peakMem)
    }

    func testProcessWindow_emptyRangeEchoesWindowBounds() {
        let pw = store.processWindow(MetricsStore.Window(since: 500, until: 900))
        XCTAssertEqual(pw.sampleCount, 0)
        XCTAssertEqual(pw.startTS, 500)
        XCTAssertEqual(pw.endTS, 900)
        XCTAssertTrue(pw.ranked(by: .peakCPU, limit: 10).isEmpty)
        XCTAssertGreaterThan(pw.intervalSeconds, 0, "falls back to the sampler cadence")
    }

    // MARK: Reader staleness — burrow_info + GET /info

    func testReaders_reportAgePerPrefix() throws {
        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: 800, json: snapshotJSON(cpu: 1))
        try db.insert(prefix: "other.reader", ts: 950, json: "{}")

        let readers = store.readers(now: 1000)
        XCTAssertEqual(readers.count, 2)
        let snap = try XCTUnwrap(readers.first { $0.prefix == MetricsStore.snapshotPrefix })
        XCTAssertEqual(snap.latestTS, 800)
        XCTAssertEqual(snap.ageSeconds, 200)
        // Clock skew clamps to 0, never negative.
        let other = try XCTUnwrap(store.readers(now: 900).first { $0.prefix == "other.reader" })
        XCTAssertEqual(other.ageSeconds, 0)
    }

    func testReaders_emptyStoreIsEmpty() {
        XCTAssertTrue(store.readers(now: 1000).isEmpty)
    }
}
