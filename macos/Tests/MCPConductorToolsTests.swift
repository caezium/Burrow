//
//  MCPConductorToolsTests.swift
//  BurrowTests
//
//  The Phase-6.3 conductor-parity tools (dupes, orphans, net, rules
//  dryrun, sentinel, slim-check, photos) route through the bundled
//  `burrow` conductor. These pin the tool CONTRACT — catalog listing,
//  required-argument validation, the no-audit rule, and the degrade-
//  to-JSON-error path when no conductor is bundled (the test bundle
//  never ships one, so that branch is exercised without spawning).
//

import XCTest
@testable import Burrow

final class MCPConductorToolsTests: XCTestCase {
    private var tempDir: URL!
    private var db: DB!
    private var catalog: ToolCatalog!
    private var server: MCPServer!

    /// The seven read-only discovery tools this phase adds.
    private static let conductorTools: Set<String> = [
        "burrow_dupes", "burrow_net", "burrow_orphans", "burrow_photos",
        "burrow_rules_dryrun", "burrow_sentinel", "burrow_slim_check",
    ]

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-conductor-mcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try DB(at: tempDir.appendingPathComponent("burrow.db"))
        catalog = ToolCatalog(db: db)
        server = MCPServer(db: db)
    }

    override func tearDown() {
        server = nil
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Catalog listing

    func testDescriptors_listAllSevenConductorTools() {
        let names = Set(catalog.descriptors().compactMap { $0["name"] as? String })
        for tool in Self.conductorTools {
            XCTAssertTrue(names.contains(tool), "tools/list must include \(tool)")
        }
    }

    /// Every conductor tool carries a description that says it is read-only,
    /// and a schema of the same shape the rest of the catalog uses.
    func testDescriptors_conductorToolsHaveSchemaAndReadOnlyDescription() throws {
        for d in catalog.descriptors() where Self.conductorTools.contains((d["name"] as? String) ?? "") {
            let name = try XCTUnwrap(d["name"] as? String)
            let desc = try XCTUnwrap(d["description"] as? String, "\(name) needs a description")
            XCTAssertTrue(desc.localizedCaseInsensitiveContains("read-only"),
                          "\(name) description must say read-only")
            let schema = try XCTUnwrap(d["inputSchema"] as? [String: Any], "\(name) needs an inputSchema")
            XCTAssertEqual(schema["type"] as? String, "object")
            XCTAssertNotNil(schema["properties"], "\(name) schema needs properties")
        }
    }

    /// The required arguments must be declared in the schema so agents
    /// discover them from tools/list instead of by trial and error.
    func testDescriptors_requiredArgumentsAreDeclared() throws {
        let expected: [String: [String]] = [
            "burrow_dupes": ["paths"],
            "burrow_net": [],
            "burrow_orphans": ["path"],
            "burrow_photos": ["path"],
            "burrow_rules_dryrun": ["dir"],
            "burrow_sentinel": [],
            "burrow_slim_check": ["binary"],
        ]
        for d in catalog.descriptors() {
            guard let name = d["name"] as? String, let want = expected[name] else { continue }
            let schema = try XCTUnwrap(d["inputSchema"] as? [String: Any])
            let required = (schema["required"] as? [String]) ?? []
            XCTAssertEqual(Set(required), Set(want), "\(name) required args drifted")
            // Every required arg must also exist as a property.
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            for arg in want {
                XCTAssertNotNil(properties[arg], "\(name) required arg `\(arg)` missing from properties")
            }
        }
    }

    // MARK: - Required-argument validation (before any conductor spawn)

    func testDupes_withoutPaths_throwsBadArguments() {
        XCTAssertThrowsError(try catalog.call(name: "burrow_dupes", arguments: [:])) { err in
            guard case MCPToolError.badArguments = err else {
                return XCTFail("expected .badArguments, got \(err)")
            }
        }
    }

    func testDupes_withEmptyPaths_throwsBadArguments() {
        XCTAssertThrowsError(try catalog.call(name: "burrow_dupes",
                                              arguments: ["paths": ["", "  "]])) { err in
            guard case MCPToolError.badArguments = err else {
                return XCTFail("expected .badArguments, got \(err)")
            }
        }
    }

    func testOrphans_withoutPath_throwsBadArguments() {
        XCTAssertThrowsError(try catalog.call(name: "burrow_orphans", arguments: [:])) { err in
            guard case MCPToolError.badArguments = err else {
                return XCTFail("expected .badArguments, got \(err)")
            }
        }
    }

    func testRulesDryrun_withoutDir_throwsBadArguments() {
        // The bundled conductor ships no rules/ directory and its CLI default
        // (`rules/` relative to CWD) is meaningless from a GUI-spawned
        // process — so `dir` is required. Honest > broken.
        XCTAssertThrowsError(try catalog.call(name: "burrow_rules_dryrun", arguments: [:])) { err in
            guard case MCPToolError.badArguments = err else {
                return XCTFail("expected .badArguments, got \(err)")
            }
        }
    }

    func testSlimCheck_withoutBinary_throwsBadArguments() {
        XCTAssertThrowsError(try catalog.call(name: "burrow_slim_check", arguments: [:])) { err in
            guard case MCPToolError.badArguments = err else {
                return XCTFail("expected .badArguments, got \(err)")
            }
        }
    }

    func testPhotos_withoutPath_throwsBadArguments() {
        XCTAssertThrowsError(try catalog.call(name: "burrow_photos", arguments: [:])) { err in
            guard case MCPToolError.badArguments = err else {
                return XCTFail("expected .badArguments, got \(err)")
            }
        }
    }

    /// Over the JSON-RPC envelope the same validation must surface as the
    /// standard -32602 invalid-arguments error.
    func testSlimCheck_withoutBinary_is32602OverTheEnvelope() {
        let r = server.response(toLine: Data(
            #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"burrow_slim_check","arguments":{}}}"#.utf8))
        XCTAssertEqual((r?["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    // MARK: - Read-only: never audited, never confirm-gated

    func testConductorTools_areNotAudited() {
        for tool in Self.conductorTools {
            XCTAssertFalse(ToolCatalog.auditedTools.contains(tool),
                           "\(tool) is read-only and must not be in auditedTools")
        }
    }

    // MARK: - Degrade, never throw (no conductor in the test bundle)

    /// The test bundle ships no Resources/burrow, so `isAvailable` is false
    /// and the call must come back as a JSON error object naming the
    /// conductor — never a throw, never a crash, and no process spawned.
    func testNet_withoutBundledConductor_returnsJSONErrorMentioningConductor() throws {
        XCTAssertFalse(BurrowConductor.isAvailable,
                       "test bundles must not ship a conductor; this test depends on that")
        let json = try catalog.call(name: "burrow_net", arguments: [:])
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let error = try XCTUnwrap(obj["error"] as? String)
        XCTAssertTrue(error.localizedCaseInsensitiveContains("conductor")
                        || error.localizedCaseInsensitiveContains("burrow"),
                      "the error must tell the agent the conductor is missing, got: \(error)")
    }

    func testSentinel_withoutBundledConductor_returnsJSONErrorNotThrow() throws {
        let json = try catalog.call(name: "burrow_sentinel", arguments: [:])
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertNotNil(obj["error"])
    }

    /// Valid arguments + missing conductor must still degrade (the
    /// argument check passes, then the availability check reports).
    func testSlimCheck_withBinaryButNoConductor_returnsJSONError() throws {
        let json = try catalog.call(name: "burrow_slim_check", arguments: ["binary": "/usr/bin/true"])
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertNotNil(obj["error"])
    }
}
