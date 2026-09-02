//
//  AnalyzeStreamingTests.swift
//  BurrowTests
//
//  The progressive treemap path: `analyze --progress <path>` streamed from the bundled engine,
//  driven here by a stub engine that emits the fixture lines the real one does (BUR-132).
//

import XCTest
@testable import Burrow

final class AnalyzeStreamingTests: XCTestCase {

    func testScanStreaming_drivesProgressFromTheStreamAndParsesTheTerminalResult() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-analyze-argv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let stub = """
        printf '%s\\n' "$@" > '\(marker.path)'
        printf '{"type":"progress","files":1,"dirs":1,"bytes":3,"path":"/x/sub"}\\n'
        printf '{"type":"progress","files":2,"dirs":1,"bytes":13,"path":"/x/sub/b"}\\n'
        printf '{"type":"result","data":{"path":"/x","overview":false,"entries":[{"name":"sub","path":"/x/sub","size":13,"is_dir":true}],"total_size":13,"total_files":2}}\\n'
        """
        var ticks: [(path: String, files: Int)] = []
        let result = try ConductorBundleFixture.withConductor(present: true, stub: stub) {
            try AnalyzeModel.scanStreaming("/x") { path, files, _ in ticks.append((path, files)) }
        }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "analyze\n--progress\n/x\n",
                       "the engine is asked for the progress stream of exactly this path")
        XCTAssertEqual(ticks.map(\.files), [1, 2], "every progress line reaches the treemap's counter")
        XCTAssertEqual(ticks.map(\.path), ["/x/sub", "/x/sub/b"])
        XCTAssertEqual(result.path, "/x")
        XCTAssertEqual(result.totalSize, 13)
        XCTAssertEqual(result.totalFiles, 2)
        XCTAssertEqual(result.entries.map(\.name), ["sub"])
        XCTAssertEqual(result.entries.first?.isDir, true)
    }

    /// A stream that ends without a `result` is a miss, and the caller falls back to the
    /// per-child walk — it must throw, never return an empty tree as if the scan succeeded.
    func testScanStreaming_throwsWhenTheStreamEndsWithoutAResult() throws {
        let stub = #"printf '{"type":"progress","files":1,"dirs":0,"bytes":0,"path":"/x"}\n'"#
        try ConductorBundleFixture.withConductor(present: true, stub: stub) {
            XCTAssertThrowsError(try AnalyzeModel.scanStreaming("/x") { _, _, _ in })
        }
    }
}
