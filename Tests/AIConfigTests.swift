//
//  AIConfigTests.swift
//  BurrowTests
//
//  Boundary tests for the Explain lens's provider configuration — the one
//  place that decides which backend is selected, whether it's usable, and
//  how the provider is built. Previously that knowledge was spread across
//  Store accessors, provider default arguments, and ExplainEngine's switch;
//  the selection path was untested end-to-end.
//

import XCTest
@testable import Burrow

final class AIConfigTests: XCTestCase {
    override func setUp() {
        Store.d = UserDefaults(suiteName: StoreTests.scratchSuite)!
        Store.d.removePersistentDomain(forName: StoreTests.scratchSuite)
    }

    override func tearDown() {
        Store.d.removePersistentDomain(forName: StoreTests.scratchSuite)
        Store.d = .standard
    }

    // MARK: Load — Store is read in exactly one place

    func testLoad_defaultsToOllama() {
        let c = AIConfig.load()
        XCTAssertEqual(c.backend, .ollama)
        XCTAssertFalse(c.enabled)
        XCTAssertFalse(c.ollamaModel.isEmpty, "Store supplies a default model")
    }

    func testLoad_selectsOpenAIAndThreadsFields() {
        Store.aiEnabled = true
        Store.aiProvider = "openai"
        Store.aiOpenAIBaseURL = "http://127.0.0.1:1234/v1"
        Store.aiOpenAIModel = "qwen2.5-7b"

        let c = AIConfig.load()
        XCTAssertTrue(c.enabled)
        XCTAssertEqual(c.backend, .openai)
        XCTAssertEqual(c.openAIBaseURL, "http://127.0.0.1:1234/v1")
        XCTAssertEqual(c.openAIModel, "qwen2.5-7b")
    }

    func testLoad_garbageProviderFallsBackToOllama() {
        Store.aiProvider = "claude-9000"
        XCTAssertEqual(AIConfig.load().backend, .ollama)
    }

    // MARK: Validation — fail fast with an actionable message, not a hang

    func testProblem_nilForUsableConfigs() {
        XCTAssertNil(AIConfig(enabled: true, backend: .ollama, ollamaModel: "qwen3:4b",
                              openAIBaseURL: "", openAIModel: "", openAIKey: "").problem)
        // Empty key is fine — LM Studio and friends don't want one.
        XCTAssertNil(AIConfig(enabled: true, backend: .openai, ollamaModel: "",
                              openAIBaseURL: "http://127.0.0.1:1234/v1",
                              openAIModel: "m", openAIKey: "").problem)
    }

    func testProblem_flagsMissingModelAndBadURL() {
        XCTAssertNotNil(AIConfig(enabled: true, backend: .ollama, ollamaModel: "  ",
                                 openAIBaseURL: "", openAIModel: "", openAIKey: "").problem)
        XCTAssertNotNil(AIConfig(enabled: true, backend: .openai, ollamaModel: "",
                                 openAIBaseURL: "not a url at all",
                                 openAIModel: "m", openAIKey: "").problem)
        XCTAssertNotNil(AIConfig(enabled: true, backend: .openai, ollamaModel: "",
                                 openAIBaseURL: "http://127.0.0.1:1234/v1",
                                 openAIModel: "", openAIKey: "").problem)
    }

    // MARK: Provider construction — config threads through explicitly

    func testMakeProvider_ollamaThreadsModel() throws {
        let c = AIConfig(enabled: true, backend: .ollama, ollamaModel: "qwen3:4b",
                         openAIBaseURL: "", openAIModel: "", openAIKey: "")
        let p = try XCTUnwrap(c.makeProvider() as? OllamaProvider)
        XCTAssertEqual(p.model, "qwen3:4b")
    }

    func testMakeProvider_openAIThreadsEndpointModelAndKey() throws {
        let c = AIConfig(enabled: true, backend: .openai, ollamaModel: "",
                         openAIBaseURL: "https://api.example.com/v1",
                         openAIModel: "gpt-x", openAIKey: "sk-test")
        let p = try XCTUnwrap(c.makeProvider() as? OpenAICompatibleProvider)
        XCTAssertEqual(p.baseURL, "https://api.example.com/v1")
        XCTAssertEqual(p.model, "gpt-x")
        XCTAssertEqual(p.apiKey, "sk-test")
    }
}
