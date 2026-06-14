//
//  FeedsTests.swift
//  BurrowTests
//
//  The demand-driven feed layer (issue #53): shared refcounted pumps
//  keyed by query, task-scoped subscription lifecycle, in-flight
//  coalescing, keep-stale-on-failure, and change suppression — asserted
//  against published values on a manual clock. Render nothing; spawn
//  nothing. Leak-freedom is structural: nothing ticks without a
//  subscriber, so the HistoryView timer-leak class is unrepresentable.
//

import XCTest
@testable import Burrow

@MainActor
final class FeedsTests: XCTestCase {
    private var clock: ManualFeedClock!
    private var hub: FeedHub!

    override func setUp() async throws {
        clock = ManualFeedClock()
        hub = FeedHub(clock: clock)
    }

    /// Let the feed's internal fetch Task hop the actor and apply.
    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    // MARK: Sharing — identical keys resolve to ONE pump

    func testFeed_isSharedByQueryKey() {
        let a: Feed<Int> = hub.feed("cpu", cadence: 2) { 1 }
        let b: Feed<Int> = hub.feed("cpu", cadence: 2) { 2 }
        let c: Feed<Int> = hub.feed("mem", cadence: 2) { 3 }
        XCTAssertTrue(a === b, "same key → same instance → one timer, one fetch, N observers")
        XCTAssertFalse(a === c)
    }

    // MARK: Demand counting + structural leak-freedom

    func testFirstSubscriberStartsThePump_lastStopsIt() async {
        let feed: Feed<Int> = hub.feed("k", cadence: 2) { 7 }
        XCTAssertEqual(feed.fetchCount, 0, "nothing ticks without a subscriber")

        feed.attach()
        await settle()
        XCTAssertEqual(feed.fetchCount, 1, "first attach takes an immediate sample")
        XCTAssertEqual(feed.value, 7)

        feed.attach()                       // second observer of the same pump
        clock.advance()
        await settle()
        XCTAssertEqual(feed.fetchCount, 2, "two subscribers + one tick = ONE upstream fetch")

        feed.detach()
        clock.advance()
        await settle()
        XCTAssertEqual(feed.fetchCount, 3, "still one subscriber → still ticking")

        feed.detach()
        clock.advance()
        clock.advance()
        await settle()
        XCTAssertEqual(feed.fetchCount, 3, "zero subscribers → zero fetches, structurally")
    }

    func testSubscribeValues_cancellationIsTheUnsubscribe() async {
        let feed: Feed<Int> = hub.feed("k", cadence: 2) { 5 }
        let task = Task { @MainActor in
            for await v in feed.subscribeValues() {
                XCTAssertEqual(v, 5)
                break   // got the first value; keep the subscription parked
            }
        }
        _ = await task.value
        await settle()
        XCTAssertGreaterThanOrEqual(feed.fetchCount, 1)

        // The for-await loop above ended (break terminates the stream), so
        // the subscription is gone: further ticks must fetch nothing.
        let before = feed.fetchCount
        clock.advance()
        await settle()
        XCTAssertEqual(feed.fetchCount, before, "ended subscription = detached pump")
    }

    // MARK: Coalescing — a slow fetch absorbs ticks

    func testTicksCoalesceWhileAFetchIsInFlight() async {
        let gate = FetchGate()
        let feed: Feed<Int> = hub.feed("slow", cadence: 2) { await gate.wait() }
        feed.attach()
        await settle()
        clock.advance()
        clock.advance()
        clock.advance()
        await settle()
        XCTAssertEqual(feed.fetchCount, 1, "three ticks over one in-flight fetch = one call")
        await gate.open(42)
        await settle()
        XCTAssertEqual(feed.value, 42)
        feed.detach()
    }

    // MARK: Failure keeps the stale value; the next tick self-heals

    func testFailureKeepsStaleValue_thenSelfHeals() async {
        let script = ScriptedFetch([.success(1), .failure, .success(2)])
        let feed: Feed<Int> = hub.feed("flaky", cadence: 2) { script.next() }
        feed.attach()
        await settle()
        XCTAssertEqual(feed.value, 1)

        clock.advance()
        await settle()
        guard case .failed(let stale) = feed.phase else {
            return XCTFail("fetch failure must surface as .failed, got \(feed.phase)")
        }
        XCTAssertEqual(stale, 1, "dashboards degrade, they don't blank")
        XCTAssertEqual(feed.value, 1)

        clock.advance()
        await settle()
        XCTAssertEqual(feed.value, 2, "next successful tick self-heals")
        feed.detach()
    }

    // MARK: Change suppression — identical token, zero re-publishes

    func testIdenticalChangeTokenDoesNotRepublish() async {
        let feed: Feed<Int> = hub.feed("same", cadence: 1,
                                       changeToken: { AnyHashable($0) }) { 9 }
        var publishes = 0
        let sub = feed.objectWillChange.sink { publishes += 1 }
        defer { sub.cancel() }

        feed.attach()
        await settle()
        let afterFirst = publishes
        clock.advance()
        clock.advance()
        await settle()
        XCTAssertEqual(publishes, afterFirst,
                       "1 Hz polling over an unchanged row must cause zero invalidations")
        feed.detach()
    }

    /// Suppression must not survive a failure: success → fail → identical
    /// success has to land back in .ready, or the feed reports a stale
    /// failure forever while fetches are healthy.
    func testRecoveryAfterFailure_republishesEvenWithIdenticalToken() async {
        let script = ScriptedFetch([.success(1), .failure, .success(1)])
        let feed: Feed<Int> = hub.feed("recover", cadence: 2,
                                       changeToken: { AnyHashable($0) }) { script.next() }
        feed.attach()
        await settle()
        XCTAssertEqual(feed.value, 1)

        clock.advance()
        await settle()
        guard case .failed = feed.phase else {
            return XCTFail("expected .failed after the flaky tick, got \(feed.phase)")
        }

        clock.advance()
        await settle()
        guard case .ready(let v) = feed.phase else {
            return XCTFail("a healthy fetch must return the feed to .ready even when the value is unchanged — got \(feed.phase)")
        }
        XCTAssertEqual(v, 1)
        feed.detach()
    }

    // MARK: Migration — the shared metric pumps (issue #53 remainder)
    //
    // The headline of the migration: the popover HUD and the Status pane
    // used to run their own timer pairs polling the same `LiveFeed`
    // snapshot and the same DB history window. Now both ask the hub for the
    // SAME keys, so each query is ONE pump — one timer, one read, two
    // observers. These assert that property end-to-end with the real
    // `liveSnapshot`/`metricSparklines` factories.

    func testMetricPumps_sameKeyAcrossTwoScreens_isOnePump() throws {
        let db = try Self.tempDB()
        defer { Self.removeDB(db) }
        let live = LiveFeed()

        // "HUD" and "Status" each resolve the snapshot + sparkline queries.
        let hudSnap = hub.liveSnapshot(live)
        let statusSnap = hub.liveSnapshot(live)
        let hudSpark = hub.metricSparklines(db: db.db)
        let statusSpark = hub.metricSparklines(db: db.db)

        XCTAssertTrue(hudSnap === statusSnap, "both screens share ONE snapshot pump")
        XCTAssertTrue(hudSpark === statusSpark, "both screens share ONE sparkline pump")
        // …and the two queries are distinct pumps (different keys).
        XCTAssertFalse((hudSnap as AnyObject) === (hudSpark as AnyObject))
    }

    func testSharedSnapshotPump_twoSubscribers_oneFetchPerTick() async throws {
        let live = LiveFeed()
        // The HUD and the Status pane both bind the live-snapshot pump.
        let hud = hub.liveSnapshot(live)
        let status = hub.liveSnapshot(live)
        XCTAssertTrue(hud === status)

        hud.attach()                       // popover opens
        await settle()
        XCTAssertEqual(hud.fetchCount, 1, "first subscriber takes an immediate sample")

        status.attach()                    // Status pane mounts onto the same pump
        clock.advance()
        await settle()
        XCTAssertEqual(hud.fetchCount, 2,
                       "two subscribers + one tick = ONE upstream read, not two")

        status.detach()                    // leave Status; popover still open
        clock.advance()
        await settle()
        XCTAssertEqual(hud.fetchCount, 3, "one subscriber left → still ticking")

        hud.detach()                       // popover closes
        clock.advance()
        clock.advance()
        await settle()
        XCTAssertEqual(hud.fetchCount, 3, "zero subscribers → zero reads, structurally")
    }

    func testMetricSparklines_identicalWindow_suppressesRepublish() async throws {
        let db = try Self.tempDB()
        defer { Self.removeDB(db) }
        // Two rows, fixed — the window doesn't change between ticks, so the
        // projected value is identical and the change token must fold it.
        try db.insertSnapshot(ts: 100, cpu: 10)
        try db.insertSnapshot(ts: 200, cpu: 20)

        let feed = hub.metricSparklines(db: db.db)
        var publishes = 0
        let sub = feed.objectWillChange.sink { publishes += 1 }
        defer { sub.cancel() }

        feed.attach()
        await settle()
        let afterFirst = publishes
        clock.advance()
        clock.advance()
        await settle()
        XCTAssertEqual(publishes, afterFirst,
                       "an unchanged DB window must cause zero republishes across ticks")
        feed.detach()
    }

    // MARK: Migration — Sparklines aggregation (pure helper)

    func testSparklines_projectsEachSeriesAndRanksTopDrain() throws {
        // Two snapshots: rising CPU, a fan-reporting machine, and one
        // process ("hog") that out-CPUs the rest on average.
        let s1 = try Self.status(cpu: 10, memPct: 40, rx: 1, tx: 2, gpu: 5,
                                 fanCount: 2, fanSpeed: 1200,
                                 procs: [("hog", 80), ("idle", 1)])
        let s2 = try Self.status(cpu: 30, memPct: 50, rx: 3, tx: 4, gpu: 15,
                                 fanCount: 2, fanSpeed: 1400,
                                 procs: [("hog", 90), ("idle", 2)])

        let out = Sparklines.from([s1, s2])
        XCTAssertEqual(out.cpu, [10, 30])
        XCTAssertEqual(out.mem, [40, 50])
        XCTAssertEqual(out.net, [3, 7], "net is rx+tx summed across interfaces")
        XCTAssertEqual(out.gpu, [5, 15])
        XCTAssertEqual(out.fan, [1200, 1400], "RPM kept only when fans are reported")
        XCTAssertEqual(out.topDrain?.name, "hog", "heaviest process by average CPU")
        XCTAssertEqual(out.topDrain?.avgCPU ?? 0, 85, accuracy: 0.001)
    }

    func testSparklines_dropsFanlessSnapshots_andTrimsToTail() throws {
        // No fans on this machine → the fan series stays empty even though
        // the other series have points (the "no placebo zeros" rule).
        let noFan = try Self.status(cpu: 1, memPct: 1, rx: 0, tx: 0, gpu: 0,
                                    fanCount: 0, fanSpeed: 0, procs: [])
        let out1 = Sparklines.from([noFan, noFan, noFan])
        XCTAssertEqual(out1.fan, [], "fan-less snapshots contribute nothing")
        XCTAssertEqual(out1.cpu.count, 3)
        XCTAssertNil(out1.topDrain, "no processes → no drain")

        // tailPoints trims the sparkline to its newest N while keeping order.
        let many = try (0..<10).map { try Self.status(cpu: Double($0), memPct: 0, rx: 0, tx: 0,
                                                       gpu: 0, fanCount: 0, fanSpeed: 0, procs: []) }
        let out2 = Sparklines.from(many, tailPoints: 3)
        XCTAssertEqual(out2.cpu, [7, 8, 9], "keeps the newest tailPoints in order")
    }
}

// MARK: - Migration test plumbing (snapshot/DB builders)

extension FeedsTests {
    /// A throwaway on-disk DB plus a tiny snapshot writer, mirroring the
    /// MetricsStoreTests pattern (real SQLite, no mocks).
    final class TempDB {
        let db: DB
        let dir: URL
        init() throws {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("burrow-feeds-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            db = try DB(at: dir.appendingPathComponent("burrow.db"))
        }
        func insertSnapshot(ts: Int, cpu: Double) throws {
            try db.insert(prefix: MetricsStore.snapshotPrefix, ts: ts,
                          json: FeedsTests.statusJSON(cpu: cpu))
        }
    }

    nonisolated static func tempDB() throws -> TempDB { try TempDB() }
    nonisolated static func removeDB(_ t: TempDB) { try? FileManager.default.removeItem(at: t.dir) }

    /// Minimal valid `mo status --json` for a CPU value (the sparkline test
    /// only needs the window to be non-empty and stable).
    nonisolated static func statusJSON(cpu: Double) -> String {
        """
        {"collected_at":"2026-06-08T03:16:25.068057-07:00","host":"h","platform":"darwin",
         "uptime_seconds":100,"procs":1,
         "hardware":{"model":"Mac","cpu_model":"M","total_ram":"24 GB","disk_size":"460 GB","os_version":"26"},
         "health_score":90,"health_score_msg":"Good",
         "cpu":{"usage":\(cpu),"load1":1,"load5":1,"load15":1,"core_count":10,"logical_cpu":10},
         "memory":{"used":1,"total":2,"used_percent":50,"swap_used":0,"swap_total":0,"pressure":""},
         "disk_io":{"read_rate":0,"write_rate":0}}
        """
    }

    /// Decode a synthetic MoleStatus for the pure-aggregation tests.
    nonisolated static func status(cpu: Double, memPct: Double, rx: Double, tx: Double, gpu: Double,
                                   fanCount: Int, fanSpeed: Int,
                                   procs: [(name: String, cpu: Double)]) throws -> MoleStatus {
        let top = procs.map {
            "{\"pid\":1,\"name\":\"\($0.name)\",\"command\":\"\($0.name)\",\"cpu\":\($0.cpu),\"memory\":0}"
        }.joined(separator: ",")
        let json = """
        {"collected_at":"2026-06-08T03:16:25.068057-07:00","host":"h","platform":"darwin",
         "uptime_seconds":100,"procs":1,
         "hardware":{"model":"Mac","cpu_model":"M","total_ram":"24 GB","disk_size":"460 GB","os_version":"26"},
         "health_score":90,"health_score_msg":"Good",
         "cpu":{"usage":\(cpu),"load1":1,"load5":1,"load15":1,"core_count":10,"logical_cpu":10},
         "memory":{"used":1,"total":2,"used_percent":\(memPct),"swap_used":0,"swap_total":0,"pressure":""},
         "disk_io":{"read_rate":0,"write_rate":0},
         "network":[{"name":"en0","rx_rate_mbs":\(rx),"tx_rate_mbs":\(tx),"ip":"10.0.0.1"}],
         "gpu":[{"name":"GPU","usage":\(gpu),"memory_used":0,"memory_total":0,"core_count":8}],
         "thermal":{"cpu_temp":0,"gpu_temp":0,"fan_speed":\(fanSpeed),"fan_count":\(fanCount),"system_power":0},
         "top_processes":[\(top)]}
        """
        return try JSONDecoder().decode(MoleStatus.self, from: Data(json.utf8))
    }
}

// MARK: - Test plumbing

/// Holds fetches open until released — the coalescing scenario.
private actor FetchGate {
    private var continuations: [CheckedContinuation<Int?, Never>] = []
    func wait() async -> Int? {
        await withCheckedContinuation { continuations.append($0) }
    }
    func open(_ value: Int) {
        let conts = continuations
        continuations = []
        for c in conts { c.resume(returning: value) }
    }
}

/// Deterministic fetch script: each call returns the next result.
private final class ScriptedFetch: @unchecked Sendable {
    enum Step { case success(Int), failure }
    private var steps: [Step]
    private let lock = NSLock()
    init(_ steps: [Step]) { self.steps = steps }
    func next() -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard !steps.isEmpty else { return nil }
        switch steps.removeFirst() {
        case .success(let v): return v
        case .failure: return nil
        }
    }
}
