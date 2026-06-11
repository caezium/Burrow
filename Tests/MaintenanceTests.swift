//
//  MaintenanceTests.swift
//  BurrowTests
//
//  Exercises the prune path against a fresh DB. Doesn't exercise the
//  hourly timer itself — that's just `DispatchSource.makeTimerSource`
//  with stable settings; testing it would mean injecting a clock and
//  is overkill for v0.2. `runNow()` runs the same prune body the
//  timer would, so coverage of the actual logic is here.
//

import XCTest
@testable import Burrow

final class MaintenanceTests: XCTestCase {
    private var tempDir: URL!
    private var db: DB!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-maint-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try DB(at: tempDir.appendingPathComponent("burrow.db"))
        // Defaults under our control during the test — in a scratch suite so
        // the developer's real retention setting is never touched (and the
        // hosted app, if it ever ran services, couldn't see the 7 either).
        Store.d = UserDefaults(suiteName: StoreTests.scratchSuite)!
        Store.d.removePersistentDomain(forName: StoreTests.scratchSuite)
        Store.d.set(7, forKey: "retention_days")
    }

    override func tearDown() {
        db = nil
        Store.d.removePersistentDomain(forName: StoreTests.scratchSuite)
        Store.d = .standard
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRunNow_prunesOlderThanRetention() throws {
        let now = Int(Date().timeIntervalSince1970)
        let day = 86_400
        try db.insert(prefix: "p", ts: now - 14 * day, json: "{}")  // older than 7d
        try db.insert(prefix: "p", ts: now - 3 * day,  json: "{}")  // within
        try db.insert(prefix: "p", ts: now,             json: "{}") // current

        let m = Maintenance(db: db)
        m.runNow()

        let surviving = db.findRange(prefix: "p", since: 0, until: now + 1)
        XCTAssertEqual(surviving.count, 2, "two rows should survive a 7-day retention")
        XCTAssertEqual(m.lastPruneDeleted, 1)
        XCTAssertNotNil(m.lastRunAt)
    }

    func testRunNow_isNoOpWhenAllRowsFresh() throws {
        let now = Int(Date().timeIntervalSince1970)
        try db.insert(prefix: "p", ts: now - 3_600, json: "{}")
        let m = Maintenance(db: db)
        m.runNow()
        XCTAssertEqual(m.lastPruneDeleted, 0)
    }

    func testRunNow_advancesLastRunAt() throws {
        let m = Maintenance(db: db)
        XCTAssertNil(m.lastRunAt)
        m.runNow()
        XCTAssertNotNil(m.lastRunAt)
        let first = m.lastRunAt!
        Thread.sleep(forTimeInterval: 0.01)
        m.runNow()
        XCTAssertGreaterThan(m.lastRunAt!, first, "second run should advance the timestamp")
    }
}
