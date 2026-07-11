//
//  MCPTests.swift
//  BurrowTests
//
//  Smoke-tests the MCP tool catalog routing without standing up the
//  full stdio loop. The dispatcher (`MCPServer.handleLine`) is harder
//  to test directly because it owns FileHandles; calling
//  `ToolCatalog.call(...)` exercises the same code path one layer
//  below the JSON-RPC envelope and proves each tool name resolves +
//  returns valid JSON.
//

import XCTest
@testable import Burrow

final class MCPTests: XCTestCase {
    private var tempDir: URL!
    private var db: DB!
    private var catalog: ToolCatalog!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-mcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try DB(at: tempDir.appendingPathComponent("burrow.db"))
        catalog = ToolCatalog(db: db)

        // Seed a couple of snapshots so tools have something to return.
        let now = Int(Date().timeIntervalSince1970)
        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: now - 60, json: sampleSnapshot(cpu: 22.5))
        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: now,      json: sampleSnapshot(cpu: 88.0))
    }

    override func tearDown() {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
        Store.d.removePersistentDomain(forName: StoreTests.scratchSuite)
        Store.d = .standard
    }

    // MARK: - Argument hardening (audit M1)
    //
    // `minutes * 60` traps on Int overflow in all build configs — an
    // agent-supplied huge value must come back as a tool error, not kill
    // the MCP process. (No RED run exists for these: the un-guarded code
    // crashes the test runner instead of failing the assert.)

    func testHistory_rejectsOverflowingMinutes() {
        XCTAssertThrowsError(try catalog.call(name: "burrow_history",
                                              arguments: ["minutes": 200_000_000_000_000_000]))
    }

    func testTopProcesses_rejectsOverflowingMinutes() {
        XCTAssertThrowsError(try catalog.call(name: "burrow_top_processes",
                                              arguments: ["minutes": 200_000_000_000_000_000]))
    }

    func testHistory_acceptsSaneMinutes() throws {
        let json = try catalog.call(name: "burrow_history", arguments: ["minutes": 120])
        XCTAssertTrue(json.contains("\"count\""))
    }

    // MARK: - Irreversible-action gate (audit M2)

    /// The cleanup opt-in alone must NOT unlock uninstalls: they're
    /// irreversible-class (and `permanent:true` even bypasses the Trash),
    /// so they need the dedicated second switch. Blocked means blocked —
    /// no `mo` is spawned, the reply says why.
    func testUninstall_blockedWithoutIrreversibleOptIn() throws {
        Store.d = UserDefaults(suiteName: StoreTests.scratchSuite)!
        Store.d.removePersistentDomain(forName: StoreTests.scratchSuite)
        Store.mcpActionsEnabled = true   // first key on; second key stays off

        let json = try catalog.call(name: "burrow_uninstall",
                                    arguments: ["apps": ["Slack"], "confirm": true])
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["blocked"] as? Bool, true)
        XCTAssertEqual(obj["ran"] as? Bool, false)
        let reason = try XCTUnwrap(obj["reason"] as? String)
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("uninstall"),
                      "the block reason must point at the missing uninstall opt-in")
    }

    /// With neither key on, confirm:true is still blocked (pre-existing
    /// behavior, pinned so the gate order can't regress).
    func testUninstall_blockedWithoutAnyOptIn() throws {
        Store.d = UserDefaults(suiteName: StoreTests.scratchSuite)!
        Store.d.removePersistentDomain(forName: StoreTests.scratchSuite)

        let json = try catalog.call(name: "burrow_uninstall",
                                    arguments: ["apps": ["Slack"], "confirm": true])
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["blocked"] as? Bool, true)
    }

    func testDescriptors_listsAllToolsWithSchema() {
        let d = catalog.descriptors()
        let names = d.compactMap { $0["name"] as? String }
        XCTAssertEqual(Set(names),
                       ["burrow_snapshot", "burrow_history", "burrow_top_processes",
                        "burrow_process_usage", "burrow_disk_forecast", "burrow_diff",
                        "burrow_report", "burrow_doctor", "burrow_ports", "burrow_info",
                        "burrow_cleanup_history", "burrow_deleted_files",
                        "burrow_analyze", "burrow_list_apps",
                        "burrow_dupes", "burrow_net", "burrow_orphans",
                        "burrow_photos", "burrow_rules_dryrun", "burrow_sentinel",
                        "burrow_slim_check", "burrow_clean",
                        "burrow_optimize", "burrow_uninstall", "burrow_purge",
                        "burrow_installer"])
        // Every tool must carry an inputSchema and a description.
        for tool in d {
            XCTAssertNotNil(tool["description"] as? String)
            XCTAssertNotNil(tool["inputSchema"] as? [String: Any])
        }
    }

    func testCallSnapshot_returnsLatestRow() throws {
        let json = try catalog.call(name: "burrow_snapshot", arguments: [:])
        // Parses as a JSON object containing the snapshot.
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertNotNil(obj["ts"])
        XCTAssertNotNil(obj["snapshot"])
    }

    func testCallHistory_returnsRowCountAndRows() throws {
        let json = try catalog.call(name: "burrow_history", arguments: ["minutes": 5])
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let count = try XCTUnwrap(obj["count"] as? Int)
        XCTAssertGreaterThan(count, 0)
        let rows = try XCTUnwrap(obj["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, count)
    }

    func testCallHistory_rejectsZeroMinutes() {
        XCTAssertThrowsError(try catalog.call(name: "burrow_history", arguments: ["minutes": 0])) { err in
            guard case MCPToolError.badArguments = err else {
                return XCTFail("expected .badArguments, got \(err)")
            }
        }
    }

    func testCallTopProcesses_returnsAggregatedList() throws {
        let json = try catalog.call(name: "burrow_top_processes", arguments: ["minutes": 5, "limit": 5])
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["window_minutes"] as? Int, 5)
        let procs = try XCTUnwrap(obj["processes"] as? [[String: Any]])
        // Our seeded snapshots include a `top_processes` entry; the
        // aggregate should surface it.
        XCTAssertGreaterThan(procs.count, 0)
        let first = try XCTUnwrap(procs.first)
        XCTAssertNotNil(first["name"] as? String)
        XCTAssertNotNil(first["peak_cpu"] as? Double)
    }

    func testCallInfo_includesReadersAndRetention() throws {
        let json = try catalog.call(name: "burrow_info", arguments: [:])
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertNotNil(obj["now"])
        XCTAssertNotNil(obj["retention_days"])
        let readers = try XCTUnwrap(obj["readers"] as? [[String: Any]])
        XCTAssertEqual(readers.count, 1)
        XCTAssertEqual(readers[0]["prefix"] as? String, MetricsStore.snapshotPrefix)
    }

    func testCallInfo_surfacesDriftCounters() throws {
        MetricsStore.resetDriftCounters()
        let clean = try catalog.call(name: "burrow_info", arguments: [:])
        let cleanObj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(clean.utf8)) as? [String: Any])
        XCTAssertEqual(cleanObj["decode_skipped_total"] as? Int, 0)
        XCTAssertTrue(cleanObj["last_drift"] is NSNull)

        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: 999, json: "not valid json")
        _ = MetricsStore(db: db).snapshots(.init(since: 0, until: 1000))

        let drifted = try catalog.call(name: "burrow_info", arguments: [:])
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(drifted.utf8)) as? [String: Any])
        XCTAssertEqual(obj["decode_skipped_total"] as? Int, 1)
        let last = try XCTUnwrap(obj["last_drift"] as? [String: Any])
        XCTAssertEqual(last["ts"] as? Int, 999)
        XCTAssertNotNil(last["message"] as? String)
    }

    /// The semantic usage tool must re-rank by the requested metric — the
    /// whole point of adding it over burrow_top_processes (which only ever
    /// ranks by peak CPU and so calls a one-second spike the "top" process).
    /// "heavy" runs hot the whole window; "spike" peaks once then idles.
    func testCallProcessUsage_ranksByChosenMetric() throws {
        // (setUp already seeded a `kernel_task` at ~110% cumulative; pick
        // timestamps off the seed rows so we don't collide on the PK and
        // make `heavy` out-rank it on cumulative load.)
        let now = Int(Date().timeIntervalSince1970)
        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: now - 300,
                      json: snapshotJSON([("heavy", 60, 5)]))
        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: now - 240,
                      json: snapshotJSON([("heavy", 60, 5)]))
        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: now - 180,
                      json: snapshotJSON([("heavy", 60, 5), ("spike", 1, 1)]))
        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: now - 120,
                      json: snapshotJSON([("spike", 95, 1)]))

        let byCPUTime = try names(from: catalog.call(name: "burrow_process_usage",
                                                     arguments: ["minutes": 30, "metric": "cpu_time"]))
        XCTAssertEqual(byCPUTime.first, "heavy", "sustained load wins cumulative CPU-time")

        let byPeak = try names(from: catalog.call(name: "burrow_process_usage",
                                                  arguments: ["minutes": 30, "metric": "peak_cpu"]))
        XCTAssertEqual(byPeak.first, "spike", "the one-second spike wins peak CPU")
    }

    func testCallProcessUsage_reportsWindowItUsed() throws {
        let json = try catalog.call(name: "burrow_process_usage", arguments: ["minutes": 5])
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        // It must echo the window + metric so the agent isn't guessing.
        XCTAssertEqual(obj["window_minutes"] as? Int, 5)
        XCTAssertNotNil(obj["start_ts"]); XCTAssertNotNil(obj["end_ts"])
        XCTAssertNotNil(obj["sample_count"]); XCTAssertNotNil(obj["metric"])
    }

    func testCallProcessUsage_rejectsUnknownMetric() {
        XCTAssertThrowsError(try catalog.call(name: "burrow_process_usage",
                                              arguments: ["metric": "vibes"])) { err in
            guard case MCPToolError.badArguments = err else {
                return XCTFail("expected .badArguments, got \(err)")
            }
        }
    }

    // The `burrow mcp` PATH-shim invocation must be recognised alongside
    // the original `--mcp` flag, and ordinary launches must not be.
    func testIsMCPInvocation_recognisesFlagAndSubcommand() {
        XCTAssertTrue(BurrowMain.isMCPInvocation(["Burrow", "--mcp"]))
        XCTAssertTrue(BurrowMain.isMCPInvocation(["burrow", "mcp"]))
        XCTAssertFalse(BurrowMain.isMCPInvocation(["Burrow"]))
        XCTAssertFalse(BurrowMain.isMCPInvocation(["Burrow", "status"]))
    }

    // The two issue-#2 tools shell out to `mo` / read its log, which may be
    // absent on a CI runner. Rather than a machine-dependent "always valid
    // JSON" check (which passed whether mo ran, failed, or was missing), the
    // wrapping logic is now a pure function tested for BOTH branches.

    func testCleanupHistory_moAbsent_yieldsGracefulErrorObject() throws {
        // exit 127 = mo not found. Must be a valid object an agent can read,
        // never a throw.
        let json = ToolCatalog.cleanupHistoryResult(exitCode: 127, stdout: "")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertNotNil(obj["error"])
        XCTAssertEqual(obj["sessions"] as? [Any] != nil, true)
    }

    func testCleanupHistory_moPresent_passesThroughItsJSON() throws {
        let molesJSON = #"{"sessions":[{"command":"clean","size":"1MB"}]}"#
        let json = ToolCatalog.cleanupHistoryResult(exitCode: 0, stdout: "  \(molesJSON)\n")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let sessions = try XCTUnwrap(obj["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.first?["command"] as? String, "clean")
        XCTAssertNil(obj["error"], "a successful run must not carry an error marker")
    }

    func testCleanupHistory_moPresentButEmpty_yieldsEmptySessions() throws {
        let json = ToolCatalog.cleanupHistoryResult(exitCode: 0, stdout: "   \n")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual((obj["sessions"] as? [Any])?.count, 0)
    }

    func testDeletedFiles_emptyLog_yieldsZeroCount() throws {
        let json = ToolCatalog.deletedFilesResult(logText: "", logPath: "/tmp/x.log", limit: 10)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["count"] as? Int, 0)
        XCTAssertEqual((obj["files"] as? [Any])?.count, 0)
    }

    func testDeletedFiles_populatedLog_countsAndOrdersNewestFirst() throws {
        let log = "2026\ttrash\tcache\tok\t/a\n2026\tremove\tlog\tok\t/b"
        let json = ToolCatalog.deletedFilesResult(logText: log, logPath: "/tmp/x.log", limit: 10)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["count"] as? Int, 2)
        XCTAssertEqual(obj["log"] as? String, "/tmp/x.log")
        let files = try XCTUnwrap(obj["files"] as? [[String: Any]])
        XCTAssertEqual(files.first?["path"] as? String, "/b", "newest first")
    }

    func testParseDeletionLog_parsesRowsNewestFirst() {
        let log = """
        2026-06-07T10:00:00+0800\ttrash\tcache\tok\t/Users/x/Library/Caches/a
        2026-06-07T10:00:01+0800\tremove\tlog\tok\t/Users/x/Library/Logs/b.log
        2026-06-07T10:00:02+0800\ttrash\tunknown\tfailed\t/Users/x/c
        """
        let e = ToolCatalog.parseDeletionLog(log, limit: 10)
        XCTAssertEqual(e.count, 3)
        XCTAssertEqual(e.first?["path"] as? String, "/Users/x/c", "newest first")
        XCTAssertEqual(e.first?["status"] as? String, "failed")
        XCTAssertEqual(e.last?["action"] as? String, "trash")
    }

    func testParseDeletionLog_skipsMalformedLines() {
        let log = "garbage with no tabs\n2026\ttrash\tc\tok\t/a\n2026\ttrash\tc\tok\t/b"
        let e = ToolCatalog.parseDeletionLog(log, limit: 10)
        XCTAssertEqual(e.count, 2, "the tab-less line is dropped")
    }

    func testParseDeletionLog_respectsLimit() {
        let log = (1...5).map { "2026\ttrash\tc\tok\t/\($0)" }.joined(separator: "\n")
        let e = ToolCatalog.parseDeletionLog(log, limit: 2)
        XCTAssertEqual(e.count, 2)
        XCTAssertEqual(e.first?["path"] as? String, "/5", "keeps the 2 most recent, newest first")
        XCTAssertEqual(e.last?["path"] as? String, "/4")
    }

    // MARK: - Action tools (the gate)

    // (The decide() truth table in MoActionsTests is the safety model now —
    // realActionAllowed and its four-cell test collapsed into it.)

    // confirm:true with the Settings opt-in OFF must NOT run mo — it must
    // short-circuit to a blocked result (no deletion attempted).
    func testClean_confirmWithoutOptIn_isBlockedNotRun() throws {
        let prior = Store.mcpActionsEnabled
        Store.mcpActionsEnabled = false
        defer { Store.mcpActionsEnabled = prior }

        let json = try catalog.call(name: "burrow_clean", arguments: ["confirm": true])
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["blocked"] as? Bool, true)
        XCTAssertEqual(obj["ran"] as? Bool, false)
        XCTAssertNotNil(obj["reason"] as? String)
    }

    // uninstall is meaningless without a target — reject early, before mo.
    func testUninstall_withoutApps_throwsBadArguments() {
        XCTAssertThrowsError(try catalog.call(name: "burrow_uninstall", arguments: [:])) { err in
            guard case MCPToolError.badArguments = err else {
                return XCTFail("expected .badArguments, got \(err)")
            }
        }
    }

    func testStripANSI_removesColorCodes() {
        let colored = "\u{1B}[1;35mMole Purge\u{1B}[0m done"
        XCTAssertEqual(ToolCatalog.stripANSI(colored), "Mole Purge done")
    }

    func testCallUnknownTool_throwsUnknown() {
        XCTAssertThrowsError(try catalog.call(name: "no_such_tool", arguments: [:])) { err in
            guard case MCPToolError.unknown(let name) = err else {
                return XCTFail("expected .unknown, got \(err)")
            }
            XCTAssertEqual(name, "no_such_tool")
        }
    }

    // MARK: - Helpers

    /// Pull the ordered process names out of a burrow_process_usage result.
    private func names(from json: String) throws -> [String] {
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let procs = try XCTUnwrap(obj["processes"] as? [[String: Any]])
        return procs.compactMap { $0["name"] as? String }
    }

    /// A snapshot whose `top_processes` is the given (name, cpu%, mem%) list.
    private func snapshotJSON(_ procs: [(String, Double, Double)]) -> String {
        let entries = procs.enumerated().map { i, p in
            "{ \"pid\": \(i + 1), \"ppid\": 0, \"name\": \"\(p.0)\", \"command\": \"\(p.0)\", \"cpu\": \(p.1), \"memory\": \(p.2) }"
        }.joined(separator: ",")
        return """
        {
          "collected_at": "2026-05-31T12:00:00.000000-07:00",
          "host": "test", "platform": "darwin", "uptime": "1h 0m",
          "uptime_seconds": 3600, "procs": 100,
          "hardware": {
            "model": "Test", "cpu_model": "Test", "total_ram": "16GB",
            "disk_size": "512GB", "os_version": "14.5", "refresh_rate": "60Hz"
          },
          "health_score": 80, "health_score_msg": "ok",
          "cpu": { "usage": 10.0, "load1": 1.0, "load5": 1.0, "load15": 1.0, "core_count": 8, "logical_cpu": 8 },
          "memory": { "used": 1000, "total": 16000, "used_percent": 50.0, "swap_used": 0, "swap_total": 0, "pressure": "normal" },
          "disk_io": { "read_rate": 1.0, "write_rate": 2.0 },
          "top_processes": [\(entries)]
        }
        """
    }

    /// Minimal valid Mole snapshot JSON. Includes only what the
    /// callers we test actually decode (top_processes for the
    /// aggregation test, the rest are structurally required by the
    /// Codable struct).
    private func sampleSnapshot(cpu: Double) -> String {
        return """
        {
          "collected_at": "2026-05-31T12:00:00.000000-07:00",
          "host": "test",
          "platform": "darwin",
          "uptime": "1h 0m",
          "uptime_seconds": 3600,
          "procs": 100,
          "hardware": {
            "model": "Test", "cpu_model": "Test", "total_ram": "16GB",
            "disk_size": "512GB", "os_version": "14.5", "refresh_rate": "60Hz"
          },
          "health_score": 80,
          "health_score_msg": "ok",
          "cpu": {
            "usage": \(cpu), "load1": 1.0, "load5": 1.0, "load15": 1.0,
            "core_count": 8, "logical_cpu": 8
          },
          "memory": {
            "used": 1000, "total": 16000, "used_percent": 50.0,
            "swap_used": 0, "swap_total": 0, "pressure": "normal"
          },
          "disk_io": { "read_rate": 1.0, "write_rate": 2.0 },
          "top_processes": [
            { "pid": 1, "ppid": 0, "name": "kernel_task", "command": "kernel", "cpu": \(cpu), "memory": 10.0 }
          ]
        }
        """
    }
}
