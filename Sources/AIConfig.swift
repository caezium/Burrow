//
//  AIConfig.swift
//  Burrow
//
//  The Explain lens's provider configuration, assembled in exactly one
//  place. Store owns raw persistence (with its defaults and the keychain-
//  backed API key), Settings owns rendering — but which backend is
//  selected, whether it's usable, and how the provider gets built all
//  live here, behind tests. Adding a backend means: a case in AIBackend,
//  a branch in makeProvider, a Settings section — and nothing else.
//

import Foundation

enum AIBackend: String, CaseIterable {
    case ollama, openai
}

struct AIConfig: Equatable {
    var enabled: Bool
    var backend: AIBackend
    var ollamaModel: String
    var openAIBaseURL: String
    var openAIModel: String
    var openAIKey: String

    /// The current settings, read from Store (which supplies trimming,
    /// defaults, and the keychain-backed key) — the only place provider
    /// configuration is assembled from persistence.
    static func load() -> AIConfig {
        AIConfig(enabled: Store.aiEnabled,
                 backend: AIBackend(rawValue: Store.aiProvider) ?? .ollama,
                 ollamaModel: Store.aiOllamaModel,
                 openAIBaseURL: Store.aiOpenAIBaseURL,
                 openAIModel: Store.aiOpenAIModel,
                 openAIKey: Store.aiOpenAIKey)
    }

    /// nil when the config can produce a working provider; otherwise a
    /// human-readable problem to surface BEFORE a doomed network call.
    /// An empty API key is deliberately fine — local OpenAI-compatible
    /// servers (LM Studio, llama.cpp) don't want one.
    var problem: String? {
        switch backend {
        case .ollama:
            if ollamaModel.trimmingCharacters(in: .whitespaces).isEmpty {
                return NSLocalizedString("No Ollama model is set — pick one in Settings.", comment: "")
            }
        case .openai:
            // Modern Foundation percent-encodes garbage rather than failing
            // URL(string:), so "is a URL" isn't enough — require a real
            // http(s) endpoint with a host.
            let url = OpenAICompatibleProvider.endpoint(from: openAIBaseURL)
            if url?.host == nil || (url?.scheme != "http" && url?.scheme != "https") {
                return NSLocalizedString("The API base URL isn't a valid http(s) URL — check it in Settings.", comment: "")
            }
            if openAIModel.trimmingCharacters(in: .whitespaces).isEmpty {
                return NSLocalizedString("No model name is set for the OpenAI-compatible API — set one in Settings.", comment: "")
            }
        }
        return nil
    }

    func makeProvider() -> ExplainProvider {
        switch backend {
        case .ollama: return OllamaProvider(model: ollamaModel)
        case .openai: return OpenAICompatibleProvider(baseURL: openAIBaseURL,
                                                      model: openAIModel,
                                                      apiKey: openAIKey)
        }
    }
}
