//
//  ExplainTests.swift
//  BurrowTests
//
//  The Explain lens splits into pure pieces (context, prompt, parse) and
//  one network seam (ExplainProvider). These tests pin the pure pieces
//  and drive the whole engine with a fake provider — no model required.
//

import XCTest
@testable import Burrow

final class ExplainTests: XCTestCase {
    private var tempDir: URL!
    private var db: DB!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-explain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try DB(at: tempDir.appendingPathComponent("burrow.db"))
    }

    override func tearDown() {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Context

    func testContextBuild_nilWhenNoSnapshot() {
        XCTAssertNil(ExplainContext.build(db: db))
    }

    func testContextBuild_extractsFactsAndTopProcesses() throws {
        let now = Int(Date().timeIntervalSince1970)
        try db.insert(prefix: Sampler.snapshotPrefix, ts: now, json: snapshot())
        let ctx = try XCTUnwrap(ExplainContext.build(db: db))
        XCTAssertEqual(ctx.healthScore, 80)
        XCTAssertEqual(ctx.cpuUsage, 91.0, accuracy: 0.001)
        XCTAssertEqual(ctx.topProcesses.first?.name, "hot", "top process is the highest-CPU one")
        XCTAssertTrue(ctx.factSheet.contains("health_score"))
        XCTAssertTrue(ctx.factSheet.contains("hot"))
    }

    func testContextBuild_includesRecentTrendFromHistory() throws {
        let now = Int(Date().timeIntervalSince1970)
        // Two snapshots in the window so the summary has something to average.
        try db.insert(prefix: Sampler.snapshotPrefix, ts: now - 120, json: snapshot())
        try db.insert(prefix: Sampler.snapshotPrefix, ts: now, json: snapshot())
        let ctx = try XCTUnwrap(ExplainContext.build(db: db))
        XCTAssertEqual(ctx.cpuPeak, 91.0, accuracy: 0.001, "window peak comes from the snapshots")
        XCTAssertTrue(ctx.factSheet.contains("last_60min_cpu"), "fact sheet carries the trend")
    }

    // MARK: - Parse

    func testParse_extractsActionAndStripsDirective() {
        let r = ExplainResult.parse("CPU is busy indexing. Safe to ignore.\nACTION: clean")
        XCTAssertEqual(r.suggestion, .clean)
        XCTAssertFalse(r.explanation.contains("ACTION:"), "the directive line is stripped")
        XCTAssertTrue(r.explanation.contains("indexing"))
    }

    func testParse_noneMeansNoSuggestion() {
        XCTAssertNil(ExplainResult.parse("Everything looks healthy.\nACTION: none").suggestion)
    }

    func testParse_toleratesMissingAction() {
        let r = ExplainResult.parse("Just an explanation, no directive.")
        XCTAssertNil(r.suggestion)
        XCTAssertEqual(r.explanation, "Just an explanation, no directive.")
    }

    // MARK: - Prompt

    func testPrompt_embedsFactsAndAsksForActionLine() throws {
        let now = Int(Date().timeIntervalSince1970)
        try db.insert(prefix: Sampler.snapshotPrefix, ts: now, json: snapshot())
        let ctx = try XCTUnwrap(ExplainContext.build(db: db))
        let (system, user) = ExplainPrompt.make(ctx)
        XCTAssertTrue(system.contains("ACTION:"), "model is instructed to emit an action line")
        XCTAssertTrue(user.contains("health_score"))
    }

    // MARK: - Ollama request shape

    func testOllamaRequest_postsChatWithMessages() throws {
        let req = try OllamaProvider.makeRequest(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            model: "llama3.2", system: "sys", user: "usr")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/api/chat")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "llama3.2")
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
    }

    // MARK: - OpenAI-compatible (LM Studio) request shape

    func testOpenAIEndpoint_normalizesBaseURL() {
        // Whatever form the user types, we resolve to /v1/chat/completions.
        XCTAssertEqual(OpenAICompatibleProvider.endpoint(from: "http://127.0.0.1:1234/v1")?.absoluteString,
                       "http://127.0.0.1:1234/v1/chat/completions")
        XCTAssertEqual(OpenAICompatibleProvider.endpoint(from: "http://127.0.0.1:1234/v1/")?.absoluteString,
                       "http://127.0.0.1:1234/v1/chat/completions", "trailing slash tolerated")
        XCTAssertEqual(OpenAICompatibleProvider.endpoint(from: "https://api.openai.com")?.absoluteString,
                       "https://api.openai.com/v1/chat/completions", "bare host gets /v1 added")
        XCTAssertEqual(OpenAICompatibleProvider.endpoint(from: "http://h/v1/chat/completions")?.absoluteString,
                       "http://h/v1/chat/completions", "already-complete URL is left alone")
    }

    func testOpenAIRequest_postsChatCompletionsWithAuthWhenKeyed() throws {
        let req = try OpenAICompatibleProvider.makeRequest(
            baseURL: "http://127.0.0.1:1234/v1", model: "local-model",
            apiKey: "sk-test", system: "sys", user: "usr")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/v1/chat/completions")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "local-model")
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
    }

    func testOpenAIRequest_omitsAuthHeaderWhenKeyBlank() throws {
        // LM Studio and most local servers don't want an Authorization header.
        let req = try OpenAICompatibleProvider.makeRequest(
            baseURL: "http://127.0.0.1:1234/v1", model: "local-model",
            apiKey: "", system: "sys", user: "usr")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: - Engine end-to-end (fake provider)

    func testEngine_parsesProviderReplyIntoActionableResult() async throws {
        let now = Int(Date().timeIntervalSince1970)
        try db.insert(prefix: Sampler.snapshotPrefix, ts: now, json: snapshot())
        let engine = ExplainEngine(provider: FakeProvider(reply: "Disk is nearly full.\nACTION: clean"))
        let result = try await engine.explain(db: db)
        XCTAssertEqual(result.suggestion, .clean)
        XCTAssertEqual(result.suggestion?.pane, .tool(.clean))
        XCTAssertTrue(result.explanation.contains("Disk"))
    }

    func testEngine_throwsWhenNoSnapshot() async {
        let engine = ExplainEngine(provider: FakeProvider(reply: "x"))
        do {
            _ = try await engine.explain(db: db)
            XCTFail("expected noData")
        } catch ExplainError.noData {
            // expected
        } catch {
            XCTFail("expected .noData, got \(error)")
        }
    }

    // MARK: - Helpers

    private struct FakeProvider: ExplainProvider {
        let reply: String
        func complete(system: String, user: String) async throws -> String { reply }
    }

    /// Snapshot with a clear top process ("hot" at 91% CPU).
    private func snapshot() -> String {
        return """
        {
          "collected_at": "2026-05-31T12:00:00.000000-07:00",
          "host": "test", "platform": "darwin", "uptime": "1h", "uptime_seconds": 3600, "procs": 100,
          "hardware": { "model": "T", "cpu_model": "T", "total_ram": "16GB", "disk_size": "512GB", "os_version": "14.5", "refresh_rate": "60Hz" },
          "health_score": 80, "health_score_msg": "ok",
          "cpu": { "usage": 91.0, "load1": 1.0, "load5": 1.0, "load15": 1.0, "core_count": 8, "logical_cpu": 8 },
          "memory": { "used": 8000, "total": 16000, "used_percent": 70.0, "swap_used": 0, "swap_total": 0, "pressure": "warning" },
          "disk_io": { "read_rate": 1.0, "write_rate": 2.0 },
          "disks": [ { "mount": "/", "used": 480, "total": 512, "used_percent": 94.0, "external": false } ],
          "top_processes": [
            { "pid": 1, "ppid": 0, "name": "idle", "command": "x", "cpu": 2.0, "memory": 1.0 },
            { "pid": 2, "ppid": 0, "name": "hot", "command": "x", "cpu": 91.0, "memory": 30.0 }
          ]
        }
        """
    }
}
