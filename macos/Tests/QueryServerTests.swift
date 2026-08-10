//
//  QueryServerTests.swift
//  BurrowTests
//
//  The query server parses untrusted bytes from any local process, so the
//  policy layer is tested as pure functions: route() against a seeded DB,
//  nextAction() for the receive loop, httpHead() for the response shape.
//  No sockets — the NWListener plumbing stays thin and untested.
//

import XCTest
@testable import Burrow

final class QueryServerTests: XCTestCase {
    private let token = "test-only-query-credential"
    private var tempDir: URL!
    private var db: DB!
    private var server: QueryServer!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-qs-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try DB(at: tempDir.appendingPathComponent("burrow.db"))
        server = QueryServer(db: db, port: 9277, authToken: token)
    }

    override func tearDown() {
        server = nil
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Response head

    // Audit C2: the server speaks to localhost, but the user's browser also
    // runs on localhost — a CORS allow-all header would let any web page
    // read /snapshot (hostname, process command lines) cross-origin. The
    // response must not opt out of the browser's same-origin protection.
    func testResponseHead_doesNotAllowCrossOriginReads() {
        let head = QueryServer.httpHead(contentLength: 2)
        XCTAssertFalse(head.contains("Access-Control-Allow-Origin"),
                       "loopback API must not grant cross-origin reads to web pages")
    }

    func testResponseHead_isWellFormedHTTP() {
        let head = QueryServer.httpHead(contentLength: 5)
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(head.contains("Content-Length: 5\r\n"))
        XCTAssertTrue(head.contains("Connection: close\r\n"))
        XCTAssertTrue(head.hasSuffix("\r\n\r\n"), "head must end with the blank line separator")
    }

    // MARK: - Receive-loop policy

    func testNextAction_completeHeaderResponds() {
        let req = Data("GET /health HTTP/1.1\r\nHost: x\r\n\r\n".utf8)
        XCTAssertEqual(QueryServer.nextAction(buffer: req, isComplete: false),
                       .respond("GET /health HTTP/1.1\r\nHost: x\r\n\r\n"))
    }

    func testNextAction_partialHeaderKeepsReading() {
        let req = Data("GET /health HT".utf8)
        XCTAssertEqual(QueryServer.nextAction(buffer: req, isComplete: false), .keepReading)
    }

    func testNextAction_eofRespondsWithWhatArrived() {
        let req = Data("GET /health HTTP/1.1".utf8)
        XCTAssertEqual(QueryServer.nextAction(buffer: req, isComplete: true),
                       .respond("GET /health HTTP/1.1"))
    }

    // Audit C2: a client streaming garbage without a header terminator must
    // not grow the buffer without bound — drop it once past any plausible
    // request size.
    func testNextAction_dropsRunawayRequest() {
        let runaway = Data(repeating: UInt8(ascii: "A"), count: 64 * 1024 + 1)
        XCTAssertEqual(QueryServer.nextAction(buffer: runaway, isComplete: false), .drop,
                       "unterminated requests past the size cap must be dropped")
    }

    // MARK: - Routing

    private func request(_ target: String,
                         method: String = "GET",
                         host: String? = "127.0.0.1:9277",
                         credential: String? = nil,
                         omitCredential: Bool = false,
                         extraHeaders: [String] = []) -> String {
        var lines = ["\(method) \(target) HTTP/1.1"]
        if let host { lines.append("Host: \(host)") }
        // nil means "the valid token", derived from the one symbol rather than
        // a second copy of the literal that could drift out of step with it.
        // Sending NO Authorization header is now spelled omitCredential: true.
        if !omitCredential { lines.append("Authorization: Bearer \(credential ?? token)") }
        lines.append(contentsOf: extraHeaders)
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    func testRoute_requiresValidBearerCredential() {
        let missing = server.route(request("/health", omitCredential: true))
        XCTAssertEqual(missing.statusCode, 401)
        XCTAssertFalse(missing.body.contains("\"ok\":true"))

        let wrong = server.route(request("/health", credential: "wrong"))
        XCTAssertEqual(wrong.statusCode, 401)

        let queryStringLeak = server.route(request("/health?token=\(token)", omitCredential: true))
        XCTAssertEqual(queryStringLeak.statusCode, 401,
                       "credentials in URLs must not bypass the Authorization header gate")

        XCTAssertEqual(server.route(request("/health")).statusCode, 200)
    }

    func testRoute_rejectsDNSRebindingAndBrowserOrigins() {
        XCTAssertEqual(server.route(request("/snapshot", host: "attacker.example")).statusCode, 403)
        XCTAssertEqual(server.route(request("/snapshot", host: nil)).statusCode, 403)
        XCTAssertEqual(server.route(request("/snapshot", extraHeaders: ["Origin: https://attacker.example"])).statusCode, 403)
        XCTAssertEqual(server.route(request("/snapshot", extraHeaders: ["Origin: null"])).statusCode, 403)
        XCTAssertEqual(server.route(request("/snapshot", extraHeaders: ["Sec-Fetch-Site: cross-site"])).statusCode, 403)
    }

    func testRoute_constrainsMethodAndRequestBody() {
        XCTAssertEqual(server.route(request("/health", method: "POST",
                                            extraHeaders: ["Content-Type: application/json", "Content-Length: 2"]) + "{}").statusCode,
                       405)
        XCTAssertEqual(server.route(request("/health", extraHeaders: ["Content-Length: 2"]) + "{}").statusCode,
                       400)
        XCTAssertEqual(server.route(request("/health", extraHeaders: ["Transfer-Encoding: chunked"])).statusCode,
                       400)
    }

    func testRoute_rateLimitsAuthenticatedClients() {
        let limited = QueryServer(db: db, port: 9277, authToken: token,
                                  rateLimiter: QueryRateLimiter(limit: 2, window: 60))
        XCTAssertEqual(limited.route(request("/health")).statusCode, 200)
        XCTAssertEqual(limited.route(request("/health")).statusCode, 200)
        XCTAssertEqual(limited.route(request("/health")).statusCode, 429)
    }

    func testRoute_health() {
        let res = server.route(request("/health"))
        XCTAssertTrue(res.body.contains("\"ok\":true"))
        XCTAssertTrue(res.body.contains("9277"))
        XCTAssertEqual(res.contentType, QueryServer.jsonContentType)
    }

    func testRoute_rejectsNonGET() {
        let res = server.route(request("/health", method: "POST"))
        XCTAssertTrue(res.body.contains("error"))
        XCTAssertTrue(res.body.contains("only GET"))
        XCTAssertEqual(res.statusCode, 405)
    }

    func testRoute_unknownPathIsError() {
        let res = server.route(request("/admin"))
        XCTAssertTrue(res.body.contains("unknown route"))
        XCTAssertEqual(res.statusCode, 404)
    }

    func testRoute_malformedRequestIsError() {
        XCTAssertTrue(server.route("").body.contains("error"))
        XCTAssertTrue(server.route("\r\n\r\n").body.contains("error"))
        XCTAssertEqual(server.route("").statusCode, 400)
    }

    func testRoute_snapshotReturnsLatestSeededRow() throws {
        let now = Int(Date().timeIntervalSince1970)
        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: now - 60, json: "{\"old\":true}")
        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: now, json: "{\"new\":true}")
        let res = server.route(request("/snapshot"))
        XCTAssertTrue(res.body.contains("\"new\":true"), "should embed the most recent row verbatim")
        XCTAssertFalse(res.body.contains("\"old\":true"))
        XCTAssertTrue(res.body.contains("\"ts\":\(now)"))
    }

    func testRoute_snapshotWithEmptyDBIsError() {
        let res = server.route(request("/snapshot"))
        XCTAssertTrue(res.body.contains("no snapshot yet"))
    }

    func testRoute_metricsRequiresPrefix() {
        let res = server.route(request("/metrics"))
        XCTAssertTrue(res.body.contains("missing 'prefix'"))
    }

    func testRoute_metricsReturnsSeededRange() throws {
        let now = Int(Date().timeIntervalSince1970)
        try db.insert(prefix: "cpu", ts: now - 10, json: "{\"v\":1}")
        try db.insert(prefix: "cpu", ts: now - 5, json: "{\"v\":2}")
        try db.insert(prefix: "other", ts: now - 5, json: "{\"v\":9}")
        let res = server.route(request("/metrics?prefix=cpu&since=0&until=\(now + 1)"))
        XCTAssertTrue(res.body.contains("{\"v\":1}"))
        XCTAssertTrue(res.body.contains("{\"v\":2}"))
        XCTAssertFalse(res.body.contains("{\"v\":9}"), "other prefixes must not bleed into the slice")
    }

    // Roadmap B7: `/metrics?format=prometheus` renders the latest snapshot as
    // Prometheus text exposition, served with the text/plain scrape
    // content-type (not JSON) so a real scraper accepts it.
    func testRoute_metricsPrometheusRendersLatestSnapshot() throws {
        let now = Int(Date().timeIntervalSince1970)
        let snap = """
        {"collected_at":"2026-06-08T03:16:25.068057-07:00","host":"h","platform":"darwin","uptime_seconds":100,"procs":1,
         "hardware":{"model":"Mac","cpu_model":"M","total_ram":"24 GB","disk_size":"460 GB","os_version":"26"},
         "health_score":90,"health_score_msg":"Good",
         "cpu":{"usage":42,"load1":1.5,"load5":1,"load15":1,"core_count":10,"logical_cpu":10},
         "memory":{"used":100,"total":200,"used_percent":50,"swap_used":0,"swap_total":0,"pressure":""},
         "disk_io":{"read_rate":0,"write_rate":0},"top_processes":[]}
        """
        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: now, json: snap)
        let res = server.route(request("/metrics?format=prometheus"))
        XCTAssertEqual(res.contentType, QueryServer.prometheusContentType)
        XCTAssertTrue(res.body.contains("\nburrow_cpu_usage_percent 42\n"), res.body)
        XCTAssertTrue(res.body.contains("# TYPE burrow_health_score gauge"), res.body)
    }

    func testRoute_metricsPrometheusWithEmptyDBYieldsComment() {
        let res = server.route(request("/metrics?format=prometheus"))
        XCTAssertEqual(res.contentType, QueryServer.prometheusContentType)
        XCTAssertTrue(res.body.hasPrefix("#"), "scrapers tolerate an empty target; emit a comment, not error JSON")
    }

    // Drift counters ride along on /info so a blank chart always has a
    // visible cause an agent (or curl) can see.
    func testRoute_infoSurfacesDriftCounters() throws {
        MetricsStore.resetDriftCounters()
        let clean = server.route(request("/info"))
        let cleanObj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(clean.body.utf8)) as? [String: Any])
        XCTAssertEqual(cleanObj["decode_skipped_total"] as? Int, 0)
        XCTAssertTrue(cleanObj["last_drift"] is NSNull, "no drift yet → explicit null")

        let now = Int(Date().timeIntervalSince1970)
        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: now, json: "not valid json")
        _ = MetricsStore(db: db).snapshots(.init(since: 0, until: now + 1))

        let drifted = server.route(request("/info"))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(drifted.body.utf8)) as? [String: Any])
        XCTAssertEqual(obj["decode_skipped_total"] as? Int, 1)
        let last = try XCTUnwrap(obj["last_drift"] as? [String: Any])
        XCTAssertEqual(last["ts"] as? Int, now)
        XCTAssertNotNil(last["message"] as? String)
    }
}
