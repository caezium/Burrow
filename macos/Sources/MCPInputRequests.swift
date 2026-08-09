//
//  MCPInputRequests.swift
//  Burrow
//
//  Multi Round-Trip Requests (MRTR) — the 2026-07-28 replacement for
//  server-initiated requests.
//
//  A server that needs something mid-call can't just send a request any
//  more: it returns `resultType: "input_required"` with the questions in
//  `inputRequests`, and the client re-issues the original call with the
//  answers in `inputResponses`. Correlation across the retry is the
//  server's job, which is what `requestState` carries.
//
//  IMPORTANT — this is ergonomics, not consent. An `input_required` round
//  trip is answered by the *agent*, which is free to answer its own
//  question without a human ever seeing it. So MRTR is used here only
//  where the server is genuinely missing information it cannot invent (an
//  app name, a directory to scan). It is deliberately NOT used as a
//  confirmation gate for the destructive tools: those stay governed by
//  `MoActions.decide` and the user's Settings opt-ins, which an agent
//  cannot answer on the user's behalf.
//

import Foundation

enum MCPInputRequests {
    /// A single argument the server can't proceed without.
    struct MissingArgument {
        let key: String
        let message: String
        /// Whether the answer is a comma-separated list that expands into an
        /// array argument. Elicitation form values are primitives, so a list
        /// arrives as one string.
        let isList: Bool
        let placeholder: String
    }

    /// Which required argument each tool would otherwise reject. Tools with
    /// sensible defaults (burrow_analyze defaults to the home folder) are
    /// absent on purpose — asking would be worse than defaulting.
    static func missingArgument(tool: String, arguments: [String: Any]) -> MissingArgument? {
        func blankString(_ key: String) -> Bool {
            let v = (arguments[key] as? String)?.trimmingCharacters(in: .whitespaces)
            return v == nil || v!.isEmpty
        }
        func blankList(_ key: String) -> Bool {
            let v = (arguments[key] as? [String])?
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return v == nil || v!.isEmpty
        }

        switch tool {
        case "burrow_uninstall" where blankList("apps"):
            return MissingArgument(
                key: "apps",
                message: "Which applications should be uninstalled? Use the exact names burrow_list_apps reports. Separate several with commas.",
                isList: true, placeholder: "Slack, Zoom")
        case "burrow_dupes" where blankList("paths"):
            return MissingArgument(
                key: "paths",
                message: "Which directories should be scanned for duplicate files? Absolute paths, separated by commas.",
                isList: true, placeholder: "/Users/you/Downloads, /Users/you/Documents")
        case "burrow_orphans" where blankString("path"):
            return MissingArgument(
                key: "path",
                message: "Which directory should be scanned for orphaned files?",
                isList: false, placeholder: "/Users/you/Library/Application Support")
        case "burrow_photos" where blankString("path"):
            return MissingArgument(
                key: "path",
                message: "Which directory should be scanned for near-duplicate photos?",
                isList: false, placeholder: "/Users/you/Pictures")
        case "burrow_rules_dryrun" where blankString("dir"):
            return MissingArgument(
                key: "dir",
                message: "Which rules directory should be previewed? No rules ship with the app, so there is no default.",
                isList: false, placeholder: "/Users/you/burrow-rules")
        case "burrow_slim_check" where blankString("binary"):
            return MissingArgument(
                key: "binary",
                message: "Which Mach-O binary should be measured? Usually an app's main executable.",
                isList: false, placeholder: "/Applications/Some.app/Contents/MacOS/Some")
        default:
            return nil
        }
    }

    /// The `inputRequests` map for one missing argument. Keys are
    /// server-assigned; we use the argument name so the retry is readable.
    static func elicitation(for missing: MissingArgument) -> [String: Any] {
        let field: [String: Any] = [
            "type": "string",
            "title": missing.key,
            "description": "\(missing.message) Example: \(missing.placeholder)",
            "minLength": 1,
        ]
        return [
            missing.key: [
                "method": "elicitation/create",
                "params": [
                    "mode": "form",
                    "message": missing.message,
                    "requestedSchema": [
                        "type": "object",
                        "properties": [missing.key: field],
                        "required": [missing.key],
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    /// Encode what the retry needs to know. The spec types `requestState` as
    /// an opaque string, so this is our own JSON in it.
    static func encodeState(tool: String, arguments: [String: Any], asking key: String) -> String {
        let payload: [String: Any] = ["tool": tool, "arguments": arguments, "asking": key]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }

    struct State {
        let tool: String
        let arguments: [String: Any]
        let asking: String
    }

    static func decodeState(_ raw: String?) -> State? {
        guard let raw, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tool = obj["tool"] as? String,
              let asking = obj["asking"] as? String else { return nil }
        return State(tool: tool,
                     arguments: (obj["arguments"] as? [String: Any]) ?? [:],
                     asking: asking)
    }

    /// What came back from the client.
    enum Resolution {
        /// The user answered; these are the arguments to run with.
        case proceed([String: Any])
        /// The user declined or dismissed. Not an error — the tool reports it.
        case declined(String)
        /// The answer didn't contain what we asked for.
        case unusable(String)
    }

    /// Fold `inputResponses` back into the original arguments.
    static func resolve(state: State, inputResponses: [String: Any]) -> Resolution {
        guard let response = inputResponses[state.asking] as? [String: Any] else {
            return .unusable("no answer for \"\(state.asking)\" in inputResponses")
        }
        let action = response["action"] as? String ?? ""
        switch action {
        case "accept":
            break
        case "decline":
            return .declined("the user declined to provide \(state.asking)")
        case "cancel":
            return .declined("the user dismissed the request for \(state.asking)")
        default:
            return .unusable("unrecognised elicitation action \"\(action)\"")
        }

        let content = (response["content"] as? [String: Any]) ?? [:]
        var arguments = state.arguments

        // The client may hand back a list directly, or the comma-separated
        // string the form asked for. Accept either.
        if let list = content[state.asking] as? [String] {
            let cleaned = list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !cleaned.isEmpty else { return .unusable("the answer for \(state.asking) was empty") }
            arguments[state.asking] = cleaned
            return .proceed(arguments)
        }

        guard let raw = content[state.asking] as? String else {
            return .unusable("the answer for \(state.asking) was not a string")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .unusable("the answer for \(state.asking) was empty") }

        if Self.isListArgument(tool: state.tool, key: state.asking) {
            let parts = trimmed.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !parts.isEmpty else { return .unusable("the answer for \(state.asking) was empty") }
            arguments[state.asking] = parts
        } else {
            arguments[state.asking] = trimmed
        }
        return .proceed(arguments)
    }

    /// Whether the tool wants an array for this argument. Derived from the
    /// same table the question came from, so the two can't disagree.
    private static func isListArgument(tool: String, key: String) -> Bool {
        Self.missingArgument(tool: tool, arguments: [:])?.isList == true
            && Self.missingArgument(tool: tool, arguments: [:])?.key == key
    }
}
