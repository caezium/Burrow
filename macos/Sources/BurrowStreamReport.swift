//
//  BurrowStreamReport.swift
//  Burrow
//
//  Reduces the NDJSON progress feed from `burrow-engine clean --stream` / `optimize --stream`
//  into the (groups, summary) shape TaskReportView renders — the same TaskRunReport the old
//  human-text `parseTaskReport` produced, so the Clean/Optimize views + completion notification
//  are unchanged. The engine emits one JSON object per line:
//
//    clean live:    {"event":"removed","path":P,"bytes":N} | {"event":"failed",...} |
//                   {"event":"protected","path":P,"reason":R?}  then  {"event":"done",
//                   "freed_bytes":N,"freed_human":H,"moved_to_trash_bytes":N,
//                   "moved_to_trash_human":H,"removed":N,"failed":N,"protected":N}
//    clean preview: {"event":"would_remove","path":P,"bytes":N}  then  {"event":"done",
//                   "dry_run":true,"would_free_bytes":N,"would_free_human":H,"count":N}
//    optimize live: {"event":"task","name":T,"ok":B,"error":E|null[,"skipped":true,
//                   "reason":R]}  then  {"event":"done","ok":B,"tasks":N,"failed":N}
//    optimize prev: {"event":"would_run","name":T,"description":D}  then  {"event":"done",
//                   "dry_run":true,"tasks":N}
//
//  `purge --stream` speaks exactly the clean vocabulary over build artifacts, and a reviewed
//  `clean --apply --plan <file>` speaks it over the plan's paths (a path the engine refuses is a
//  `protected` line with `reason:"not_a_clean_target"`), so one reducer serves all of them.
//
//  Parsed line-by-line with JSONSerialization (like BurrowEnvelope) — the reduce is called on the
//  accumulated `[String]` after every streamed line (throttled) and once at exit. Output that
//  isn't NDJSON at all (a legacy Homebrew `mo`, reachable when no conductor is bundled) falls
//  through to `parseTaskReport` rather than reducing to a blank report — see `reduce`.
//

import Foundation

enum BurrowStreamReport {
    /// The card title for a streamed run's one group, decided by the mo-style argv the operation
    /// was built with rather than inferred from the events that come back.
    ///
    /// Inferring would half-work: clean and optimize emit disjoint event vocabularies today
    /// (`removed`/`would_remove`/`protected` vs `task`/`would_run`), so a mapping off the event
    /// name is possible — but it has nothing to go on for a run whose only line is `done`, and it
    /// silently mistitles the day the engine adds an event. The argv is settled before the process
    /// even spawns and is the operation's own statement of which tool it is, so every streamed
    /// ToolOperation passes it through here and no run can be labelled as the other tool.
    static func groupTitle(forMo moArgs: [String]) -> String {
        moArgs.first == "optimize"
            ? NSLocalizedString("Maintenance", comment: "streamed optimize group title")
            : cleanupTitle
    }

    private static var cleanupTitle: String {
        NSLocalizedString("Cleanup", comment: "streamed clean group title")
    }

    /// Reduce the accumulated NDJSON lines into a TaskRunReport. Unparseable / non-event lines are
    /// skipped, so a stray warning on stderr never breaks the result screen. `title` names the one
    /// group the items land in — pass `groupTitle(forMo:)`; the default keeps clean's wording for
    /// the clean-only callers.
    static func reduce(_ lines: [String], title: String? = nil,
                       categoryOf: ((String) -> String?)? = nil) -> TaskRunReport {
        var items: [TaskItem] = []
        // `categoryOf` groups items back under the review categories the user ticked them in
        // (the reviewed clean); without it every item lands in the one `title` group.
        var groupNames: [String] = []
        var grouped: [String: [TaskItem]] = [:]
        var summary: TaskSummary?

        func add(_ item: TaskItem, path: String?) {
            items.append(item)
            guard let categoryOf else { return }
            let name = path.flatMap(categoryOf) ?? title ?? cleanupTitle
            if grouped[name] == nil { groupNames.append(name) }
            grouped[name, default: []].append(item)
        }

        for line in lines {
            guard let obj = object(from: line), let event = obj["event"] as? String else { continue }
            switch event {
            case "removed":
                if let p = obj["path"] as? String { add(TaskItem(marker: .ok, text: p), path: p) }
            case "would_remove":
                if let p = obj["path"] as? String { add(TaskItem(marker: .action, text: p), path: p) }
            case "failed":
                if let p = obj["path"] as? String { add(TaskItem(marker: .error, text: p), path: p) }
            case "protected":
                // A refusal is never silently dropped: it lands in the report with the
                // engine's reason when it gives one (`not_a_clean_target` for a plan path
                // outside the clean roots), so the user can see WHAT was left and why.
                if let p = obj["path"] as? String {
                    add(TaskItem(marker: .review, text: protectedText(p, reason: obj["reason"] as? String)), path: p)
                }
            case "task":
                if let name = obj["name"] as? String {
                    let ok = obj["ok"] as? Bool ?? true
                    if obj["skipped"] as? Bool == true {
                        // Skipped is not failed: nothing was attempted. The engine says why
                        // (`requires_admin` when an un-elevated run met a root-only task).
                        add(TaskItem(marker: .info,
                                     text: skippedText(name, reason: obj["reason"] as? String)), path: nil)
                    } else {
                        add(TaskItem(marker: ok ? .ok : .error, text: name), path: nil)
                    }
                }
            case "would_run":
                if let name = obj["name"] as? String { add(TaskItem(marker: .action, text: name), path: nil) }
            case "done":
                summary = makeSummary(from: obj, itemCount: items.count)
            default:
                break
            }
        }

        let groups: [TaskGroup]
        if items.isEmpty {
            groups = []
        } else if categoryOf != nil {
            groups = groupNames.map { TaskGroup(title: $0, items: grouped[$0] ?? []) }
        } else {
            groups = [TaskGroup(title: title ?? cleanupTitle, items: items)]
        }

        // Nothing was NDJSON → parse the lines as mo's human text instead of returning a blank
        // report. That path is live, not hypothetical: `OperationFlow.start` only appends
        // `--stream` when a conductor is bundled (`BurrowEngine.streamOverride`), and when one
        // isn't, `resolveEngine` can land on a legacy Homebrew `/opt/homebrew/bin/mo`
        // (`EngineCLI.trustedExecutable`), which speaks the ➤/→ marker grammar `parseTaskReport`
        // was written for. Putting the fallback in the reducer rather than in a view means the
        // result screen AND the completion notification (whose detail line is derived from this
        // same report, via `ToolOperation.finalDetail`) both get it.
        //
        // Both empty is the trigger, never either alone. A streamed run that legitimately did
        // nothing — a clean machine — still ends with a `done` event, so it returns empty `groups`
        // WITH a summary and is kept as-is. And when the trigger does fire on NDJSON or on no
        // output at all, `parseTaskReport` returns exactly the empty report we'd have returned
        // anyway: it needs a ➤ or marker line to open a group, drops groups that end up with no
        // items, and its bare-header branch rejects any line containing a `:` — which every JSON
        // line has. So the fallback can only add a report, never fabricate one.
        if groups.isEmpty, summary == nil { return parseTaskReport(lines) }
        return (groups: groups, summary: summary)
    }

    /// A short human label for the HUD detail line, extracted from one NDJSON event. Empty for the
    /// terminal `done` (the HUD keeps the last item line) or an unparseable line.
    static func hudLine(_ line: String) -> String {
        guard let obj = object(from: line), let event = obj["event"] as? String else { return "" }
        switch event {
        case "removed", "would_remove", "failed", "protected":
            if let p = obj["path"] as? String { return (p as NSString).lastPathComponent }
        case "task", "would_run":
            if let name = obj["name"] as? String { return name }
        default:
            break
        }
        return ""
    }

    /// Per-line byte delta for a live count-up total (CleanView's dry-run scan hero number):
    /// the size this one line reports as would-be-removed (preview) or removed (live), 0 for
    /// anything else. The `done` line's own total is authoritative once it lands (CleanView
    /// prefers `summary.space` at that point) — this only drives the animation before then.
    /// Mirrors `CleanList.streamedItemBytes`'s role for the old human-text format.
    static func streamedBytes(_ line: String) -> Int64 {
        guard let obj = object(from: line), let event = obj["event"] as? String,
              event == "removed" || event == "would_remove",
              let bytes = intField(obj, "bytes") else { return 0 }
        return Int64(bytes)
    }

    // MARK: - internals

    /// "path — protected (reason)". Pure, so the wording is pinned by a test.
    static func protectedText(_ path: String, reason: String?) -> String {
        switch reason {
        case nil, "":
            return String(format: NSLocalizedString("%@ — protected", comment: "clean refusal"), path)
        case "not_a_clean_target":
            return String(format: NSLocalizedString("%@ — refused: not a clean target", comment: "plan refusal"), path)
        case let r?:
            return String(format: NSLocalizedString("%@ — protected (%@)", comment: "clean refusal with reason"), path, r)
        }
    }

    /// "task — skipped (needs administrator)". Pure, so the wording is pinned by a test.
    static func skippedText(_ name: String, reason: String?) -> String {
        switch reason {
        case "requires_admin":
            return String(format: NSLocalizedString("%@ — skipped (needs administrator)", comment: "optimize skip"), name)
        case nil, "":
            return String(format: NSLocalizedString("%@ — skipped", comment: "optimize skip"), name)
        case let r?:
            return String(format: NSLocalizedString("%@ — skipped (%@)", comment: "optimize skip with reason"), name, r)
        }
    }

    private static func object(from line: String) -> [String: Any]? {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.first == "{", let data = t.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    /// Build the summary from a `done` event, covering both the live and preview shapes of clean
    /// and optimize. `itemCount` is the number of accumulated item lines (fallback when a specific
    /// count field is absent).
    private static func makeSummary(from done: [String: Any], itemCount: Int) -> TaskSummary {
        // Freed disk (live clean) vs would-free (preview) vs no size (optimize). On the
        // engine's default Trash path `freed_bytes` is 0 and the bytes are in
        // `moved_to_trash_bytes`; a zero freed figure is dropped rather than rendered as
        // "Cleaned 0B" beside the Trash figure. A live run that moved everything to the Trash
        // therefore reads "1.2GB moved to Trash · 5 items", never "Cleaned 1.2GB".
        let trashedBytes = intField(done, "moved_to_trash_bytes") ?? 0
        let trashed = trashedBytes > 0
            ? (done["moved_to_trash_human"] as? String ?? Fmt.bytes(Int64(trashedBytes)))
            : ""
        let freedHuman: String?
        if let freed = intField(done, "freed_bytes") {
            freedHuman = freed > 0 ? (done["freed_human"] as? String ?? Fmt.bytes(Int64(freed))) : nil
        } else {
            freedHuman = done["freed_human"] as? String
        }
        let wouldFreeHuman = done["would_free_human"] as? String
        let space = freedHuman ?? wouldFreeHuman ?? ""

        // Item count: removed (clean live) → count (clean preview) → tasks (optimize) → accumulated.
        let count = intField(done, "removed")
            ?? intField(done, "count")
            ?? intField(done, "tasks")
            ?? itemCount
        let items = count > 0 ? String(count) : ""

        // `freed_bytes`/`freed_human` is the PLANNER's own tally of what it queued for removal
        // (`outcome.freed_bytes += c.size`, summed before deletion — see clean/execute.rs), not a
        // measured before/after disk delta; on APFS with clones those can diverge. That belongs
        // in `space` ("Cleaned X"), same as the preview's `would_free_human` — never in
        // `freeChange` ("Freed X"), which TaskSummary reserves for an actual "Free space change:"
        // reading. The engine doesn't emit that at all yet, so `freeChange` stays empty here; the
        // old human-text parser mapped its equivalent live-clean line to `space` for the same
        // reason (see `parseTaskReport`'s "Tracked cleanup:" handling).
        return TaskSummary(space: space, items: items, categories: "", trashed: trashed)
    }

    /// Read an integer field regardless of whether JSONSerialization bridged it to Int or Double.
    private static func intField(_ obj: [String: Any], _ key: String) -> Int? {
        if let n = obj[key] as? Int { return n }
        if let d = obj[key] as? Double { return Int(d) }
        return nil
    }
}
