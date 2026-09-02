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
        /// `apps[].query` — the argument Burrow sent, echoed back verbatim.
        ///
        /// On its own this confirms NOTHING about identity, and believing otherwise is what let an
        /// agent delete an application it never named: ask for `"unknown"` and the echo is
        /// `"unknown"`, so asked and echoed agree perfectly while the engine quietly resolved
        /// Synergy. The comparison that matters is `query` against `name`/`bundleId`/`path` below —
        /// what the engine RESOLVED — not `query` against itself.
        let query: String
        let name: String
        let bundleId: String
        /// `apps[].path` — the `.app` the engine resolved this query to. The identity a caller can
        /// check against the inventory row it meant, and the reason this field is decoded at all.
        let path: String
        let application: ApplicationPlan

        /// Whether `query` NAMES this app rather than merely having matched it.
        ///
        /// The engine resolves in three passes (`resolve.rs:135-165`): an exact display-name or
        /// containing-directory hit, then an exact bundle-id or cask-token hit, then a SUBSTRING
        /// SWEEP over names and directories with no early exit. Only the first two are a caller
        /// naming an app; the third is the engine picking apps out of a fragment, and `uninstall e`
        /// resolving 66 rows is the same mechanism as `uninstall unknown` resolving Synergy.
        ///
        /// The dry run does not say which pass fired, so this asks the question from the answer's
        /// side: does the term equal what the engine says this app IS? Case-insensitive, because
        /// the engine lowercases both sides before comparing (`"UNKNOWN"` resolves Synergy too,
        /// verified against the real binary).
        ///
        /// A cask token that is not the app's own name (`visual-studio-code` → "Visual Studio
        /// Code") fails this and is refused with a message pointing at the bundle id. That is the
        /// deliberate trade: a caller that must re-issue with an exact identifier costs one round
        /// trip; a caller that deletes an app it did not name costs the app.
        func isNamedBy(_ term: String) -> Bool {
            let t = term.trimmingCharacters(in: .whitespaces)
            return t.caseInsensitiveCompare(name) == .orderedSame
                || t.caseInsensitiveCompare(bundleId) == .orderedSame
        }
    }

    /// The inventory row a caller MEANT when it put `query` on argv — the identity the engine's own
    /// resolution is checked against.
    ///
    /// Supplied by the GUI, which selected a row and knows exactly which one; a surface that has
    /// only strings (the MCP tool takes an agent's `apps[]`) passes none, and is held to
    /// [`AppPlan.isNamedBy`] plus [`isSendableArgument`] instead.
    struct Expectation: Equatable {
        let query: String
        let name: String
        let path: String
        let bundleId: String
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

    static func decodePlan(_ payload: [String: Any]) -> Plan {
        let apps: [AppPlan] = (payload["apps"] as? [[String: Any]] ?? []).compactMap { row in
            guard let query = row["query"] as? String else { return nil }
            let app = row["application"] as? [String: Any] ?? [:]
            return AppPlan(
                query: query,
                name: row["name"] as? String ?? query,
                bundleId: row["bundle_id"] as? String ?? "",
                // `apps[].path` and `apps[].application.path` are the same bundle in the engine's
                // own emitter; reading the row's first and falling back keeps the identity check
                // alive if either ever goes missing rather than silently comparing against "".
                path: (row["path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (app["path"] as? String ?? ""),
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

    // MARK: - What may go on argv at all

    /// The literal `uninstall --list` records as the `bundle_id` of a bundle with no
    /// `CFBundleIdentifier` — five rows on the machine this was verified against.
    static let placeholderBundleID = "unknown"

    /// Whether one positional may reach `uninstall`'s argv. THE SAME PREDICATE ON EVERY SURFACE —
    /// the GUI's selection, the MCP tool's `apps[]`, and the guard's own last look before an apply.
    ///
    /// It was previously the GUI's alone (`SoftwareModel.isSendableBundleID`), and the MCP path
    /// trimmed-and-dropped-empties instead. That gap was live: `burrow_list_apps` hands agents
    /// `"unknown"` verbatim on every row with no `CFBundleIdentifier`, and
    /// `uninstall --dry-run unknown` resolves it — through the engine's exact bundle-id pass, so
    /// no ambiguity is reported — to whichever such row comes first (Synergy, verified). Every
    /// other rail then agreed with itself: the query set matched, nothing was unmatched, nothing
    /// ambiguous, no refusal. The apply deleted an application the caller never named.
    ///
    /// The three refused values, all verified against the real binary:
    ///
    ///  - **`""`** — an empty positional survives `positionals` and reaches the substring sweep,
    ///    whose `name.contains("")` is true of every row: 135 apps resolved as one.
    ///  - **`"unknown"`, case-insensitively** — the placeholder above. The engine lowercases both
    ///    sides before comparing, so `"UNKNOWN"` and `"Unknown"` resolve Synergy just as readily;
    ///    a case-sensitive check would have been a hole on any surface taking free text.
    ///  - **a leading `-`** — `positionals` skips it, so the run silently acts on fewer apps than
    ///    it reported acting on.
    ///
    /// An app whose bundle has no identifier is still removable: it is named
    /// (`uninstall Synergy` resolves by display name). What is refused is the placeholder standing
    /// in for the identity, which names nothing.
    static func isSendableArgument(_ term: String) -> Bool {
        let t = term.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty
            && t.caseInsensitiveCompare(placeholderBundleID) != .orderedSame
            && !t.hasPrefix("-")
    }

    // MARK: - The verdict

    /// Why this run must NOT proceed, or nil when the dry run confirms exactly the confirmed set.
    ///
    /// Every case here is a way the apply would act on something other than what the user agreed
    /// to, or a refusal the engine has already declared. A refusal is REPORTED, never routed
    /// around: there is deliberately no branch that drops a refused app and runs the remainder.
    ///
    /// `expecting` is the caller's own answer to "which row did I mean", one entry per argument,
    /// and it is the only thing here that can catch a resolution that is internally consistent and
    /// still wrong. It has no default: a surface with no expectation must say so, because the
    /// alternative — a defaulted `[]` — is how the identity check would quietly stop running.
    static func abortReason(confirmed: [String], dryRun: DryRun,
                            expecting: [Expectation]) -> String? {
        // 0. Before anything is compared: an argument that must never have been on argv at all.
        //    Checked here as well as at each surface's input, because this is the last look before
        //    a destructive apply and the surfaces have already disagreed with each other once.
        if let unsendable = confirmed.first(where: { !isSendableArgument($0) }) {
            return String(format: NSLocalizedString("“%@” isn't an identifier that names one app — it resolves to whichever app the engine happens to match first, so nothing was removed. Use the app's bundle id or its exact name.", comment: "uninstall preflight"),
                          unsendable.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        switch dryRun {
        case .unreadable:
            return NSLocalizedString("The dry run's output wasn't in a format Burrow can confirm a matched set from, so nothing was removed.", comment: "uninstall preflight")

        case .engineRefused(let message):
            return String(format: NSLocalizedString("The engine refused the dry run, so nothing was removed: %@", comment: "uninstall preflight"),
                          message)

        case .legacy(let matched):
            return mismatchDescription(confirmed: confirmed, matched: matched, subject: legacySubject)

        case .engine(let plan):
            // 1. The set itself, in one namespace: `query` is literally the argument we sent.
            //    Compared as bundle ids on purpose — display names are the ambiguity this whole
            //    path exists to remove — but rendered with the engine's own name beside the id,
            //    since "com.crossover.steam" alone tells a user who picked Steam very little.
            //
            //    NOTE what this step can and cannot do. Both sides are the same strings by
            //    construction, so agreement here means "the engine echoed my arguments back",
            //    which is a statement about the echo and not about which applications will be
            //    deleted. Step 5 is where identity is actually checked.
            var labels: [String: String] = [:]
            for app in plan.apps where !app.name.isEmpty {
                labels[app.query.lowercased()] = "\(app.name) (\(app.query))"
            }
            if let mismatch = mismatchDescription(confirmed: confirmed,
                                                  matched: plan.apps.map(\.query),
                                                  labels: labels,
                                                  subject: engineSubject) {
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
            // 5. IDENTITY — the check that was missing, and the one the other four cannot stand in
            //    for. Steps 1-4 all compare the request against itself; this compares the request
            //    against the APPLICATION the engine says it resolved.
            if let wrong = identityProblem(plan: plan, expecting: expecting) {
                return wrong
            }
            // 6. A protection rail already declines one of these bundles. Show it verbatim.
            if let refused = plan.refusedApps.first, let reason = refused.application.refusal {
                return String(format: NSLocalizedString("The engine won't remove %1$@: %2$@", comment: "uninstall preflight"),
                              refused.name, reason)
            }
            return nil
        }
    }

    /// Step 5 of [`abortReason`], separated because it is the whole point of the guard.
    ///
    /// Three questions, in order of how much the caller knows:
    ///
    ///  1. **Can identity be checked at all?** A resolved app with no `path` is one the guard
    ///     cannot pin to anything. Fail closed rather than proceed on a payload it can't read.
    ///  2. **Does the term name this app?** Surface-independent, and the rail that stops an agent
    ///     from deleting an app it never named — see [`AppPlan.isNamedBy`].
    ///  3. **Is it the row the caller picked?** Only when the caller said which row. The GUI
    ///     always can: it selected an inventory row and has its path and bundle id.
    ///
    /// Plus one structural check: two resolved rows must not name the same bundle, which would
    /// mean the run acts on it twice and the counts above stop meaning what they claim.
    private static func identityProblem(plan: Plan, expecting: [Expectation]) -> String? {
        var seenPaths: Set<String> = []
        for app in plan.apps {
            if app.application.path.isEmpty && app.path.isEmpty {
                return String(format: NSLocalizedString("The engine didn't say which application “%@” resolves to, so Burrow can't confirm it's the right one and nothing was removed.", comment: "uninstall preflight"),
                              app.query)
            }
            let path = app.path.isEmpty ? app.application.path : app.path
            guard seenPaths.insert(path).inserted else {
                return String(format: NSLocalizedString("The engine resolved %@ twice, so the run wouldn't act on the set it reported.", comment: "uninstall preflight"),
                              path)
            }
            guard app.isNamedBy(app.query) else {
                // What to name it BY. An app whose bundle has no `CFBundleIdentifier` reports the
                // placeholder here, and telling someone to "use the bundle id (unknown)" would be
                // advice to send the exact string this guard refuses — so those get pointed at
                // their display name, which is what really resolves them.
                let identifier = isSendableArgument(app.bundleId) ? app.bundleId : app.name
                return String(format: NSLocalizedString("“%1$@” isn't %2$@'s name or bundle id — the engine matched it by substring, so it may not be the app you meant. Nothing was removed; ask for it by name: %3$@.", comment: "uninstall preflight"),
                              app.query, app.name, identifier)
            }
            guard !expecting.isEmpty else { continue }
            guard let want = expecting.first(where: {
                $0.query.caseInsensitiveCompare(app.query) == .orderedSame
            }) else {
                return String(format: NSLocalizedString("The engine resolved an argument Burrow didn't send (“%@”), so nothing was removed.", comment: "uninstall preflight"),
                              app.query)
            }
            if !want.path.isEmpty, want.path != path {
                return String(format: NSLocalizedString("“%1$@” resolves to %2$@ (%3$@), not the %4$@ you picked (%5$@), so nothing was removed.", comment: "uninstall preflight"),
                              app.query, app.name, path, want.name, want.path)
            }
            if !want.bundleId.isEmpty, isSendableArgument(want.bundleId), !app.bundleId.isEmpty,
               want.bundleId.caseInsensitiveCompare(app.bundleId) != .orderedSame {
                return String(format: NSLocalizedString("“%1$@” resolves to an app whose bundle id is %2$@, not the %3$@ you picked, so nothing was removed.", comment: "uninstall preflight"),
                              app.query, app.bundleId, want.bundleId)
            }
        }
        return nil
    }

    // MARK: - What the sheet promised vs. what the plan says

    /// How one application actually comes off the disk.
    enum Mechanism: Equatable {
        /// Burrow/the engine removes the bundle itself — the Trash by default, outright under
        /// `--permanent`. Recoverable exactly when it went to the Trash.
        case direct
        /// `brew uninstall --cask --zap <token>`. Homebrew unlinks; nothing goes to the Trash, and
        /// `--zap` removes paths no enumeration predicted.
        case homebrew
    }

    static func mechanism(for app: AppPlan) -> Mechanism {
        app.application.isHomebrewCask ? .homebrew : .direct
    }

    /// Where the post-consent dry run disagrees with the promise the confirm sheet already made,
    /// or nil when they agree. **Trash-vs-Homebrew only** — the one difference that makes the
    /// sheet's central claim ("you can put them back") false.
    ///
    /// Two resolutions of the same fact sit either side of the consent dialog. The sheet reads the
    /// Software tab's inventory snapshot, which may be minutes old; the engine rebuilds the
    /// inventory inside every invocation (`cli.rs:745`), and its Homebrew stage is a `brew info`
    /// sweep behind a 10 s deadline with a `brew_wedged` breaker that degrades EVERY cask row to
    /// `source: "App"` once it trips. Trip it during `--list` but not during the apply and the
    /// sheet promises the Trash for a set of casks that are about to be `--zap`ped.
    ///
    /// `promised` is keyed by lowercased query, so it is built from the same arguments the guard
    /// compares. An argument with no promise recorded is not a disagreement — it is a caller that
    /// made no claim.
    static func consentDivergence(plan: Plan, promised: [String: Mechanism]) -> String? {
        var nowHomebrew: [AppPlan] = []
        var nowDirect: [AppPlan] = []
        for app in plan.apps {
            guard let was = promised[app.query.lowercased()] else { continue }
            let now = mechanism(for: app)
            guard was != now else { continue }
            if now == .homebrew { nowHomebrew.append(app) } else { nowDirect.append(app) }
        }
        var parts: [String] = []
        if !nowHomebrew.isEmpty {
            parts.append(String(format: NSLocalizedString("Homebrew removes these after all, with `brew uninstall --cask --zap` — that doesn't use the Trash, so you can't put them back: %@", comment: "uninstall re-confirm"),
                                nowHomebrew.map(\.name).joined(separator: ", ")))
        }
        if !nowDirect.isEmpty {
            parts.append(String(format: NSLocalizedString("These aren't Homebrew's after all — Burrow moves them to the Trash itself: %@", comment: "uninstall re-confirm"),
                                nowDirect.map(\.name).joined(separator: ", ")))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    // MARK: - How the apply is run: elevated or not

    /// Which process the real removal runs in, decided from the post-consent dry run.
    enum Elevation: Equatable {
        /// Every bundle is writable by the invoking user: the apply runs as that user, exactly
        /// like the dry run did. Leftovers under `~/Library` never need more than that.
        case unelevated
        /// At least one bundle needs administrator rights (the engine's `requires_admin`, or a
        /// per-app `needs_admin`). The apply runs through the privileged path, so macOS asks
        /// the user to authenticate; `apps` names the bundles that made it necessary, for the
        /// prompt copy.
        case elevated(apps: [String])
    }

    /// The route for `plan`. Pure, so the decision is testable without a prompt.
    ///
    /// An elevated run is the ONLY way a root-owned bundle comes off: the un-elevated apply
    /// hits EPERM on it and the engine then leaves its support files alone too (`partial`),
    /// which is the re-opened GitHub #253 — the user was told "needs an administrator" and
    /// nothing asked them for one. Elevating here is what turns that advisory back into a
    /// prompt. It is also the ONLY time the app elevates an uninstall: a plan with no admin
    /// requirement stays as the invoking user, because root is not a better way to trash
    /// files under that user's own home, and `BURROW_HOME` (see
    /// `PrivilegedEngineEnvironment`) is what keeps the elevated engine looking under the
    /// user's home rather than root's for the leftovers it removes alongside the bundle.
    static func elevation(for plan: Plan) -> Elevation {
        let admin = plan.adminApps.map(\.name)
        guard plan.requiresAdmin || !admin.isEmpty else { return .unelevated }
        return .elevated(apps: admin)
    }

    /// Facts the dry run turned up that the run's REPORT has to mention — they do not block, and
    /// deliberately so.
    ///
    /// `requiresAdmin` in particular is NOT an abort: the engine's `needs_admin` is an `access(2)`
    /// approximation that does not consult ACLs. It is what makes the apply run ELEVATED (see
    /// `elevation(for:)`), so the advisory tells the user a password prompt is coming rather
    /// than predicting a failure.
    static func advisories(for plan: Plan) -> [String] {
        var out: [String] = []
        if case .elevated(let apps) = elevation(for: plan) {
            let names = apps.joined(separator: ", ")
            out.append(String(format: NSLocalizedString("Needs an administrator: %@. Burrow will ask for an administrator password and remove it with that authorization.", comment: "uninstall advisory"),
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
        /// `apps[].removed_count` — SUPPORT FILES actually removed for this app, the bundle not
        /// folded in. Read because it is half of "did the disk change", and `leftoversAttempted`
        /// is not: the sweep can be attempted over an empty candidate list.
        let removedCount: Int
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

        /// Whether this run took anything off the disk.
        ///
        /// The reason it exists: a run where one app's bundle was refused and another's was
        /// deleted exits 1 with an `ok:TRUE` envelope (`i32::from(failed)` — verified against the
        /// real binary, two scratch bundles, exit 1). Every caller that reads the exit code alone
        /// therefore reports a real deletion as "didn't run", which is the wrong claim in the
        /// dangerous direction. The per-app accounting is the only honest answer, and it
        /// decomposes exactly: an application removed, or a support file removed.
        var changedTheDisk: Bool {
            applicationsRemoved > 0 || apps.contains { $0.removedCount > 0 }
        }
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
                removedCount: row["removed_count"] as? Int ?? 0,
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
    ///
    /// `subject` is the binary being described. It is a parameter and not a constant because both
    /// binaries reach this function and they are not the same program: the sentence said "mo" on
    /// the engine path, where every other line of the rewritten copy says "the engine", so the one
    /// place naming who is about to delete something named the wrong one.
    static func mismatchDescription(confirmed: [String], matched: [String],
                                    labels: [String: String] = [:],
                                    subject: String) -> String? {
        let confirmedSet = Set(confirmed.map { $0.lowercased() })
        let matchedSet = Set(matched.map { $0.lowercased() })
        guard confirmedSet != matchedSet else { return nil }

        var parts: [String] = []
        let extra = matched.filter { !confirmedSet.contains($0.lowercased()) }
            .map { labels[$0.lowercased()] ?? $0 }
        let missing = confirmed.filter { !matchedSet.contains($0.lowercased()) }
        if !extra.isEmpty {
            parts.append(String(format: NSLocalizedString("%1$@ would also remove: %2$@", comment: ""),
                                subject, extra.joined(separator: ", ")))
        }
        if !missing.isEmpty {
            parts.append(String(format: NSLocalizedString("%1$@ did not match: %2$@", comment: ""),
                                subject, missing.joined(separator: ", ")))
        }
        return parts.joined(separator: " · ")
    }

    /// The bundled Rust binary, in the words the rest of this file uses.
    static var engineSubject: String { NSLocalizedString("The engine", comment: "uninstall preflight subject") }
    /// A real legacy `mo` / MIT-fork binary, which is a different program and says so.
    static var legacySubject: String { NSLocalizedString("mo", comment: "uninstall preflight subject") }
}
