//
//  UninstallGuard.swift
//  Burrow
//
//  Pre-flight verification for the Software tab's uninstall. Burrow's confirm sheet shows the apps
//  the USER picked; `uninstall <ids>` does its OWN matching before acting, and if that matcher
//  resolves an argument to more (or different) apps than the one confirmed, the executed set
//  silently diverges from the confirmed set. The guard closes that gap without driving a TTY: run
//  the dry run first (non-destructive), read what it says it will act on, and only proceed when
//  that equals what the user confirmed. Anything unreadable fails CLOSED.
//
//  # The two output contracts, kept structurally apart
//
//  The BUNDLED ENGINE answers every command in the Burrow envelope — `{ok, burrow_cli, command,
//  data|error}` — and never the legacy "Matched N app(s):" text. A real legacy `mo`/MIT-fork binary
//  answers only that text and emits no envelope. `readDryRun` branches on
//  `BurrowEnvelope.inOutput`, the same discriminator every other repointed call site uses, and the
//  two branches share no parsing at all.
//
//  That separation is the fix for a real hazard, not tidiness. The engine's no-match failure
//  message is `"No matching applications found. (<term>)"` — the oracle's wording, kept verbatim
//  by the engine on purpose — and that is the exact sentence `matchedApps` special-cases to mean
//  "the legacy binary matched nothing", i.e. `[]`. Fed engine JSON, the legacy parser therefore
//  returned an EMPTY MATCHED SET rather than nil, and the run only failed closed because an empty
//  set then disagreed with a non-empty confirmed set. Two coincidences deep is not a safety
//  property. So the envelope is now checked FIRST in `readDryRun`, and `matchedApps` additionally
//  refuses envelope-shaped input outright — a stray caller cannot reach the coincidence either.
//
//  # Why it is open now
//
//  It was closed on one blocker: the engine removed an app's `~/Library` leftovers and never the
//  `.app` itself, so "Remove" could not carry out the removal it offered. burrow-engine @ df9ea3f
//  ports `lib/uninstall/batch.sh`'s bundle half — the `.app` goes FIRST, through the same Trash /
//  `--permanent` switch as every other path, and a Homebrew cask goes through
//  `brew uninstall --cask --zap` or not at all. The other two former blockers (one app per
//  invocation; Burrow sending display names) were already fixed, the first in the engine and the
//  second by `SoftwareModel.uninstallBatch`.
//
//  What the guard confirms is now MORE than the old text parser could: `apps[].query` echoes the
//  argument verbatim, so the comparison happens in ONE namespace (bundle ids against bundle ids)
//  instead of comparing sent bundle ids against printed display names, and the same payload also
//  carries the engine's own refusals, its ambiguity verdict, whether elevation is needed and the
//  external commands it will run. The guard reads all of it, because every one of those is a way
//  the run can act on something other than what was confirmed.
//
//  # It never works around a refusal
//
//  The engine keeps five gates — `should_protect_from_uninstall`, `ProtectionMode::Uninstall`,
//  `validate_path_for_deletion`, `--dry-run` beating `--apply`, and the ambiguity refusal. When any
//  of them speaks, this guard SHOWS the refusal and stops. It never re-issues the command with
//  different arguments, never drops the refused app and runs the rest, and never retries.
//

import Foundation

enum UninstallGuard {

    // MARK: - The dry run's plan (engine)

    /// One app's bundle as the dry run describes it — `apps[].application`.
    struct ApplicationPlan: Equatable {
        /// The `.app` path the apply will act on.
        let path: String
        /// False when the bundle is already gone. The engine calls that a success and still sweeps
        /// the leftovers, so it is not a problem — but it does change what the run will report.
        let present: Bool
        let sizeHuman: String?
        /// The engine's `needs_sudo` port. Burrow's uninstall ticket is NOT elevated
        /// (`MoAction.spec`'s `elevatedRealRunGUI: false`), so this is what the run will trip on.
        let needsAdmin: Bool
        /// `"delete"` (Trash, or outright under `--permanent`) or `"brew_zap"`.
        let action: String
        /// The Homebrew cask token, set exactly when `action == "brew_zap"`.
        let cask: String?
        /// Non-nil when `validate_path_for_deletion` / `should_protect_path` ALREADY declines this
        /// bundle. The dry run computes it so a preview never promises what the apply will refuse.
        let refusal: String?

        var isHomebrewCask: Bool { action == "brew_zap" }
    }

    /// One resolved app in `apps[]`.
    struct AppPlan: Equatable {
        /// `apps[].query` — the argument Burrow sent, echoed back verbatim. This is what makes the
        /// confirmation exact: it is compared against the very strings `uninstallBatch` produced,
        /// with no name/id translation on either side.
        let query: String
        let name: String
        let bundleId: String
        let application: ApplicationPlan
    }

    /// A term the engine's substring sweep resolved to more than one app. The engine REFUSES such
    /// an `--apply` outright; the dry run declares it so a caller can stop first.
    struct Ambiguity: Equatable {
        let query: String
        let names: [String]
    }

    /// A state change outside the enumerated paths — today, `brew uninstall --cask --zap <token>`.
    /// `--zap` runs the cask's own zap stanza, which deletes paths no enumeration can predict, so
    /// the command is declared rather than merely implied.
    struct ExternalCommand: Equatable {
        let name: String
        let command: String
        let note: String?
    }

    /// The engine's whole dry-run answer, decoded.
    struct Plan: Equatable {
        let apps: [AppPlan]
        /// Arguments that resolved to no installed app.
        let unmatched: [String]
        let ambiguous: [Ambiguity]
        /// How many bundles the apply will actually remove.
        let removesApplications: Int
        /// True when ANY bundle needs elevation Burrow's un-elevated ticket does not have.
        let requiresAdmin: Bool
        let externalCommands: [ExternalCommand]
        /// Engine-side advisories (e.g. running as root looked for leftovers under `/var/root`).
        let warnings: [String]
        let totalHuman: String?

        /// Apps the engine says it will hand-delete (Trash / `--permanent`), i.e. not brew.
        var directRemovals: [AppPlan] { apps.filter { !$0.application.isHomebrewCask } }
        /// Apps Homebrew will remove with `--zap`.
        var homebrewRemovals: [AppPlan] { apps.filter { $0.application.isHomebrewCask } }
        /// Apps whose bundle a protection rail already declines.
        var refusedApps: [AppPlan] { apps.filter { $0.application.refusal != nil } }
        var adminApps: [AppPlan] { apps.filter { $0.application.needsAdmin } }
    }

    /// What one dry-run capture turned out to be. The four cases are disjoint by construction —
    /// the envelope discriminator is checked before any text parsing happens — so no output can be
    /// read as two of them, which is the whole point of the type.
    enum DryRun: Equatable {
        /// The bundled engine, `ok:true`: a decoded plan.
        case engine(Plan)
        /// The bundled engine, `ok:false`: it refused or failed, and this is its own message
        /// (a protected component, a bad identifier, both `--dry-run` and `--apply`, …).
        case engineRefused(String)
        /// A legacy `mo`/MIT-fork binary's "Matched N app(s):" list, or `[]` for its
        /// "No matching applications found." — display names, the only namespace it speaks.
        case legacy([String])
        /// Neither shape. Fail closed.
        case unreadable
    }

    /// Read one `uninstall --dry-run` capture.
    ///
    /// `stdout` is the ONLY place an envelope can be: the engine writes its failures there too and
    /// nothing to stderr (`BurrowEnvelope`'s measurements). `stderr` is joined in for the legacy
    /// path only, where mo decorates and diagnoses across both streams.
    static func readDryRun(stdout: String, stderr: String) -> DryRun {
        if let envelope = BurrowEnvelope.inOutput(stdout) {
            guard envelope.ok, let data = envelope.data,
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                // A refusal, or a success envelope whose payload we cannot read. Both stop the run;
                // the message is the engine's own where it has one.
                let reason = (envelope.error?.message ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .engineRefused(reason.isEmpty
                    ? "the engine's dry run returned no readable plan"
                    : reason)
            }
            return .engine(decodePlan(payload))
        }
        guard let matched = matchedApps(inDryRunOutput: stdout + "\n" + stderr) else {
            return .unreadable
        }
        return .legacy(matched)
    }

    private static func decodePlan(_ payload: [String: Any]) -> Plan {
        let apps: [AppPlan] = (payload["apps"] as? [[String: Any]] ?? []).compactMap { row in
            guard let query = row["query"] as? String else { return nil }
            let app = row["application"] as? [String: Any] ?? [:]
            return AppPlan(
                query: query,
                name: row["name"] as? String ?? query,
                bundleId: row["bundle_id"] as? String ?? "",
                application: ApplicationPlan(
                    path: app["path"] as? String ?? "",
                    present: app["present"] as? Bool ?? false,
                    sizeHuman: app["size_human"] as? String,
                    needsAdmin: app["needs_admin"] as? Bool ?? false,
                    action: app["action"] as? String ?? "delete",
                    cask: app["cask"] as? String,
                    refusal: app["refusal"] as? String))
        }
        let ambiguous: [Ambiguity] = (payload["ambiguous"] as? [[String: Any]] ?? []).compactMap {
            guard let query = $0["query"] as? String else { return nil }
            return Ambiguity(query: query, names: $0["names"] as? [String] ?? [])
        }
        let external: [ExternalCommand] = (payload["external_commands"] as? [[String: Any]] ?? []).compactMap {
            guard let command = $0["command"] as? String else { return nil }
            return ExternalCommand(name: $0["name"] as? String ?? "",
                                   command: command,
                                   note: $0["note"] as? String)
        }
        return Plan(apps: apps,
                    unmatched: payload["unmatched"] as? [String] ?? [],
                    ambiguous: ambiguous,
                    removesApplications: payload["removes_applications"] as? Int ?? 0,
                    requiresAdmin: payload["requires_admin"] as? Bool ?? false,
                    externalCommands: external,
                    warnings: payload["warnings"] as? [String] ?? [],
                    totalHuman: payload["total_human"] as? String)
    }

    // MARK: - The verdict

    /// Why this run must NOT proceed, or nil when the dry run confirms exactly the confirmed set.
    ///
    /// Every case here is a way the apply would act on something other than what the user agreed
    /// to, or a refusal the engine has already declared. A refusal is REPORTED, never routed
    /// around: there is deliberately no branch that drops a refused app and runs the remainder.
    static func abortReason(confirmed: [String], dryRun: DryRun) -> String? {
        switch dryRun {
        case .unreadable:
            return NSLocalizedString("The dry run's output wasn't in a format Burrow can confirm a matched set from, so nothing was removed.", comment: "uninstall preflight")

        case .engineRefused(let message):
            return String(format: NSLocalizedString("The engine refused the dry run, so nothing was removed: %@", comment: "uninstall preflight"),
                          message)

        case .legacy(let matched):
            return mismatchDescription(confirmed: confirmed, matched: matched)

        case .engine(let plan):
            // 1. The set itself, in one namespace: `query` is literally the argument we sent.
            //    Compared as bundle ids on purpose — display names are the ambiguity this whole
            //    path exists to remove — but rendered with the engine's own name beside the id,
            //    since "com.crossover.steam" alone tells a user who picked Steam very little.
            var labels: [String: String] = [:]
            for app in plan.apps where !app.name.isEmpty {
                labels[app.query.lowercased()] = "\(app.name) (\(app.query))"
            }
            if let mismatch = mismatchDescription(confirmed: confirmed,
                                                  matched: plan.apps.map(\.query),
                                                  labels: labels) {
                return mismatch
            }
            // 2. An argument that matched nothing. `apps[]` cannot carry it, so (1) usually catches
            //    this — but naming the argument is a better answer than "did not match".
            if !plan.unmatched.isEmpty {
                return String(format: NSLocalizedString("The engine matched no installed app for: %@", comment: "uninstall preflight"),
                              plan.unmatched.joined(separator: ", "))
            }
            // 3. The engine's own ambiguity verdict. It REFUSES this apply; stopping here shows the
            //    user which term was over-broad instead of letting the run bounce off the refusal.
            if let ambiguity = plan.ambiguous.first {
                return String(format: NSLocalizedString("“%1$@” resolves to %2$d applications (%3$@), so the engine refuses to act on it. Remove them one at a time.", comment: "uninstall preflight"),
                              ambiguity.query, ambiguity.names.count,
                              ambiguity.names.prefix(6).joined(separator: ", "))
            }
            // 4. A count divergence with matching sets means one argument resolved several rows —
            //    the same shape as (3) by a different route. Fail closed rather than assume.
            if plan.apps.count != confirmed.count {
                return String(format: NSLocalizedString("The engine resolved %1$d applications for %2$d selected, so the sets don't line up.", comment: "uninstall preflight"),
                              plan.apps.count, confirmed.count)
            }
            // 5. A protection rail already declines one of these bundles. Show it verbatim.
            if let refused = plan.refusedApps.first, let reason = refused.application.refusal {
                return String(format: NSLocalizedString("The engine won't remove %1$@: %2$@", comment: "uninstall preflight"),
                              refused.name, reason)
            }
            return nil
        }
    }

    /// Facts the dry run turned up that the run's REPORT has to mention — they do not block, and
    /// deliberately so.
    ///
    /// `requiresAdmin` in particular is NOT an abort: the engine's `needs_admin` is an `access(2)`
    /// approximation that does not consult ACLs, so refusing on it would block removals that would
    /// have worked. The engine attempts the removal regardless and, if it fails, reports the
    /// oracle's own `"Re-run with administrator privileges"` suggestion — which `Outcome` surfaces.
    static func advisories(for plan: Plan) -> [String] {
        var out: [String] = []
        if plan.requiresAdmin {
            let names = plan.adminApps.map(\.name).joined(separator: ", ")
            out.append(String(format: NSLocalizedString("Needs an administrator: %@. Burrow doesn't elevate this run, so it may fail on the app itself.", comment: "uninstall advisory"),
                              names.isEmpty ? NSLocalizedString("one of these apps", comment: "uninstall advisory") : names))
        }
        for command in plan.externalCommands {
            out.append(String(format: NSLocalizedString("Homebrew removes %1$@: `%2$@`. `--zap` also deletes configuration and data the cask declares, which the preview can't list.", comment: "uninstall advisory"),
                              command.name, command.command))
        }
        out.append(contentsOf: plan.warnings)
        return out
    }

    // MARK: - What actually happened (apply)

    /// One app's bundle after the apply — `apps[].application`.
    struct ApplicationOutcome: Equatable {
        let path: String
        /// `removed` | `absent` | `refused` | `failed`.
        let state: String
        /// `trash` | `permanent` | `brew`, when it was removed. Brew is NOT recoverable — brew
        /// unlinks, it does not Trash — so this is what a report may claim, never an assumption.
        let via: String?
        let reason: String?
        /// The engine's own remediation text. This is the user's next action; it must be shown.
        let suggestion: String?
    }

    /// One app's verdict — `apps[].status`.
    struct AppOutcome: Equatable {
        let query: String
        let name: String
        /// `removed` | `partial` | `refused`.
        let status: String
        let application: ApplicationOutcome
        /// False when the bundle didn't come away: the engine then leaves the support files alone
        /// too (`batch.sh:840`), because half-uninstalling an app leaves it broken rather than
        /// merely present.
        let leftoversAttempted: Bool
        let freedHuman: String?

        var succeeded: Bool { status == "removed" }
    }

    struct Outcome: Equatable {
        let apps: [AppOutcome]
        let applicationsRemoved: Int
        let applicationsRefused: Int
        let freedHuman: String?
        let warnings: [String]

        var allRemoved: Bool { !apps.isEmpty && apps.allSatisfy(\.succeeded) }
        var problems: [AppOutcome] { apps.filter { !$0.succeeded } }
    }

    /// Decode an `uninstall --apply` capture, or nil when it isn't an `ok:true` engine envelope
    /// (a legacy `mo` answered, or the run failed — the caller reports the failure separately).
    static func readOutcome(stdout: String) -> Outcome? {
        guard let envelope = BurrowEnvelope.inOutput(stdout), envelope.ok,
              let data = envelope.data,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = payload["apps"] as? [[String: Any]]
        else { return nil }
        let apps: [AppOutcome] = rows.compactMap { row in
            guard let query = row["query"] as? String else { return nil }
            let app = row["application"] as? [String: Any] ?? [:]
            return AppOutcome(
                query: query,
                name: row["name"] as? String ?? query,
                status: row["status"] as? String ?? "",
                application: ApplicationOutcome(
                    path: app["path"] as? String ?? "",
                    state: app["state"] as? String ?? "",
                    via: app["via"] as? String,
                    reason: app["reason"] as? String,
                    suggestion: app["suggestion"] as? String),
                leftoversAttempted: row["leftovers_attempted"] as? Bool ?? false,
                freedHuman: row["freed_human"] as? String)
        }
        return Outcome(apps: apps,
                       applicationsRemoved: payload["applications_removed"] as? Int ?? 0,
                       applicationsRefused: payload["applications_refused"] as? Int ?? 0,
                       freedHuman: payload["freed_human"] as? String,
                       warnings: payload["warnings"] as? [String] ?? [])
    }

    /// The user-facing account of a run that did not fully succeed, or nil when every app came
    /// away. One paragraph per app: what happened to the application, whether its support files
    /// were even attempted, and — where the engine offers one — the next action.
    ///
    /// "The leftovers went and the app did not" USED to report as a success. `status` makes that
    /// impossible to miss and this is where it stops being missable to a person.
    static func problemReport(_ outcome: Outcome) -> String? {
        let problems = outcome.problems
        guard !problems.isEmpty else { return nil }
        var blocks: [String] = problems.map { app in
            var line: String
            switch app.application.state {
            case "refused":
                line = String(format: NSLocalizedString("%@ — the engine refused to remove the application.", comment: "uninstall outcome"), app.name)
            case "failed":
                line = String(format: NSLocalizedString("%@ — the application could not be removed.", comment: "uninstall outcome"), app.name)
            case "removed", "absent":
                // The bundle went (or was already gone) and something else did not: support files.
                line = String(format: NSLocalizedString("%@ — the application was removed, but some of its support files were not.", comment: "uninstall outcome"), app.name)
            default:
                line = String(format: NSLocalizedString("%@ — the removal finished partly.", comment: "uninstall outcome"), app.name)
            }
            if let reason = app.application.reason, !reason.isEmpty {
                line += "\n  " + reason
            }
            if !app.leftoversAttempted {
                line += "\n  " + NSLocalizedString("Its support files were left alone, so the app is still installed rather than half-removed.", comment: "uninstall outcome")
            }
            if let suggestion = app.application.suggestion, !suggestion.isEmpty {
                line += "\n  " + String(format: NSLocalizedString("Next: %@", comment: "uninstall outcome"), suggestion)
            }
            return line
        }
        blocks.append(contentsOf: outcome.warnings)
        return blocks.joined(separator: "\n\n")
    }

    // MARK: - Legacy text format (a real `mo` / MIT fork only)

    /// App names a legacy `mo` reports it matched, parsed from its (ANSI-decorated)
    /// `uninstall --dry-run` output:
    ///
    ///     ◎ Matched 2 app(s):
    ///     1. Slack  120MB  |  Last: 2d ago
    ///     2. Python Launcher  315KB  |  Last: 1y ago
    ///
    /// Returns `[]` for "No matching applications found.", the parsed names for a matched list, and
    /// nil when the output fits neither shape (parse failure → the caller must abort).
    ///
    /// **Envelope-shaped input is refused outright**, before any of that. The engine's own
    /// no-match failure carries the identical "No matching applications found." sentence — it keeps
    /// the oracle's wording deliberately — so without this check engine JSON parses to `[]`, an
    /// answer this function has no business giving about a binary it cannot read. `readDryRun`
    /// already routes by envelope and never calls this on engine output; the guard here is so that
    /// a future caller which forgets cannot reach the coincidence either.
    static func matchedApps(inDryRunOutput raw: String) -> [String]? {
        if BurrowEnvelope.inOutput(raw) != nil { return nil }
        let text = Ansi.strip(raw)
        if text.contains("No matching applications found") { return [] }

        let lines = text.components(separatedBy: .newlines)
        guard let headerIdx = lines.firstIndex(where: {
            $0.contains("Matched") && $0.contains("app(s):")
        }) else { return nil }

        var names: [String] = []
        for line in lines[(headerIdx + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }   // blank line ends the list
            guard let ordinal = trimmed.range(of: #"^\d+\.\s+"#,
                                              options: .regularExpression) else { break }
            // The name sits between the "N. " ordinal and the two-space
            // column gap before the size — app names can contain single
            // spaces ("Python Launcher"), columns are separated by two.
            let rest = trimmed[ordinal.upperBound...]
            let name = rest.range(of: "  ").map { String(rest[..<$0.lowerBound]) } ?? String(rest)
            let cleaned = name.trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty { names.append(cleaned) }
        }
        // A "Matched N" header with no parseable rows is a format we don't
        // understand — fail closed rather than claim "nothing matched".
        return names.isEmpty ? nil : names
    }

    /// Human-readable description of how `matched` diverges from `confirmed`, or nil when the sets
    /// agree. Case-insensitive: on the legacy path both sides are mo's own canonical display names,
    /// and on the engine path both sides are the same bundle-id strings Burrow sent, so folding
    /// case can only ever forgive a difference neither producer introduces.
    ///
    /// `labels` maps a lowercased term to how it should READ (the engine supplies
    /// `"Steam (com.valvesoftware.steam)"`); the comparison itself never touches it. Only the
    /// matched side can be labelled — a confirmed term that resolved to nothing has no name to
    /// borrow, which is exactly why it went missing.
    static func mismatchDescription(confirmed: [String], matched: [String],
                                    labels: [String: String] = [:]) -> String? {
        let confirmedSet = Set(confirmed.map { $0.lowercased() })
        let matchedSet = Set(matched.map { $0.lowercased() })
        guard confirmedSet != matchedSet else { return nil }

        var parts: [String] = []
        let extra = matched.filter { !confirmedSet.contains($0.lowercased()) }
            .map { labels[$0.lowercased()] ?? $0 }
        let missing = confirmed.filter { !matchedSet.contains($0.lowercased()) }
        if !extra.isEmpty {
            parts.append(String(format: NSLocalizedString("mo would also remove: %@", comment: ""),
                                extra.joined(separator: ", ")))
        }
        if !missing.isEmpty {
            parts.append(String(format: NSLocalizedString("mo did not match: %@", comment: ""),
                                missing.joined(separator: ", ")))
        }
        return parts.joined(separator: " · ")
    }
}
