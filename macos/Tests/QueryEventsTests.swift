//
//  QueryEventsTests.swift
//  BurrowTests
//
//  The SSE /events stream shares the query server's HTTP bearer gate. The
//  streaming socket stays thin; these tests exercise the request boundary.
//

import XCTest
@testable import Burrow

final class QueryEventsTests: XCTestCase {
    func testEventsRejectsCredentialInQueryString() throws {
        let request = "GET /events?token=abc123 HTTP/1.1\r\nHost: 127.0.0.1:9277\r\n\r\n"
        XCTAssertEqual(QueryServer.authorize(request, token: "abc123", port: 9277), .unauthorized)
    }

    func testEventsAcceptsBearerHeaderFromLocalClient() throws {
        let request = "GET /events HTTP/1.1\r\nHost: localhost:9277\r\nAuthorization: Bearer abc123\r\n\r\n"
        XCTAssertEqual(QueryServer.authorize(request, token: "abc123", port: 9277), .allowed)
    }

    func testEventsRejectsBrowserRequestEvenWithCredential() throws {
        let request = "GET /events HTTP/1.1\r\nHost: localhost:9277\r\nAuthorization: Bearer abc123\r\nOrigin: http://localhost:3000\r\n\r\n"
        XCTAssertEqual(QueryServer.authorize(request, token: "abc123", port: 9277), .forbidden)
    }
}
