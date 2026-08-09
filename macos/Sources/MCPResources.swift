//
//  MCPResources.swift
//  Burrow
//
//  Resources, resource templates, prompts, and argument completion.
//
//  Burrow is a data-rich app that, until now, exposed all of it through
//  tool calls only. Resources fit the read-mostly half of that data better:
//  an agent can attach `burrow://doctor` to its context once instead of
//  re-calling a tool, and the `ttlMs` hints tell it how long the attachment
//  stays honest — five seconds for a live snapshot, a minute for a digest.
//
//  Everything here is read-only by construction. Resources map onto the
//  same read tools the catalogue already exposes, so there is exactly one
//  implementation of each answer; nothing that deletes is reachable from a
//  resource URI or a prompt.
//

import Foundation

struct MCPResources {
    let catalog: ToolCatalog
    let db: DB

    private var metrics: MetricsStore { MetricsStore(db: db) }

    // MARK: - Fixed resources

    /// One row of the resource table: how to describe it, and which read
    /// tool produces it.
    struct Fixed {
        let uri: String
        let name: String
        let title: String
        let description: String
        let mimeType: String
        let tool: String
        let arguments: [String: Any]
        let ttlMs: Int
    }

    static let fixed: [Fixed] = [
        Fixed(uri: "burrow://snapshot/latest", name: "latest_snapshot",
              title: "Latest system snapshot",
              description: "The most recent sample: CPU, memory, disk, network, thermal, and top processes.",
              mimeType: "application/json", tool: "burrow_snapshot", arguments: [:],
              ttlMs: MCPProtocol.Cache.liveTTL),

        Fixed(uri: "burrow://doctor", name: "doctor",
              title: "Diagnostics",
              description: "Engine presence, Full Disk Access, memory pressure, disk headroom, and decode errors as ok/warn/fail checks.",
              mimeType: "application/json", tool: "burrow_doctor", arguments: [:],
              ttlMs: MCPProtocol.Cache.digestTTL),

        Fixed(uri: "burrow://ports", name: "listening_ports",
              title: "Listening ports",
              description: "Every listening TCP/UDP socket with the process that owns it.",
              mimeType: "application/json", tool: "burrow_ports", arguments: [:],
              ttlMs: MCPProtocol.Cache.liveTTL),

        Fixed(uri: "burrow://info", name: "burrow_state",
              title: "Burrow's own state",
              description: "Which data streams are recording, how stale each one is, and the retention setting. Read this before trusting the others.",
              mimeType: "application/json", tool: "burrow_info", arguments: [:],
              ttlMs: MCPProtocol.Cache.liveTTL),

        Fixed(uri: "burrow://forecast/disk", name: "disk_forecast",
              title: "Disk-full forecast",
              description: "When the largest volume runs out of space, fitted from free-space history.",
              mimeType: "application/json", tool: "burrow_disk_forecast", arguments: [:],
              ttlMs: MCPProtocol.Cache.digestTTL),

        Fixed(uri: "burrow://cleanup/history", name: "cleanup_history",
              title: "Cleanup history",
              description: "Past clean/optimize/purge/uninstall sessions with bytes freed and item counts.",
              mimeType: "application/json", tool: "burrow_cleanup_history", arguments: [:],
              ttlMs: MCPProtocol.Cache.digestTTL),

        Fixed(uri: "burrow://cleanup/deleted-files", name: "deleted_files",
              title: "Deleted file paths",
              description: "The exact paths past cleanups removed or trashed, newest first.",
              mimeType: "application/json", tool: "burrow_deleted_files", arguments: [:],
              ttlMs: MCPProtocol.Cache.digestTTL),

        Fixed(uri: "burrow://agent-audit", name: "agent_audit",
              title: "What agents have done",
              description: "Every mutating tool call an agent has made through this server in the last week, with its arguments and outcome.",
              mimeType: "application/json", tool: "burrow_agent_audit", arguments: [:],
              ttlMs: MCPProtocol.Cache.liveTTL),

        Fixed(uri: "burrow://anomalies", name: "anomalies",
              title: "CPU anomalies",
              description: "Processes whose recent CPU use has regressed against their own 14-day baseline.",
              mimeType: "application/json", tool: "burrow_anomalies", arguments: [:],
              ttlMs: MCPProtocol.Cache.digestTTL),

        Fixed(uri: "burrow://report/weekly", name: "weekly_report",
              title: "Weekly digest",
              description: "The seven-day system digest as Markdown — disk forecast, top energy users, cleanup summary.",
              mimeType: "text/markdown", tool: "burrow_report", arguments: [:],
              ttlMs: MCPProtocol.Cache.digestTTL),
    ]

    /// Resource descriptors for `resources/list`.
    static func listing() -> [[String: Any]] {
        Self.fixed.map { r in
            [
                "uri": r.uri,
                "name": r.name,
                "title": r.title,
                "description": r.description,
                "mimeType": r.mimeType,
                "annotations": ["audience": ["assistant"], "priority": 0.5],
            ]
        }
    }

    // MARK: - Templates

    static let templates: [[String: Any]] = [
        [
            "uriTemplate": "burrow://history/{minutes}",
            "name": "metric_history",
            "title": "Metric history window",
            "description": "Sampled snapshots over the last {minutes} minutes, e.g. burrow://history/120.",
            "mimeType": "application/json",
        ],
        [
            "uriTemplate": "burrow://processes/{metric}",
            "name": "process_ranking",
            "title": "Process ranking",
            "description": "Processes over the last hour ranked by {metric}: cpu_time, peak_cpu, avg_cpu, or peak_mem.",
            "mimeType": "application/json",
        ],
        [
            "uriTemplate": "burrow://report/{days}",
            "name": "report_window",
            "title": "Digest over N days",
            "description": "The system digest as Markdown over the last {days} days, e.g. burrow://report/30.",
            "mimeType": "text/markdown",
        ],
    ]

    // MARK: - Reading

    struct Contents {
        let text: String
        let mimeType: String
        let ttlMs: Int
    }

    enum ReadError: Error {
        /// Maps to -32602 in this revision — the resource-not-found code was
        /// realigned with JSON-RPC's Invalid Params.
        case notFound(String)
    }

    func read(uri: String) throws -> Contents {
        if let fixed = Self.fixed.first(where: { $0.uri == uri }) {
            let text = (try? self.catalog.call(name: fixed.tool, arguments: fixed.arguments))
                ?? "{\"error\":\"read failed\"}"
            return Contents(text: text, mimeType: fixed.mimeType, ttlMs: fixed.ttlMs)
        }

        if let minutes = Self.parameter(of: uri, prefix: "burrow://history/") {
            guard let m = Int(minutes), m > 0, m <= 1_000_000 else {
                throw ReadError.notFound("burrow://history/{minutes} needs a positive integer, got \"\(minutes)\"")
            }
            let text = (try? self.catalog.call(name: "burrow_history", arguments: ["minutes": m]))
                ?? "{\"error\":\"read failed\"}"
            return Contents(text: text, mimeType: "application/json", ttlMs: MCPProtocol.Cache.liveTTL)
        }

        if let metric = Self.parameter(of: uri, prefix: "burrow://processes/") {
            guard MetricsStore.ProcessRank(rawValue: metric) != nil else {
                let allowed = MetricsStore.ProcessRank.allCases.map(\.rawValue).joined(separator: ", ")
                throw ReadError.notFound("burrow://processes/{metric} takes one of: \(allowed)")
            }
            let text = (try? self.catalog.call(name: "burrow_process_usage",
                                               arguments: ["metric": metric, "minutes": 60]))
                ?? "{\"error\":\"read failed\"}"
            return Contents(text: text, mimeType: "application/json", ttlMs: MCPProtocol.Cache.digestTTL)
        }

        if let days = Self.parameter(of: uri, prefix: "burrow://report/") {
            // `burrow://report/weekly` is a fixed resource and was matched above.
            guard let d = Int(days), d >= 1, d <= 90 else {
                throw ReadError.notFound("burrow://report/{days} takes 1-90, got \"\(days)\"")
            }
            let text = (try? self.catalog.call(name: "burrow_report", arguments: ["days": d]))
                ?? "# report unavailable"
            return Contents(text: text, mimeType: "text/markdown", ttlMs: MCPProtocol.Cache.digestTTL)
        }

        throw ReadError.notFound("unknown resource: \(uri)")
    }

    /// The single path segment after `prefix`, or nil when the URI doesn't
    /// match. Rejects nested paths so `burrow://history/1/2` isn't silently
    /// read as `1`.
    private static func parameter(of uri: String, prefix: String) -> String? {
        guard uri.hasPrefix(prefix) else { return nil }
        let rest = String(uri.dropFirst(prefix.count))
        guard !rest.isEmpty, !rest.contains("/") else { return nil }
        return rest.removingPercentEncoding ?? rest
    }

    // MARK: - Prompts

    static let prompts: [[String: Any]] = [
        [
            "name": "diagnose_slow_mac",
            "title": "Diagnose a slow Mac",
            "description": "Work out why this Mac is slow right now, in the order that avoids wrong answers.",
            "arguments": [
                ["name": "minutes", "description": "How far back to look. Defaults to 60.", "required": false],
            ],
        ],
        [
            "name": "reclaim_disk_space",
            "title": "Reclaim disk space",
            "description": "Find the safest large wins on disk and preview them without deleting anything.",
            "arguments": [
                ["name": "target_gb", "description": "How many gigabytes to try to free.", "required": false],
            ],
        ],
        [
            "name": "explain_last_cleanup",
            "title": "Explain the last cleanup",
            "description": "Say exactly what the most recent cleanup removed, path by path.",
            "arguments": [],
        ],
        [
            "name": "investigate_process",
            "title": "Investigate a process",
            "description": "Build a picture of one process: how much it has used, when, and what it is listening on.",
            "arguments": [
                ["name": "name", "description": "Process name, e.g. \"Google Chrome Helper\".", "required": true],
            ],
        ],
        [
            "name": "pre_uninstall_check",
            "title": "Check before uninstalling",
            "description": "Everything worth knowing before removing an app, without removing it.",
            "arguments": [
                ["name": "app", "description": "App name as burrow_list_apps reports it.", "required": true],
            ],
        ],
    ]

    /// Render a prompt into messages. Returns nil for an unknown name.
    static func prompt(name: String, arguments: [String: Any]) -> [String: Any]? {
        func arg(_ key: String) -> String? {
            if let s = arguments[key] as? String, !s.isEmpty { return s }
            if let n = arguments[key] as? Int { return String(n) }
            return nil
        }

        let text: String
        let description: String
        switch name {
        case "diagnose_slow_mac":
            let minutes = arg("minutes") ?? "60"
            description = "Diagnose slowness over the last \(minutes) minutes."
            text = """
                This Mac feels slow. Work out why, using Burrow's tools in this order:

                1. Call burrow_doctor first. If the engine is missing or data is stale, say so — \
                every later answer would be built on nothing.
                2. Call burrow_process_usage with minutes=\(minutes) and metric=cpu_time. Cumulative \
                CPU-seconds is the honest answer to "what used my computer"; peak CPU just crowns \
                whatever spiked for one sample.
                3. Call burrow_snapshot for memory pressure and thermal state right now.
                4. If disk is tight, call burrow_disk_forecast.

                Then give me the single most likely cause and what to do about it. Don't clean \
                anything — say what you'd clean and let me decide.
                """
        case "reclaim_disk_space":
            let target = arg("target_gb")
            description = target.map { "Find \($0) GB to reclaim." } ?? "Find space to reclaim."
            text = """
                I need to free up disk space\(target.map { " — about \($0) GB" } ?? "").

                Start with burrow_disk_forecast to see how urgent this is, then burrow_analyze on \
                the home folder to find where the weight actually is. Pass min_size so small \
                entries don't drown the result, and analyze a specific subdirectory rather than \
                rescanning everything.

                Then preview the safe wins: burrow_clean without confirm (that's a dry run), \
                burrow_purge for build artifacts, and burrow_dupes on the directories that looked \
                heavy. Rank what you found by bytes-per-risk and show me the list.

                Do not pass confirm:true to anything. I'll decide what gets deleted.
                """
        case "explain_last_cleanup":
            description = "Explain what the last cleanup actually removed."
            text = """
                What did the last cleanup actually do? Call burrow_cleanup_history for the session \
                summary, then burrow_deleted_files for the exact paths. Group the paths by what \
                they belonged to, tell me the total reclaimed, and flag anything that looks like it \
                shouldn't have been touched.
                """
        case "investigate_process":
            guard let process = arg("name") else { return nil }
            description = "Investigate \(process)."
            text = """
                Tell me about "\(process)" on this Mac.

                Use burrow_process_usage over a few windows (an hour, a day) so I can see whether \
                this is a spike or a pattern, burrow_ports to see whether it's listening on \
                anything, and burrow_net for what it's moving over the network. Say whether its \
                usage looks normal for what it is, and whether it's worth doing something about.
                """
        case "pre_uninstall_check":
            guard let app = arg("app") else { return nil }
            description = "Pre-uninstall check for \(app)."
            text = """
                I'm thinking about uninstalling "\(app)". Before anything is removed:

                Call burrow_list_apps and confirm the exact name the uninstaller would match — if \
                it's ambiguous, stop and tell me. Then call burrow_uninstall WITHOUT confirm to get \
                the dry-run list of what would go, and burrow_orphans on ~/Library/Application \
                Support to see what this app has already left lying around.

                Show me the file list and what it totals. Don't uninstall.
                """
        default:
            return nil
        }

        return [
            "description": description,
            "messages": [
                ["role": "user", "content": ["type": "text", "text": text]],
            ],
        ]
    }

    // MARK: - Completion

    /// `completion/complete`. Two things are worth completing here: the
    /// metric names in the process-ranking template, and real process names
    /// pulled from the recorded window — the second one is only possible
    /// because the data is already local.
    func complete(ref: [String: Any], argumentName: String, value: String) -> [String: Any] {
        let refType = ref["type"] as? String ?? ""
        var values: [String] = []

        if refType == "ref/resource", (ref["uri"] as? String)?.contains("{metric}") == true {
            values = MetricsStore.ProcessRank.allCases.map(\.rawValue)
        } else if refType == "ref/prompt", ref["name"] as? String == "investigate_process",
                  argumentName == "name" {
            values = self.recentProcessNames()
        }

        let matches = values
            .filter { value.isEmpty || $0.lowercased().hasPrefix(value.lowercased()) }
            .sorted()
        // 100 is the per-response cap the spec puts on completion values.
        let capped = Array(matches.prefix(100))
        return ["completion": ["values": capped, "total": matches.count,
                               "hasMore": matches.count > capped.count]]
    }

    /// Distinct process names seen in the last hour, so completing a process
    /// name suggests things that actually ran on this machine.
    private func recentProcessNames() -> [String] {
        let now = Int(Date().timeIntervalSince1970)
        let window = MetricsStore.Window(since: now - 3_600, until: now)
        let ranked = self.metrics.processWindow(window).ranked(by: .peakCPU, limit: 100)
        var seen = Set<String>()
        return ranked.map(\.name).filter { seen.insert($0).inserted }
    }
}
