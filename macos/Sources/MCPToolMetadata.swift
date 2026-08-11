//
//  MCPToolMetadata.swift
//  Burrow
//
//  Annotations and output schemas for the tool catalogue.
//
//  These live apart from `ToolCatalog.descriptors()` on purpose: the
//  descriptors are already dense with prose, and the read-only/destructive
//  split is a safety property that deserves to be readable in one place
//  rather than scattered across twenty-six inline dictionaries.
//
//  On `outputSchema` honesty: declaring one is a promise that
//  `structuredContent` conforms to it. Most of these tools can also return
//  a bare `{"error": …}` object when the engine is missing or a scan times
//  out, and several pass the engine's payload through verbatim so the shape
//  tracks the engine's contract rather than ours. So the schemas below
//  describe properties without requiring them — an agent gets the field map,
//  and the error path stays conformant instead of becoming a spec violation.
//

import Foundation

enum MCPToolMetadata {
    /// Per-tool display name, behavioural hints, and output shape.
    struct Entry {
        let title: String
        let readOnly: Bool
        /// Only meaningful when `readOnly` is false.
        let destructive: Bool
        /// Only meaningful when `readOnly` is false.
        let idempotent: Bool
        /// True when the tool's answer depends on live machine state outside
        /// Burrow's own recorded data — the filesystem, running processes,
        /// the installed-app inventory.
        let openWorld: Bool
        /// nil for tools whose payload isn't a JSON object (burrow_report is
        /// Markdown), which also suppresses `structuredContent`.
        let outputSchema: [String: Any]?

        var annotations: [String: Any] {
            var a: [String: Any] = [
                "title": self.title,
                "readOnlyHint": self.readOnly,
                "openWorldHint": self.openWorld,
            ]
            if !self.readOnly {
                a["destructiveHint"] = self.destructive
                a["idempotentHint"] = self.idempotent
            }
            return a
        }
    }

    // MARK: - Schema helpers

    private static func object(_ properties: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": properties, "additionalProperties": true]
    }

    private static func int(_ desc: String) -> [String: Any] {
        ["type": "integer", "description": desc]
    }

    private static func num(_ desc: String) -> [String: Any] {
        ["type": "number", "description": desc]
    }

    private static func str(_ desc: String) -> [String: Any] {
        ["type": "string", "description": desc]
    }

    private static func arr(of items: [String: Any], _ desc: String) -> [String: Any] {
        ["type": "array", "items": items, "description": desc]
    }

    private static let stringArray: [String: Any] = ["type": "array", "items": ["type": "string"]]

    /// The shape every tool that can fail softly shares. Merged into the
    /// property map rather than declared as a variant so the schema stays a
    /// plain object — agents read these as "may be present".
    private static let softError: [String: Any] = [
        "error": ["type": "string", "description": "Present instead of the payload when the tool could not run (missing engine, failed scan). Not a protocol error."],
        "hint": ["type": "string", "description": "What to try instead, when the error is actionable."],
    ]

    private static func withError(_ properties: [String: Any]) -> [String: Any] {
        var p = properties
        for (k, v) in Self.softError { p[k] = v }
        return Self.object(p)
    }

    /// Payloads that come straight from the engine (`mo`) or the bundled
    /// conductor (`burrow <cmd> --json`). We deliberately don't restate the
    /// engine's contract here — it would drift the moment the engine
    /// changes, and the descriptions already point at the source.
    private static func passthrough(_ what: String) -> [String: Any] {
        Self.withError([
            "_passthrough": ["type": "string", "description": "This tool returns \(what) verbatim; the payload's shape tracks the engine's contract, not Burrow's."],
        ])
    }

    /// The frozen action-tool contract from `ActionWire`.
    private static var actionResult: [String: Any] {
        Self.withError([
            "command": Self.str("The engine subcommand that ran."),
            "dry_run": ["type": "boolean", "description": "True when this was a preview and nothing was changed."],
            "ran": ["type": "boolean", "description": "True only when a real (non-preview) run actually executed."],
            "blocked": ["type": "boolean", "description": "Present and true when the user's Settings opt-in refused the run."],
            "reason": Self.str("Why the run was blocked. The user changes this in Burrow's Settings, not the agent."),
            "exit_code": Self.int("The engine's exit status."),
            "output": Self.str("The engine's console output, ANSI-stripped."),
            "summary": Self.object([
                "space": Self.str("Space freed, as the engine reported it."),
                "items": Self.str("Item count."),
                "categories": Self.str("Categories touched."),
                "free_change": Self.str("Change in free space."),
                "free_now": Self.str("Free space after the run."),
            ]),
            "apps": Self.stringArray,
            "permanent": ["type": "boolean", "description": "True when removed files bypassed the Trash."],
            "interactive_only": ["type": "boolean", "description": "True when the real flow is GUI-only and this is the preview."],
            "note": Self.str("Why the tool returned a preview instead of running."),
            "timed_out": ["type": "boolean", "description": "True when the engine was killed before finishing — NOT the same as 'nothing to do'."],
            "matched": Self.stringArray,
        ])
    }

    // MARK: - The table

    static let table: [String: Entry] = [
        "burrow_snapshot": Entry(
            title: "Latest system snapshot", readOnly: true, destructive: false,
            idempotent: true, openWorld: false,
            outputSchema: Self.withError([
                "ts": Self.int("Unix seconds the snapshot was taken."),
                "snapshot": Self.object([:]),
            ])),

        "burrow_history": Entry(
            title: "Metric history", readOnly: true, destructive: false,
            idempotent: true, openWorld: false,
            outputSchema: Self.withError([
                "count": Self.int("Number of returned samples."),
                "rows": Self.arr(of: Self.object([
                    "ts": Self.int("Unix seconds."),
                    "snapshot": Self.object([:]),
                ]), "Sampled snapshots, oldest first."),
            ])),

        "burrow_top_processes": Entry(
            title: "Top processes by peak CPU", readOnly: true, destructive: false,
            idempotent: true, openWorld: false,
            outputSchema: Self.withError([
                "window_minutes": Self.int("The window that was aggregated."),
                "processes": Self.arr(of: Self.object([
                    "name": Self.str("Process name."),
                    "peak_cpu": Self.num("Highest single-sample CPU percent."),
                    "peak_mem": Self.num("Highest single-sample memory percent."),
                ]), "Ranked by peak CPU, highest first."),
            ])),

        "burrow_process_usage": Entry(
            title: "Process usage ranking", readOnly: true, destructive: false,
            idempotent: true, openWorld: false,
            outputSchema: Self.withError([
                "metric": Self.str("The ranking metric that was applied."),
                "window_minutes": Self.int("Requested window."),
                "start_ts": Self.int("First sample in the window, unix seconds."),
                "end_ts": Self.int("Last sample in the window, unix seconds."),
                "sample_count": Self.int("How many samples backed the ranking."),
                "interval_seconds": Self.int("Mean gap between samples."),
                "processes": Self.arr(of: Self.object([
                    "name": Self.str("Process name."),
                    "peak_cpu": Self.num("Highest single-sample CPU percent."),
                    "avg_cpu": Self.num("Mean CPU percent while present."),
                    "est_cpu_time_seconds": Self.num("Estimated cumulative CPU-seconds — sample-derived, not kernel accounting."),
                    "peak_mem": Self.num("Highest memory percent."),
                    "samples": Self.int("Samples this process appeared in."),
                ]), "Ranked by the requested metric."),
            ])),

        "burrow_disk_forecast": Entry(
            title: "Disk-full forecast", readOnly: true, destructive: false,
            idempotent: true, openWorld: false,
            outputSchema: Self.withError([
                "mount": Self.str("Volume the forecast covers."),
                "basis_days": Self.num("How many days of history the fit used."),
                "slope_bytes_per_day": Self.int("Trend in free bytes per day; negative means filling."),
                "days_until_full": ["type": ["number", "null"], "description": "Null when the trend is flat, free space is growing, or there is under a week of history."],
                "samples": Self.int("Free-space samples in the window."),
            ])),

        "burrow_diff": Entry(
            title: "What changed since", readOnly: true, destructive: false,
            idempotent: true, openWorld: false,
            outputSchema: Self.withError([
                "since_ts": Self.int("Unix seconds of the earlier snapshot."),
                "until_ts": Self.int("Unix seconds of the later snapshot."),
                "processes_entered": Self.stringArray,
                "processes_left": Self.stringArray,
                "login_items_added": Self.stringArray,
                "login_items_removed": Self.stringArray,
                "disk_free_delta_bytes": Self.int("Change in free bytes on the largest volume."),
                "note": Self.str("Scope caveats for this diff."),
            ])),

        // Markdown, not JSON — no schema, and no structuredContent.
        "burrow_report": Entry(
            title: "Weekly digest", readOnly: true, destructive: false,
            idempotent: true, openWorld: false, outputSchema: nil),

        "burrow_doctor": Entry(
            title: "Diagnostics", readOnly: true, destructive: false,
            idempotent: true, openWorld: true,
            outputSchema: Self.withError([
                "checks": Self.arr(of: Self.object([
                    "name": Self.str("Check name."),
                    "level": ["type": "string", "enum": ["ok", "warn", "fail"]],
                    "detail": Self.str("One-line explanation."),
                ]), "One entry per diagnostic check."),
            ])),

        "burrow_ports": Entry(
            title: "Listening ports", readOnly: true, destructive: false,
            idempotent: true, openWorld: true,
            outputSchema: Self.withError([
                "count": Self.int("Number of listening sockets."),
                "ports": Self.arr(of: Self.object([
                    "pid": Self.int("Owning process id."),
                    "process": Self.str("Owning process name."),
                    "port": Self.int("Port number."),
                    "proto": Self.str("tcp or udp."),
                    "uid": Self.int("Owning user id."),
                ]), "Listening sockets with their owners."),
            ])),

        "burrow_info": Entry(
            title: "Burrow's own state", readOnly: true, destructive: false,
            idempotent: true, openWorld: false,
            outputSchema: Self.withError([
                "now": Self.int("Server clock, unix seconds."),
                "retention_days": Self.int("How long samples are kept."),
                "sample_interval_seconds": Self.int("Sampler cadence."),
                "decode_skipped_total": Self.int("Rows skipped because they failed to decode."),
                "last_drift": Self.object([:]),
                "readers": Self.arr(of: Self.object([
                    "prefix": Self.str("Data stream name."),
                    "latest_ts": ["type": ["integer", "null"]],
                    "age_seconds": ["type": ["integer", "null"]],
                ]), "One entry per recorded stream, with staleness."),
            ])),

        "burrow_cleanup_history": Entry(
            title: "Cleanup history", readOnly: true, destructive: false,
            idempotent: true, openWorld: true,
            outputSchema: Self.withError([
                "sessions": Self.arr(of: Self.object([:]), "Past cleanup sessions as the engine records them."),
            ])),

        "burrow_deleted_files": Entry(
            title: "Deleted file paths", readOnly: true, destructive: false,
            idempotent: true, openWorld: true,
            outputSchema: Self.withError([
                "count": Self.int("Entries returned."),
                "log": Self.str("Path of the deletion log that was read."),
                "files": Self.arr(of: Self.object([
                    "ts": Self.str("When the deletion happened."),
                    "action": Self.str("trash or remove."),
                    "category": Self.str("Cleanup category."),
                    "status": Self.str("ok or failed."),
                    "path": Self.str("Absolute path that was removed."),
                ]), "Newest first."),
            ])),

        "burrow_analyze": Entry(
            title: "Disk usage breakdown", readOnly: true, destructive: false,
            idempotent: true, openWorld: true,
            outputSchema: Self.withError([
                "entries": Self.arr(of: Self.object([
                    "path": Self.str("Absolute path."),
                    "size": Self.int("Bytes."),
                    "is_dir": ["type": "boolean"],
                    "children": ["type": "array", "items": ["type": "object"], "description": "Present when `depth` descended into this directory."],
                ]), "Immediate children, largest first."),
                "entries_omitted": Self.int("Entries dropped by `limit`/`min_size`."),
                "omitted_bytes": Self.int("Bytes represented by the omitted entries."),
                "partial": ["type": "boolean", "description": "True when the depth descent hit its time budget."],
                "timed_out": ["type": "boolean", "description": "True when the scan was killed before finishing."],
            ])),

        "burrow_list_apps": Entry(
            title: "Installed applications", readOnly: true, destructive: false,
            idempotent: true, openWorld: true,
            outputSchema: Self.withError([
                "apps": ["type": "array", "description": "Installed apps, in the exact form burrow_uninstall accepts."],
            ])),

        "burrow_dupes": Entry(
            title: "Duplicate files", readOnly: true, destructive: false,
            idempotent: true, openWorld: true,
            outputSchema: Self.passthrough("the conductor's `dupes` report")),

        "burrow_net": Entry(
            title: "Per-app network use", readOnly: true, destructive: false,
            idempotent: true, openWorld: true,
            outputSchema: Self.passthrough("the conductor's `net` report")),

        "burrow_orphans": Entry(
            title: "Orphaned files", readOnly: true, destructive: false,
            idempotent: true, openWorld: true,
            outputSchema: Self.passthrough("the conductor's `orphans` report")),

        "burrow_photos": Entry(
            title: "Near-duplicate photos", readOnly: true, destructive: false,
            idempotent: true, openWorld: true,
            outputSchema: Self.passthrough("the conductor's `photos` report")),

        "burrow_rules_dryrun": Entry(
            title: "Rules preview", readOnly: true, destructive: false,
            idempotent: true, openWorld: true,
            outputSchema: Self.passthrough("the conductor's `rules dryrun` report")),

        "burrow_sentinel": Entry(
            title: "Apps in the Trash", readOnly: true, destructive: false,
            idempotent: true, openWorld: true,
            outputSchema: Self.passthrough("the conductor's `sentinel` report")),

        "burrow_slim_check": Entry(
            title: "Fat-binary reclaim estimate", readOnly: true, destructive: false,
            idempotent: true, openWorld: true,
            outputSchema: Self.passthrough("the conductor's `slim-check` report")),

        "burrow_agent_audit": Entry(
            title: "What agents have done", readOnly: true, destructive: false,
            idempotent: true, openWorld: false,
            outputSchema: Self.withError([
                "count": Self.int("Rows returned."),
                "window_minutes": Self.int("The window that was searched."),
                "entries": Self.arr(of: Self.object([
                    "ts": Self.int("Unix seconds the call was made."),
                    "tool": Self.str("Which MCP tool ran."),
                    "client": Self.str("Which surface called it — \"mcp\" for this server."),
                    "dry_run": ["type": "boolean", "description": "True when the call was a preview."],
                    "duration_ms": Self.int("How long the call took."),
                    "ok": ["type": "boolean", "description": "Whether the call succeeded."],
                    "summary": Self.str("First 200 characters of what it returned."),
                    "args": Self.object([:]),
                    "args_raw": Self.str("Present instead of `args` when the stored arguments did not parse."),
                ]), "Newest first."),
            ])),

        "burrow_anomalies": Entry(
            title: "CPU anomalies", readOnly: true, destructive: false,
            idempotent: true, openWorld: false,
            outputSchema: Self.withError([
                "count": Self.int("Findings returned."),
                "findings": Self.arr(of: Self.object([
                    "process": Self.str("Process name."),
                    "recent_median_cpu": Self.num("Median CPU percent over the last 24 hours."),
                    "baseline_median_cpu": Self.num("Median CPU percent over the prior 14 days."),
                ]), "Worst regression first. Empty when there isn't enough history."),
                "basis": Self.str("The comparison that produced these findings."),
            ])),

        // The five that can change the disk. destructiveHint stays true for
        // purge and installer even though MCP only ever previews them: being
        // wrong in the cautious direction costs nothing.
        "burrow_clean": Entry(
            title: "Clean caches and temp files", readOnly: false, destructive: true,
            idempotent: true, openWorld: true, outputSchema: Self.actionResult),

        "burrow_optimize": Entry(
            title: "Run system maintenance", readOnly: false, destructive: false,
            idempotent: true, openWorld: true, outputSchema: Self.actionResult),

        "burrow_uninstall": Entry(
            title: "Uninstall applications", readOnly: false, destructive: true,
            idempotent: true, openWorld: true, outputSchema: Self.actionResult),

        "burrow_purge": Entry(
            title: "Purge build artifacts", readOnly: false, destructive: true,
            idempotent: true, openWorld: true, outputSchema: Self.actionResult),

        "burrow_installer": Entry(
            title: "Remove installer leftovers", readOnly: false, destructive: true,
            idempotent: true, openWorld: true, outputSchema: Self.actionResult),
    ]

    /// Merge annotations, titles, and output schemas into raw descriptors,
    /// and return them in a stable order. The spec asks servers to return
    /// tools deterministically so clients can cache and prompt-cache them;
    /// dictionary iteration order in `descriptors()` is stable today but
    /// sorting makes it a property rather than an accident.
    static func decorate(_ descriptors: [[String: Any]]) -> [[String: Any]] {
        let decorated: [[String: Any]] = descriptors.map { raw in
            guard let name = raw["name"] as? String, let entry = Self.table[name] else { return raw }
            var out = raw
            out["title"] = entry.title
            out["annotations"] = entry.annotations
            if let schema = entry.outputSchema { out["outputSchema"] = schema }
            return out
        }
        return decorated.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
    }

    /// Tools whose work can run for minutes. These are the ones offered as
    /// tasks when the client supports the extension, and the reason the
    /// extension is worth having: today they either block the agent or come
    /// back as `timed_out: true`, which reads like "nothing to do".
    static let longRunning: Set<String> = [
        "burrow_analyze", "burrow_dupes", "burrow_photos", "burrow_orphans",
        "burrow_clean", "burrow_optimize", "burrow_uninstall", "burrow_purge", "burrow_installer",
    ]
}
