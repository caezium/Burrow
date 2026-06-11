//
//  MCPEnvelopeTests.swift
//  BurrowTests
//
//  The JSON-RPC envelope is the surface every agent speaks to: framing
//  errors, the notification-silence rule, and the error-code mapping.
//  MCPTests covers the tool catalog one layer below; these pin the
//  envelope itself via MCPServer.response(toLine:) — no FileHandles.
//

import XCTest
@testable import Burrow

final class MCPEnvelopeTests: XCTestCase {
    private var tempDir: URL!
    private var server: MCPServer!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-envelope-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        server = MCPServer(db: try DB(at: tempDir.appendingPathComponent("burrow.db")))
    }

    override func tearDown() {
        server = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func respond(_ json: String) -> [String: Any]? {
        server.response(toLine: Data(json.utf8))
    }

    private func errorCode(_ response: [String: Any]?) -> Int? {
        (response?["error"] as? [String: Any])?["code"] as? Int
    }

    func testGarbageLine_isParseError32700() {
        XCTAssertEqual(errorCode(respond("not json at all")), -32700)
    }

    func testInitializedNotification_getsNoReply() {
        XCTAssertNil(respond(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#),
                     "replying to a notification is malformed JSON-RPC")
    }

    func testUnknownMethodNotification_getsNoReply() {
        XCTAssertNil(respond(#"{"jsonrpc":"2.0","method":"something/else"}"#))
    }

    func testUnknownMethodRequest_is32601() {
        let r = respond(#"{"jsonrpc":"2.0","id":7,"method":"nope"}"#)
        XCTAssertEqual(errorCode(r), -32601)
        XCTAssertEqual(r?["id"] as? Int, 7, "the error must echo the request id")
    }

    func testInitialize_announcesProtocolAndServer() throws {
        let r = try XCTUnwrap(respond(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#))
        let result = try XCTUnwrap(r["result"] as? [String: Any])
        XCTAssertNotNil(result["protocolVersion"] as? String)
        let info = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(info["name"] as? String, "burrow")
    }

    func testToolsList_returnsTheCatalog() throws {
        let r = try XCTUnwrap(respond(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        let result = try XCTUnwrap(r["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertTrue(tools.contains { ($0["name"] as? String) == "burrow_snapshot" })
    }

    func testToolsCall_unknownToolIs32602() {
        let r = respond(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"burrow_nope"}}"#)
        XCTAssertEqual(errorCode(r), -32602)
    }

    func testToolsCall_badArgumentsIs32602() {
        let r = respond(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"burrow_history","arguments":{"minutes":0}}}"#)
        XCTAssertEqual(errorCode(r), -32602)
    }
}
