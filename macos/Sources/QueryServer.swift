//
//  QueryServer.swift
//  Burrow
//
//  Localhost JSON HTTP server. The MCP server for Claude Code points
//  at this and a curl-from-the-terminal user can hit the same endpoints.
//  Bound to 127.0.0.1 only, double-checks the peer address at accept time,
//  and requires a per-install bearer credential plus an exact local Host.
//  Loopback is reachable by browsers and unrelated local processes, so it is
//  transport scoping rather than an authentication boundary.
//
//  Endpoints:
//    GET /health                    → { ok, app, port }
//    GET /info                      → prefix list + retention + reader-staleness
//    GET /snapshot                  → most recent mole.snapshot row
//    GET /metrics?prefix=...&since=...&until=...&bucket=...
//                                   → time-series slice, optionally bucketed
//
//  Design notes lifted from Stats:
//    * Speaks a tiny subset of HTTP/1.1 — GET only, one request per
//      connection, Connection: close. No external deps.
//    * All payloads are JSON. DB rows already hold JSON strings; we
//      embed them verbatim in responses rather than parse + re-encode.
//

import Foundation
import Network

/// A small global limiter for the loopback surface. Loopback does not mean
/// trusted: every browser and local process can reach it, so bound accepted
/// authenticated work before it reaches SQLite or snapshot decoding.
final class QueryRateLimiter {
    private let limit: Int
    private let window: TimeInterval
    private var acceptedAt: [TimeInterval] = []
    private let lock = NSLock()

    init(limit: Int = 120, window: TimeInterval = 60) {
        self.limit = max(1, limit)
        self.window = max(1, window)
    }

    func allow(at date: Date = Date()) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        let now = date.timeIntervalSince1970
        let cutoff = now - self.window
        self.acceptedAt.removeAll { $0 <= cutoff }
        guard self.acceptedAt.count < self.limit else { return false }
        self.acceptedAt.append(now)
        return true
    }
}

final class QueryServer {
    static let defaultPort: UInt16 = 9277  // Stats's MCP uses 9276; +1 to coexist

    private let db: DB
    private let port: UInt16
    private let authToken: String
    private let rateLimiter: QueryRateLimiter
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "dev.caezium.burrow.queryserver")

    init(db: DB,
         port: UInt16 = QueryServer.defaultPort,
         authToken: String = Store.queryAuthToken,
         rateLimiter: QueryRateLimiter = QueryRateLimiter()) {
        self.db = db
        self.port = port
        self.authToken = authToken
        self.rateLimiter = rateLimiter
    }

    func start() {
        guard self.listener == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: self.port) else {
            NSLog("Burrow.QueryServer: invalid port \(self.port)")
            return
        }

        let params = NWParameters.tcp
        // requiredLocalEndpoint pins us to loopback. If a future macOS
        // change loosens NWParameters defaults this is still safe.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback),
                                                           port: nwPort)

        do {
            let l = try NWListener(using: params)
            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    NSLog("Burrow.QueryServer: listening on 127.0.0.1:\(self.port)")
                case .failed(let e):
                    NSLog("Burrow.QueryServer: failed: \(e)")
                    self.listener = nil
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.start(queue: self.queue)
            self.listener = l
        } catch {
            NSLog("Burrow.QueryServer: start error: \(error)")
        }
    }

    func stop() {
        self.listener?.cancel()
        self.listener = nil
    }

    // MARK: - Connection handling

    private func accept(_ conn: NWConnection) {
        // Belt-and-braces loopback check. Drop any peer that isn't IPv4
        // 127.0.0.0/8 or IPv6 ::1. requiredLocalEndpoint above should
        // make this unreachable but the check is cheap.
        if case .hostPort(let host, _) = conn.endpoint {
            switch host {
            case .ipv4(let v4) where v4.isLoopback: break
            case .ipv6(let v6) where v6.isLoopback: break
            default:
                conn.cancel()
                return
            }
        }
        conn.start(queue: self.queue)
        // A client that connects and never completes a request would
        // otherwise pin its receive chain (and buffer) forever. We serve one
        // request per connection, so any legitimate client is long done
        // inside this window; cancelling an already-closed connection is a
        // no-op.
        self.queue.asyncAfter(deadline: .now() + 10) { [weak conn] in
            guard let conn else { return }
            // SSE /events connections are long-lived; don't idle-cancel them.
            if !EventHub.shared.isStreaming(conn) { conn.cancel() }
        }
        self.receive(conn, accumulated: Data())
    }

    /// What the receive loop should do next, as a pure function of the bytes
    /// accumulated so far. Keeps the policy (when to respond, when to give
    /// up) testable without a socket.
    enum RequestAction: Equatable {
        case respond(String)
        case keepReading
        case drop
    }

    /// No legitimate request head is anywhere near this big; a client still
    /// streaming without the blank-line terminator past this point is broken
    /// or hostile, and the buffer must not grow with it.
    static let maxRequestBytes = 64 * 1024

    static func nextAction(buffer: Data, isComplete: Bool) -> RequestAction {
        if buffer.count > Self.maxRequestBytes { return .drop }
        if let header = String(data: buffer, encoding: .utf8),
           header.contains("\r\n\r\n") || isComplete {
            return .respond(header)
        }
        return isComplete ? .drop : .keepReading
    }

    enum AuthorizationResult: Equatable {
        case allowed
        case unauthorized
        case forbidden
        case malformed
    }

    struct Response {
        let statusCode: Int
        let body: String
        let contentType: String
        var headers: [String] = []
    }

    private struct Request {
        let method: String
        let target: String
        let version: String
        let headers: [String: String]
        let body: String
    }

    /// Parse the intentionally tiny HTTP subset without accepting duplicate
    /// headers or absolute-form targets. Rejecting ambiguous input avoids Host
    /// and Authorization smuggling through this hand-rolled boundary.
    private static func parseRequest(_ raw: String) -> Request? {
        guard raw.utf8.count <= Self.maxRequestBytes else { return nil }
        let sections = raw.components(separatedBy: "\r\n\r\n")
        guard sections.count <= 2 else { return nil }
        var lines = sections[0].components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3 else { return nil }
        let method = String(requestLine[0])
        let target = String(requestLine[1])
        let version = String(requestLine[2])
        guard target.hasPrefix("/"), version == "HTTP/1.1" else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard !line.isEmpty, let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, headers[name] == nil else { return nil }
            headers[name] = value
        }
        return Request(method: method,
                       target: target,
                       version: version,
                       headers: headers,
                       body: sections.count == 2 ? sections[1] : "")
    }

    private static func timingSafeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count, !a.isEmpty else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    /// Shared by REST and SSE. A credential in the URL is deliberately
    /// ignored because URLs leak into shell history, browser history, and
    /// diagnostics; callers must use `Authorization: Bearer …`.
    static func authorize(_ raw: String, token: String, port: UInt16) -> AuthorizationResult {
        guard let request = Self.parseRequest(raw) else { return .malformed }

        let allowedHosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard let host = request.headers["host"]?.lowercased(), allowedHosts.contains(host) else {
            return .forbidden
        }
        if request.headers["origin"] != nil
            || request.headers["referer"] != nil
            || request.headers.keys.contains(where: { $0.hasPrefix("sec-fetch-") }) {
            return .forbidden
        }

        guard let authorization = request.headers["authorization"] else { return .unauthorized }
        let pieces = authorization.split(separator: " ", omittingEmptySubsequences: true)
        guard pieces.count == 2,
              pieces[0].lowercased() == "bearer",
              Self.timingSafeEqual(String(pieces[1]), token)
        else { return .unauthorized }
        return .allowed
    }

    private static func requestBodyIsAllowed(_ request: Request) -> Bool {
        guard request.headers["transfer-encoding"] == nil else { return false }
        if let rawLength = request.headers["content-length"] {
            guard let length = Int(rawLength), length >= 0,
                  length == request.body.utf8.count else { return false }
            return length == 0
        }
        return request.body.isEmpty
    }

    private func receive(_ conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, err in
            guard let self else { conn.cancel(); return }
            if err != nil { conn.cancel(); return }
            var buf = accumulated
            if let data { buf.append(data) }
            switch Self.nextAction(buffer: buf, isComplete: isComplete) {
            case .respond(let header):
                if !self.tryServeEvents(header, on: conn) {
                    self.send(self.route(header), on: conn)
                }
            case .drop:
                conn.cancel()
            case .keepReading:
                self.receive(conn, accumulated: buf)
            }
        }
    }

    /// Deliberately NO CORS header: the user's browser is also a loopback
    /// client. Real callers authenticate out of band and don't need CORS.
    static let jsonContentType = "application/json; charset=utf-8"
    /// Prometheus text exposition format, version 0.0.4 — the de-facto scrape
    /// content type. Served only by `/metrics?format=prometheus`.
    static let prometheusContentType = "text/plain; version=0.0.4; charset=utf-8"

    static func httpHead(contentLength: Int,
                         contentType: String = jsonContentType,
                         statusCode: Int = 200,
                         extraHeaders: [String] = []) -> String {
        let reason: String
        switch statusCode {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 415: reason = "Unsupported Media Type"
        case 429: reason = "Too Many Requests"
        default: reason = "Error"
        }
        var head = "HTTP/1.1 \(statusCode) \(reason)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(contentLength)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n"
        for header in extraHeaders { head += header + "\r\n" }
        return head + "\r\n"
    }

    private func send(_ response: Response, on conn: NWConnection) {
        let body = Data(response.body.utf8)
        var payload = Data(Self.httpHead(contentLength: body.count,
                                         contentType: response.contentType,
                                         statusCode: response.statusCode,
                                         extraHeaders: response.headers).utf8)
        payload.append(body)
        conn.send(content: payload, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - SSE /events (B.6)

    /// Handle `GET /events`: a bearer-gated SSE stream. Returns true if it took
    /// ownership of the connection (streaming, or 401'd it), false to fall
    /// through to the normal one-shot router. It uses the same bearer, Host,
    /// browser-origin, body, and rate policy as the one-shot routes.
    private func tryServeEvents(_ header: String, on conn: NWConnection) -> Bool {
        guard let request = Self.parseRequest(header) else { return false }
        let path = request.target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        guard path == "/events" else { return false }

        let rejection: Response?
        switch Self.authorize(header, token: self.authToken, port: self.port) {
        case .allowed: rejection = nil
        case .unauthorized:
            rejection = Self.errorResponse(401, "valid bearer credential required",
                                           headers: ["WWW-Authenticate: Bearer"])
        case .forbidden:
            rejection = Self.errorResponse(403, "request host or browser origin rejected")
        case .malformed:
            rejection = Self.errorResponse(400, "malformed request")
        }
        if let rejection {
            self.send(rejection, on: conn)
            return true
        }
        guard request.method == "GET" else {
            self.send(Self.errorResponse(405, "only GET supported",
                                         headers: ["Allow: GET"]), on: conn)
            return true
        }
        guard Self.requestBodyIsAllowed(request) else {
            self.send(Self.errorResponse(400, "GET requests cannot include a body"), on: conn)
            return true
        }
        guard self.rateLimiter.allow() else {
            self.send(Self.errorResponse(429, "rate limit exceeded",
                                         headers: ["Retry-After: 60"]), on: conn)
            return true
        }
        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/event-stream; charset=utf-8\r\n"
            + "Cache-Control: no-store\r\nConnection: keep-alive\r\n\r\n"
        conn.send(content: Data((head + SSEFrame.comment("connected")).utf8), completion: .contentProcessed { _ in })
        EventHub.shared.register(conn)
        return true
    }

    // MARK: - Routing

    /// Returns the response body and its content type. Everything is JSON
    /// except `/metrics?format=prometheus`, which is text exposition.
    func route(_ raw: String) -> Response {
        func json(_ s: String, status: Int = 200) -> Response {
            Response(statusCode: status, body: s, contentType: Self.jsonContentType)
        }

        let authorization = Self.authorize(raw, token: self.authToken, port: self.port)
        switch authorization {
        case .unauthorized:
            return Self.errorResponse(401, "valid bearer credential required",
                                      headers: ["WWW-Authenticate: Bearer"])
        case .forbidden:
            return Self.errorResponse(403, "request host or browser origin rejected")
        case .malformed:
            return Self.errorResponse(400, "malformed request")
        case .allowed:
            break
        }
        guard let request = Self.parseRequest(raw) else {
            return Self.errorResponse(400, "malformed request")
        }
        guard request.method == "GET" else {
            return Self.errorResponse(405, "only GET supported", headers: ["Allow: GET"])
        }
        guard Self.requestBodyIsAllowed(request) else {
            return Self.errorResponse(400, "GET requests cannot include a body")
        }
        guard self.rateLimiter.allow() else {
            return Self.errorResponse(429, "rate limit exceeded", headers: ["Retry-After: 60"])
        }
        let target = request.target
        let split = target.split(separator: "?", maxSplits: 1)
        let path = String(split[0])
        let query = QueryServer.parseQuery(split.count == 2 ? String(split[1]) : "")

        switch path {
        case "/health":
            return json("{\"ok\":true,\"app\":\"Burrow\",\"port\":\(self.port)}")

        case "/info":
            return json(self.routeInfo())

        case "/snapshot":
            return json(self.routeSnapshot())

        case "/metrics":
            if query["format"] == "prometheus" {
                return Response(statusCode: 200,
                                body: self.routeMetricsPrometheus(),
                                contentType: Self.prometheusContentType)
            }
            return json(self.routeMetrics(query: query))

        default:
            return json(Self.errorJSON("unknown route"), status: 404)
        }
    }

    private var metrics: MetricsStore { MetricsStore(db: db) }

    private func routeInfo() -> String {
        let now = Int(Date().timeIntervalSince1970)
        let statuses = self.metrics.readers(now: now)
        var readers: [[String: Any]] = []
        for r in statuses {
            readers.append([
                "prefix": r.prefix,
                "latest_ts": r.latestTS.map { $0 as Any } ?? NSNull(),
                "age_seconds": r.ageSeconds.map { $0 as Any } ?? NSNull(),
            ])
        }
        let counters = MetricsStore.driftCounters
        let payload: [String: Any] = [
            "now": now,
            "app": "Burrow",
            "port": self.port,
            "prefixes": statuses.map(\.prefix),
            "readers": readers,
            // Drift visibility: how many stored rows this process has had
            // to skip on read, and why the last one failed — so a blank
            // chart always has a checkable cause.
            "decode_skipped_total": counters.decodeSkippedTotal,
            "last_drift": counters.lastDrift.map {
                ["ts": $0.ts, "message": $0.message, "snippet": $0.snippet] as Any
            } ?? NSNull(),
        ]
        return Self.jsonString(payload)
    }

    private func routeSnapshot() -> String {
        guard let row = self.metrics.latestRaw() else {
            return Self.errorJSON("no snapshot yet")
        }
        // Inline the stored JSON verbatim under a known key. Callers that
        // want typed access can decode the value against the Mole schema.
        return "{\"ts\":\(row.ts),\"snapshot\":\(row.json)}"
    }

    /// `GET /metrics?format=prometheus` → the latest snapshot rendered as
    /// Prometheus text exposition (roadmap B7), so a dev can point Grafana at
    /// their own Mac. A missing or undecodable snapshot yields a comment line
    /// rather than an error JSON — scrapers tolerate an empty target.
    private func routeMetricsPrometheus() -> String {
        guard let row = self.metrics.latestRaw(),
              let status = try? JSONDecoder().decode(MoleStatus.self, from: Data(row.json.utf8))
        else {
            return "# burrow: no snapshot available\n"
        }
        return MetricsPrometheus.exposition(from: status)
    }

    private func routeMetrics(query: [String: String]) -> String {
        guard let prefix = query["prefix"], !prefix.isEmpty else {
            return Self.errorJSON("missing 'prefix' query param")
        }
        let now = Int(Date().timeIntervalSince1970)
        let since = Int(query["since"] ?? "") ?? (now - 3600)
        let until = Int(query["until"] ?? "") ?? now
        let bucket = Int(query["bucket"] ?? "")
        let rows = self.metrics.rawRows(prefix: prefix,
                                        MetricsStore.Window(since: since, until: until),
                                        maxPoints: bucket != nil ? 720 : nil)

        // Embed stored JSON verbatim, no parse → re-encode roundtrip.
        var pieces: [String] = []
        pieces.reserveCapacity(rows.count)
        for r in rows {
            pieces.append("{\"ts\":\(r.ts),\"value\":\(r.json)}")
        }
        return "[" + pieces.joined(separator: ",") + "]"
    }

    // MARK: - Helpers

    private static func parseQuery(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let v = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            out[k] = v
        }
        return out
    }

    private static func errorJSON(_ msg: String) -> String {
        return "{\"error\":\"\(msg.replacingOccurrences(of: "\"", with: "\\\""))\"}"
    }

    private static func errorResponse(_ statusCode: Int,
                                      _ message: String,
                                      headers: [String] = []) -> Response {
        Response(statusCode: statusCode,
                 body: Self.errorJSON(message),
                 contentType: Self.jsonContentType,
                 headers: headers)
    }

    private static func jsonString(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []) else {
            return errorJSON("serialization failed")
        }
        return String(data: data, encoding: .utf8) ?? errorJSON("encoding failed")
    }
}

// MARK: - IP loopback helpers

private extension IPv4Address {
    var isLoopback: Bool {
        // 127.0.0.0/8
        return self.rawValue.first == 127
    }
}

private extension IPv6Address {
    var isLoopback: Bool {
        // ::1 is 15 zero bytes followed by a 0x01.
        let bytes = Array(self.rawValue)
        return bytes.count == 16
            && bytes.prefix(15).allSatisfy { $0 == 0 }
            && bytes[15] == 1
    }
}
