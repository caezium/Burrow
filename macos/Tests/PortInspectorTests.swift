//
//  PortInspectorTests.swift
//  BurrowTests
//
//  Port-inspector safety + ordering (roadmap C.10).
//

import XCTest
@testable import Burrow

final class PortInspectorTests: XCTestCase {
    private func port(_ p: Int, _ name: String, uid: Int) -> ListeningPort {
        ListeningPort(pid: 1, process: name, port: p, proto: "tcp", address: "127.0.0.1", uid: uid)
    }

    func testKillable_onlyOwnNonRootProcesses() {
        XCTAssertTrue(PortInspector.isKillable(port(3000, "node", uid: 501), currentUID: 501))
        XCTAssertFalse(PortInspector.isKillable(port(22, "sshd", uid: 0), currentUID: 501),
                       "never offer to kill a root-owned daemon")
        XCTAssertFalse(PortInspector.isKillable(port(8080, "other", uid: 502), currentUID: 501),
                       "not another user's process")
    }

    func testSorted_byPortThenName_isStable() {
        let unsorted = [port(8080, "b", uid: 1), port(3000, "z", uid: 1), port(3000, "a", uid: 1)]
        let s = PortInspector.sorted(unsorted)
        XCTAssertEqual(s.map(\.port), [3000, 3000, 8080])
        XCTAssertEqual(s.map(\.process), ["a", "z", "b"])
    }

    // MARK: - Extended suite: lookup, conflicts, filter

    private func mk(_ port: Int, pid: Int, _ state: ConnState = .listen,
                    proc: String = "proc", remote: String? = nil, rport: Int? = nil) -> ListeningPort {
        ListeningPort(pid: pid, process: proc, port: port, proto: "tcp", address: "*", uid: 501,
                      state: state, remoteAddress: remote, remotePort: rport)
    }

    func testPortLookup_knownAndUnknown() {
        XCTAssertEqual(PortLookup.service(for: 5432), "PostgreSQL")
        XCTAssertEqual(PortLookup.service(for: 22), "SSH")
        XCTAssertNil(PortLookup.service(for: 54321))
    }

    func testConflicts_flagsSamePortDifferentPids() {
        let ports = [mk(3000, pid: 10), mk(3000, pid: 11), mk(8080, pid: 12)]
        XCTAssertEqual(PortInspector.conflicts(ports), [3000])
    }

    func testConflicts_ignoresSamePidAndEstablished() {
        let remoteA = "1.2.3.4" // greenlight:ignore hardcoded-ipv4 — port-inspector fixture
        let remoteB = "5.6.7.8" // greenlight:ignore hardcoded-ipv4 — port-inspector fixture
        let ports = [
            mk(3000, pid: 10), mk(3000, pid: 10),                       // one owner, listed twice
            mk(443, pid: 20, .established, remote: remoteA, rport: 443),
            mk(443, pid: 21, .established, remote: remoteB, rport: 443),  // established ≠ conflict
        ]
        XCTAssertTrue(PortInspector.conflicts(ports).isEmpty)
    }

    func testFilter_byState() {
        let remote = "1.1.1.1" // greenlight:ignore hardcoded-ipv4 — port-inspector fixture
        let ports = [mk(3000, pid: 1), mk(443, pid: 2, .established, remote: remote, rport: 443)]
        XCTAssertEqual(PortInspector.filter(ports, .listening, query: "").count, 1)
        XCTAssertEqual(PortInspector.filter(ports, .established, query: "").first?.port, 443)
        XCTAssertEqual(PortInspector.filter(ports, .all, query: "").count, 2)
    }

    func testFilter_byQuery_matchesPortProcessServiceAndRemote() {
        let remote = "93.184.216.34" // greenlight:ignore hardcoded-ipv4 — port-inspector fixture
        let ports = [
            mk(5432, pid: 1, proc: "postgres"),
            mk(8080, pid: 2, proc: "node"),
            mk(443, pid: 3, .established, proc: "curl", remote: remote, rport: 443),
        ]
        XCTAssertEqual(PortInspector.filter(ports, .all, query: "node").map(\.port), [8080])
        XCTAssertEqual(PortInspector.filter(ports, .all, query: "5432").map(\.port), [5432])
        XCTAssertEqual(PortInspector.filter(ports, .all, query: "postgre").map(\.port), [5432]) // service label
        XCTAssertEqual(PortInspector.filter(ports, .all, query: "93.184").map(\.port), [443])   // remote host
    }

    func testDeduped_collapsesIdenticalRows() {
        // IPv4 + IPv6 listening on the same port = two identical entries.
        let dupes = [mk(3000, pid: 10), mk(3000, pid: 10), mk(8080, pid: 11)]
        let out = PortInspector.deduped(dupes)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(Set(out.map(\.port)), [3000, 8080])
    }

    func testSorted_byBandwidth_usesRates() {
        let ports = [mk(3000, pid: 1), mk(8080, pid: 2), mk(443, pid: 3)]
        let rates: [Int: NetUsage.Rates] = [
            1: .init(down: 100, up: 0),
            2: .init(down: 5000, up: 0),
            3: .init(down: 50, up: 0),
        ]
        let desc = PortInspector.sorted(ports, by: .down, ascending: false, rates: rates)
        XCTAssertEqual(desc.map(\.pid), [2, 1, 3], "busiest download first")
    }

    func testSorted_byPort_ascending() {
        let ports = [mk(8080, pid: 1), mk(443, pid: 2), mk(3000, pid: 3)]
        XCTAssertEqual(PortInspector.sorted(ports, by: .port, ascending: true, rates: [:]).map(\.port),
                       [443, 3000, 8080])
    }
}
