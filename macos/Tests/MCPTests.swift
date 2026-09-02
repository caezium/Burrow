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

    /// A tool description is the only thing an agent has to go on, so it has to describe what the
    /// tool DOES — and this one's answer has now changed twice. It used to be told to say
    /// "DOES NOT UNINSTALL THE APPLICATION", which was true while the engine removed only
    /// `~/Library` leftovers and is false since burrow-engine @ df9ea3f removed the bundle too.
    /// What an agent must be able to read off it now: the app really goes, where it goes, that
    /// Homebrew is a different mechanism with an unbounded `--zap`, that outcomes are per app, and
    /// that identifiers are bundle ids — display names are not unique on a real machine (three
    /// `Restarter`s, two `Steam`s in a 135-app inventory).
    func testUninstallDescriptor_saysTheAppIsRemovedWhereItGoesAndAsksForABundleId() throws {
        let tool = try XCTUnwrap(catalog.descriptors().first { $0["name"] as? String == "burrow_uninstall" })
        let description = try XCTUnwrap(tool["description"] as? String)
        XCTAssertFalse(description.contains("DOES NOT UNINSTALL THE APPLICATION"),
                       "the engine removes the .app now — that warning is the false claim: \(description)")
        XCTAssertTrue(description.contains("the .app bundle itself"), description)
        XCTAssertTrue(description.contains("move to the Trash"),
                      "where the app goes is the thing a user is told afterwards: \(description)")
        XCTAssertTrue(description.contains("permanent"), description)
        XCTAssertTrue(description.contains("brew uninstall --cask --zap"),
                      "the --zap is the part that removes bytes no preview can list: \(description)")
        XCTAssertTrue(description.contains("partial"),
                      "an agent must know a run can half-succeed per app: \(description)")
        XCTAssertTrue(description.contains("bundle_id"),
                      "an agent must be told which identifier to send: \(description)")

        let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let apps = try XCTUnwrap(properties["apps"] as? [String: Any])
        XCTAssertTrue(try XCTUnwrap(apps["description"] as? String).contains("bundle_id"))
        let permanent = try XCTUnwrap(properties["permanent"] as? [String: Any])
        XCTAssertTrue(try XCTUnwrap(permanent["description"] as? String).contains("Trash"),
                      "the flag's description has to say what it bypasses")
    }

    /// `burrow_list_apps` is where an agent is told to get that identifier, so it has to name the
    /// fields it returns, warn about the `"unknown"` rows that cannot be targeted at all, and flag
    /// the Homebrew rows — those are the ones for which "it's in the Trash" is not true.
    func testListAppsDescriptor_pointsAtBundleIdAndFlagsTheUnknownAndHomebrewRows() throws {
        let tool = try XCTUnwrap(catalog.descriptors().first { $0["name"] as? String == "burrow_list_apps" })
        let description = try XCTUnwrap(tool["description"] as? String)
        XCTAssertTrue(description.contains("bundle_id"), description)
        XCTAssertTrue(description.contains("not unique"), description)
        XCTAssertTrue(description.contains("unknown"), description)
        XCTAssertTrue(description.contains("Homebrew"), description)
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
                        "burrow_slim_check", "burrow_agent_audit", "burrow_anomalies",
                        "burrow_evict", "burrow_clean",
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
        let json = ToolCatalog.cleanupHistoryResult(Captured(stdout: "", stderr: "", exitCode: 127))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertNotNil(obj["error"])
        XCTAssertEqual(obj["sessions"] as? [Any] != nil, true)
    }

    func testCleanupHistory_moPresent_passesThroughItsJSON() throws {
        let molesJSON = #"{"sessions":[{"command":"clean","size":"1MB"}]}"#
        let json = ToolCatalog.cleanupHistoryResult(Captured(stdout: "  \(molesJSON)\n", stderr: "", exitCode: 0))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let sessions = try XCTUnwrap(obj["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.first?["command"] as? String, "clean")
        XCTAssertNil(obj["error"], "a successful run must not carry an error marker")
    }

    func testCleanupHistory_moPresentButEmpty_yieldsEmptySessions() throws {
        let json = ToolCatalog.cleanupHistoryResult(Captured(stdout: "   \n", stderr: "", exitCode: 0))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual((obj["sessions"] as? [Any])?.count, 0)
    }

    // MARK: - Envelope unwrapping (the bundled engine ALWAYS wraps `history --json`; passing that
    // straight through used to hand an agent the WRONG SHAPE — an envelope where this tool has
    // always promised the bare `{"sessions":[…]}` contract). Fixture captured verbatim from
    // `burrow-engine history --json --limit 2` (0.1.0) — shape matches this repo's own
    // `history.golden.json` (logs/limit/sessions/deletions under `data`).

    func testCleanupHistory_realEngineEnvelope_unwrapsSessionsToTopLevel() throws {
        let envelope = #"{"ok":true,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"history","data":{"logs":{"operations":"/Users/henry/Library/Logs/mole/operations.log","deletions":"/Users/henry/Library/Logs/mole/deletions.log"},"limit":2,"sessions":[{"command":"optimize","started_at":"2026-07-25 08:27:26","ended_at":"2026-07-25 08:27:30","items":22,"size":"0B","operation_count":0,"actions":{"removed":0,"trashed":0,"skipped":0,"failed":0,"rebuilt":0,"other":0}},{"command":"clean","started_at":"2026-07-25 08:25:50","ended_at":"2026-07-25 08:27:25","items":647,"size":"585.5MB","operation_count":162,"actions":{"removed":0,"trashed":0,"skipped":162,"failed":0,"rebuilt":0,"other":0}}],"deletions":[]}}"#
        let json = ToolCatalog.cleanupHistoryResult(Captured(stdout: envelope, stderr: "", exitCode: 0))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertNil(obj["ok"], "must be unwrapped, not the raw envelope")
        XCTAssertNil(obj["data"], "sessions belongs at the top level, not nested under data")
        let sessions = try XCTUnwrap(obj["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.first?["command"] as? String, "optimize")
        // A bonus over the bare pre-repoint contract, not a requirement — but must survive.
        XCTAssertNotNil(obj["logs"])
    }

    func testCleanupHistory_engineErrorEnvelope_yieldsErrorObjectNotThePassthroughEnvelope() throws {
        let envelope = #"{"ok":false,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"history","error":{"kind":"error","message":"boom","platform":"macos"}}"#
        let json = ToolCatalog.cleanupHistoryResult(Captured(stdout: envelope, stderr: "", exitCode: 0))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["error"] as? String, "boom")
        XCTAssertEqual((obj["sessions"] as? [Any])?.count, 0)
    }

    // MARK: - burrow_uninstall's `apps[]`: what an agent may put on a deleting argv
    //
    // This surface honours `permanent: true` (`MoActions.argv`), so a value that resolves to the
    // wrong application here is an outright delete of it — no Trash, nothing to put back. The GUI
    // refused three values; this one trimmed whitespace and dropped empties, and the difference
    // was reachable in a single call.

    func testUninstallApps_refusesTheUnknownSentinelBurrowListAppsHandsOut() {
        // Live against the bundled engine at df9ea3f: `uninstall --dry-run unknown` resolves to
        // Synergy — `removes_applications: 1`, `unmatched: []`, `ambiguous: []`, `refusal: null`.
        // Nothing downstream disagreed with itself, because nothing downstream was comparing the
        // request against the application.
        for bad in ["unknown", "UNKNOWN", " unknown "] {
            XCTAssertThrowsError(try ToolCatalog.uninstallApps(["apps": [bad]]),
                                 "\(bad.debugDescription) must not reach argv") { error in
                guard case MCPToolError.badArguments(let message) = error else {
                    return XCTFail("expected badArguments, got \(error)")
                }
                XCTAssertTrue(message.contains("name"), message)
            }
        }
    }

    func testUninstallApps_refusesAFlagShapedArgumentAndAnEmptyList() {
        XCTAssertThrowsError(try ToolCatalog.uninstallApps(["apps": ["-permanent"]]),
                             "a leading `-` is skipped by the engine's positional scan, so the run "
                             + "would act on fewer apps than it reported")
        XCTAssertThrowsError(try ToolCatalog.uninstallApps(["apps": ["   "]]))
        XCTAssertThrowsError(try ToolCatalog.uninstallApps([:]))
    }

    func testUninstallApps_stillAcceptsARealBundleIdOrAnAppsOwnName() throws {
        XCTAssertEqual(try ToolCatalog.uninstallApps(["apps": [" eu.exelban.Stats ", "Synergy"]]),
                       ["eu.exelban.Stats", "Synergy"],
                       "an app with no CFBundleIdentifier is still removable — by its name")
    }

    // MARK: - A partial uninstall is not "didn't run"
    //
    // Real capture, `burrow-engine uninstall --apply --permanent` over TWO purpose-built scratch
    // bundles under a temporary `$HOME` — one whose path a protection rail declines, one ordinary.
    // No installed application was passed to `--apply`. It exits **1** with an **`ok:true`**
    // envelope (`i32::from(failed)`), having deleted one of the two applications.
    private static let applyPartialAcrossApps = #"{"ok":true,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"uninstall","data":{"dry_run":false,"freed_bytes":399,"freed_human":"399B","applications_removed":1,"applications_refused":1,"warnings":[],"removed":[{"path":"/private/tmp/claude-501/-Users-henry-Desktop-Burrow/447eac01-68b0-4709-9b47-4353173bbf3b/scratchpad/fakehome/Applications/BurrowScratchOK.app","size":388,"bundle_id":"dev.caezium.burrow.scratch.ok","kind":"application"},{"path":"/private/tmp/claude-501/-Users-henry-Desktop-Burrow/447eac01-68b0-4709-9b47-4353173bbf3b/scratchpad/fakehome/Library/Application Support/dev.caezium.burrow.scratch.ok","size":5,"bundle_id":"dev.caezium.burrow.scratch.ok","kind":"leftover"},{"path":"/private/tmp/claude-501/-Users-henry-Desktop-Burrow/447eac01-68b0-4709-9b47-4353173bbf3b/scratchpad/fakehome/Library/Caches/dev.caezium.burrow.scratch.ok","size":6,"bundle_id":"dev.caezium.burrow.scratch.ok","kind":"leftover"}],"errors":[{"path":"/private/tmp/claude-501/-Users-henry-Desktop-Burrow/447eac01-68b0-4709-9b47-4353173bbf3b/scratchpad/fakehome/Applications/BurrowScratchControlCenter.app","error":"protected path skipped: /private/tmp/claude-501/-Users-henry-Desktop-Burrow/447eac01-68b0-4709-9b47-4353173bbf3b/scratchpad/fakehome/Applications/BurrowScratchControlCenter.app","bundle_id":"dev.caezium.burrow.scratch.refused","kind":"application"}],"protected":["/private/tmp/claude-501/-Users-henry-Desktop-Burrow/447eac01-68b0-4709-9b47-4353173bbf3b/scratchpad/fakehome/Applications/BurrowScratchControlCenter.app"],"apps":[{"query":"dev.caezium.burrow.scratch.refused","name":"BurrowScratchControlCenter","bundle_id":"dev.caezium.burrow.scratch.refused","path":"/private/tmp/claude-501/-Users-henry-Desktop-Burrow/447eac01-68b0-4709-9b47-4353173bbf3b/scratchpad/fakehome/Applications/BurrowScratchControlCenter.app","status":"refused","application":{"path":"/private/tmp/claude-501/-Users-henry-Desktop-Burrow/447eac01-68b0-4709-9b47-4353173bbf3b/scratchpad/fakehome/Applications/BurrowScratchControlCenter.app","state":"refused","via":null,"bytes":0,"reason":"protected path skipped: /private/tmp/claude-501/-Users-henry-Desktop-Burrow/447eac01-68b0-4709-9b47-4353173bbf3b/scratchpad/fakehome/Applications/BurrowScratchControlCenter.app","suggestion":null},"removed_count":0,"leftover_freed_bytes":0,"error_count":0,"protected_count":0,"freed_bytes":0,"freed_human":"0B","leftovers_attempted":false},{"query":"dev.caezium.burrow.scratch.ok","name":"BurrowScratchOK","bundle_id":"dev.caezium.burrow.scratch.ok","path":"/private/tmp/claude-501/-Users-henry-Desktop-Burrow/447eac01-68b0-4709-9b47-4353173bbf3b/scratchpad/fakehome/Applications/BurrowScratchOK.app","status":"removed","application":{"path":"/private/tmp/claude-501/-Users-henry-Desktop-Burrow/447eac01-68b0-4709-9b47-4353173bbf3b/scratchpad/fakehome/Applications/BurrowScratchOK.app","state":"removed","via":"permanent","bytes":388,"reason":null,"suggestion":null},"removed_count":2,"leftover_freed_bytes":11,"error_count":0,"protected_count":0,"freed_bytes":399,"freed_human":"399B","leftovers_attempted":true}],"unmatched":[]}}"#

    /// `ran` is documented on the wire as a CLAIM about the disk. An application was deleted here,
    /// so the claim is true — and the old rule (`exitCode == 0 && !reportsFailure`) said false,
    /// which is the wrong answer in the direction that matters.
    func testRealRunClaim_aPartialUninstallReportsThatItRan() {
        let claim = ToolCatalog.realRunClaim(Captured(stdout: Self.applyPartialAcrossApps, stderr: "", exitCode: 1))
        XCTAssertFalse(BurrowEnvelope.reportsFailure(stdout: Self.applyPartialAcrossApps),
                       "the fixture is the trap: exit 1 over an ok:true envelope")
        XCTAssertTrue(claim.ran, "one of the two applications was deleted")
    }

    /// And the reason string is the engine's own per-app account, not the whole JSON document —
    /// which is what `failureReason`'s raw-stdout fallback returned, because a success envelope
    /// carries no `error.message` for it to classify.
    func testRealRunClaim_reportsThePerAppAccountNotTheEnvelopeItself() throws {
        let claim = ToolCatalog.realRunClaim(Captured(stdout: Self.applyPartialAcrossApps, stderr: "", exitCode: 1))
        let error = try XCTUnwrap(claim.error)
        XCTAssertFalse(error.contains("\"burrow_cli\""),
                       "the error must not be the envelope document: \(error.prefix(120))")
        XCTAssertTrue(error.contains("BurrowScratchControlCenter"), error)
        XCTAssertTrue(error.contains("protected path skipped"), error)
        XCTAssertFalse(error.contains("BurrowScratchOK"),
                       "the app that came away cleanly is not a problem to report: \(error)")
    }

    /// A run the engine refused outright removed nothing, and still says so.
    func testRealRunClaim_aFullyRefusedRunDidNotRun() throws {
        let refusedBoth = Self.applyPartialAcrossApps
            .replacingOccurrences(of: #""applications_removed":1"#, with: #""applications_removed":0"#)
            .replacingOccurrences(of: #""removed_count":2"#, with: #""removed_count":0"#)
            .replacingOccurrences(of: #""status":"removed""#, with: #""status":"refused""#)
        let claim = ToolCatalog.realRunClaim(Captured(stdout: refusedBoth, stderr: "", exitCode: 1))
        XCTAssertFalse(claim.ran)
        XCTAssertNotNil(claim.error)
    }

    /// Nothing about a legacy `mo` or a clean run changes: no envelope to decode, so the exit code
    /// still decides, and a zero exit is still a run.
    func testRealRunClaim_fallsBackToTheExitCodeWhenThereIsNoEngineOutcome() {
        XCTAssertTrue(ToolCatalog.realRunClaim(Captured(stdout: "Removed 1 app", stderr: "", exitCode: 0)).ran)
        XCTAssertFalse(ToolCatalog.realRunClaim(Captured(stdout: "", stderr: "boom", exitCode: 1)).ran)
        XCTAssertEqual(ToolCatalog.realRunClaim(Captured(stdout: "", stderr: "boom", exitCode: 1)).error, "boom")
    }

    // MARK: - Deletions log path (Fix 1, secondary check: `logs` sits under `data` in a real
    // envelope, not at the top level — the pre-fix code read the top level directly and always
    // missed it, silently falling back to the (today accidentally-correct) hardcoded path).

    func testDeletionsLogPath_realEngineEnvelope_readsNestedDataLogs() {
        let envelope = #"{"ok":true,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"history","data":{"logs":{"operations":"/Users/henry/Library/Logs/mole/operations.log","deletions":"/Users/henry/Library/Logs/mole/deletions.log"},"limit":20,"sessions":[],"deletions":[]}}"#
        XCTAssertEqual(ToolCatalog.deletionsLogPath(fromCaptureStdout: envelope),
                       "/Users/henry/Library/Logs/mole/deletions.log")
    }

    func testDeletionsLogPath_legacyTopLevelShape_stillReads() {
        let legacy = #"{"logs":{"operations":"/x/operations.log","deletions":"/x/deletions.log"},"sessions":[]}"#
        XCTAssertEqual(ToolCatalog.deletionsLogPath(fromCaptureStdout: legacy), "/x/deletions.log")
    }

    func testDeletionsLogPath_garbage_returnsNil() {
        XCTAssertNil(ToolCatalog.deletionsLogPath(fromCaptureStdout: "not json"))
        XCTAssertNil(ToolCatalog.deletionsLogPath(fromCaptureStdout: ""))
    }

    // MARK: - burrow_list_apps: an explicit error an agent can act on, never an empty list next
    // to it that reads as "no apps installed" (the engine has no `--list` at all post-repoint).

    func testListApps_engineHasNoListCommand_yieldsExplicitErrorNoAppsKey() throws {
        // `burrow-engine uninstall --list` finds no non-flag arg, so it answers its own "needs an
        // app bundle id" error envelope on STDOUT at exit 1 (never stderr) — captured verbatim.
        let stdout = #"{"ok":false,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"uninstall","error":{"kind":"error","message":"uninstall needs an app bundle id (e.g. com.foo.Bar)","platform":"macos"}}"#
        let json = ToolCatalog.listAppsToolResult(Captured(stdout: stdout, stderr: "", exitCode: 1))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertNotNil(obj["error"], "must surface an explicit error")
        XCTAssertNil(obj["apps"], "must NOT carry an empty apps list next to the error — an agent "
                     + "that reads .apps without checking .error first must not find \"no apps\"")
    }

    func testListApps_moAbsent_yieldsExplicitErrorNoAppsKey() throws {
        let json = ToolCatalog.listAppsToolResult(Captured(stdout: "", stderr: "", exitCode: 127))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertNotNil(obj["error"])
        XCTAssertNil(obj["apps"])
    }

    func testListApps_realList_passesThroughVerbatim() {
        let stdout = #"[{"name":"Slack","bundle_id":"com.tinyspeck.slackmacgap","path":"/Applications/Slack.app","size":"250MB"}]"#
        XCTAssertEqual(ToolCatalog.listAppsToolResult(Captured(stdout: stdout, stderr: "", exitCode: 0)), stdout)
    }

    func testListApps_realListEmptyOutput_yieldsEmptyAppsObject() {
        XCTAssertEqual(ToolCatalog.listAppsToolResult(Captured(stdout: "   ", stderr: "", exitCode: 0)), "{\"apps\":[]}")
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
