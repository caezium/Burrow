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
    private var tempDir: URL!
    private var db: DB!
    private var server: QueryServer!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-qs-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try DB(at: tempDir.appendingPathComponent("burrow.db"))
        server = QueryServer(db: db, port: 9277)
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

    func testRoute_health() {
        let res = server.route("GET /health HTTP/1.1\r\n\r\n")
        XCTAssertTrue(res.contains("\"ok\":true"))
        XCTAssertTrue(res.contains("9277"))
    }

    func testRoute_rejectsNonGET() {
        let res = server.route("POST /health HTTP/1.1\r\n\r\n")
        XCTAssertTrue(res.contains("error"))
        XCTAssertTrue(res.contains("only GET"))
    }

    func testRoute_unknownPathIsError() {
        let res = server.route("GET /admin HTTP/1.1\r\n\r\n")
        XCTAssertTrue(res.contains("unknown route"))
    }

    func testRoute_malformedRequestIsError() {
        XCTAssertTrue(server.route("").contains("error"))
        XCTAssertTrue(server.route("\r\n\r\n").contains("error"))
    }

    func testRoute_snapshotReturnsLatestSeededRow() throws {
        let now = Int(Date().timeIntervalSince1970)
        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: now - 60, json: "{\"old\":true}")
        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: now, json: "{\"new\":true}")
        let res = server.route("GET /snapshot HTTP/1.1\r\n\r\n")
        XCTAssertTrue(res.contains("\"new\":true"), "should embed the most recent row verbatim")
        XCTAssertFalse(res.contains("\"old\":true"))
        XCTAssertTrue(res.contains("\"ts\":\(now)"))
    }

    func testRoute_snapshotWithEmptyDBIsError() {
        let res = server.route("GET /snapshot HTTP/1.1\r\n\r\n")
        XCTAssertTrue(res.contains("no snapshot yet"))
    }

    func testRoute_metricsRequiresPrefix() {
        let res = server.route("GET /metrics HTTP/1.1\r\n\r\n")
        XCTAssertTrue(res.contains("missing 'prefix'"))
    }

    func testRoute_metricsReturnsSeededRange() throws {
        let now = Int(Date().timeIntervalSince1970)
        try db.insert(prefix: "cpu", ts: now - 10, json: "{\"v\":1}")
        try db.insert(prefix: "cpu", ts: now - 5, json: "{\"v\":2}")
        try db.insert(prefix: "other", ts: now - 5, json: "{\"v\":9}")
        let res = server.route("GET /metrics?prefix=cpu&since=0&until=\(now + 1) HTTP/1.1\r\n\r\n")
        XCTAssertTrue(res.contains("{\"v\":1}"))
        XCTAssertTrue(res.contains("{\"v\":2}"))
        XCTAssertFalse(res.contains("{\"v\":9}"), "other prefixes must not bleed into the slice")
    }
}
