//
//  MoActions.swift
//  Burrow
//
//  The gated-actions core (issue #51): the catalog of every destructive
//  `mo` action as DATA (argv / stdin / timeout / elevation / severity),
//  one pure gate shared by the GUI and the MCP server, and the owner of
//  the MCP action wire format.
//
//  The spine is the ticket-mint invariant: `MoActions.decide` is the ONLY
//  place a RunTicket can be constructed (file-private init), and runners
//  only accept tickets — so nothing in either process can execute a real
//  `mo` action without passing the same policy. "GUI ≡ MCP" is a property
//  of the code, not a discipline.
//
//  Deliberately pure: no Store, no Privacy, no AppKit — consent arrives
//  as data in the gate, verdicts come out. Which BINARY a ticket will be
//  spawned against arrives the same way, through `decide`'s `resolve` seam
//  (production default: `EngineTarget.resolve`), because the argv a ticket
//  carries is only correct relative to the program that will read it.
//

import Foundation

// MARK: - Which binary: resolved once, carried on the ticket

/// The binary a ticket will actually be spawned against, resolved ONCE at mint and carried on
/// the ticket so the decision and the spawn cannot disagree.
///
/// Two different programs sit behind `mo` discovery and they read the SAME argv with opposite
/// meanings. The bundled Rust engine previews by default and deletes on `--apply`; a legacy `mo`
/// deletes by default and previews on `--dry-run` (verified against the installed mole 1.46.0:
/// `libexec/bin/clean.sh` treats a bare `clean` as the live run and rejects an unknown `--apply`
/// with exit 1). So "translate this ticket's argv?" is a question about WHICH FILE resolved, and
/// it has to be answered by the same lookup that produces the path the spawn uses — resolving
/// once to decide and again to spawn is precisely the disagreement that turns a preview into a
/// deletion.
struct EngineTarget: Equatable {
    /// Absolute path to the resolved binary; nil when nothing resolved at all.
    let path: String?
    /// True ONLY when `path` is the engine sealed inside Burrow.app — the same path-identity
    /// check `OperationFlow.start` makes before translating its fallback spawn. Anything else (a
    /// Homebrew `mo`, the Go fork, an unresolved lookup) speaks mo's own convention as far as
    /// this side can tell, so its argv is left exactly as the catalog spelled it.
    let isBundledEngine: Bool

    /// Nothing resolved: mo-style argv, and a spawn that fails cleanly. Engine argv is never sent
    /// to a binary that could not be identified.
    static let unresolved = EngineTarget(path: nil, isBundledEngine: false)

    static func bundledEngine(_ path: String) -> EngineTarget {
        EngineTarget(path: path, isBundledEngine: true)
    }

    /// Any resolved binary that is NOT the bundled engine. Named for the wire format it speaks
    /// rather than for a product, because upstream `mo` and the MIT fork are both in here.
    static func moStyle(_ path: String) -> EngineTarget {
        EngineTarget(path: path, isBundledEngine: false)
    }

    /// Production resolution — the same pair of lookups `OperationFlow`'s `resolveMo` default
    /// uses, so a ticket and a streamed operation land on the same file: an elevated run never
    /// accepts a PATH hit (a user-writable directory could shadow the engine and be handed root),
    /// everything else uses the cached discovery.
    ///
    /// When an engine IS bundled the two sides of the identity test are the same file by
    /// construction, because `trustedExecutable()`/`findExecutable()` both consult
    /// `bundledExecutable()` first — one resolver, so they cannot drift.
    static func resolve(elevated: Bool) -> EngineTarget {
        let resolved = elevated ? MoleCLI.trustedExecutable() : MoleCLI.findExecutable()
        return EngineTarget(path: resolved,
                            isBundledEngine: resolved != nil && resolved == MoleCLI.bundledExecutable())
    }
}

// MARK: - What: the action catalog

enum MoAction: Equatable {
    case clean, optimize
    case uninstall(apps: [String], permanent: Bool)
    case purge, installer

    var commandName: String {
        switch self {
        case .clean: return "clean"
        case .optimize: return "optimize"
        case .uninstall: return "uninstall"
        case .purge: return "purge"
        case .installer: return "installer"
        }
    }

    /// Per-action facts, in one switch — THE place gating folklore lives.
    var spec: ActionSpec {
        switch self {
        case .clean:
            return ActionSpec(severity: .recoverable, interactiveOnly: false,
                              needsExplicitConfirm: true, previewNeedsFDA: true,
                              elevatedRealRunGUI: true, requiresMatchPreflight: false)
        case .optimize:
            // The admin auth prompt IS the consent — no separate dialog.
            return ActionSpec(severity: .recoverable, interactiveOnly: false,
                              needsExplicitConfirm: false, previewNeedsFDA: true,
                              elevatedRealRunGUI: true, requiresMatchPreflight: false)
        case .uninstall:
            return ActionSpec(severity: .irreversible, interactiveOnly: false,
                              needsExplicitConfirm: true, previewNeedsFDA: false,
                              elevatedRealRunGUI: false, requiresMatchPreflight: true)
        case .purge, .installer:
            // Real runs are an interactive TUI checklist; only previews are
            // mintable here.
            return ActionSpec(severity: .recoverable, interactiveOnly: true,
                              needsExplicitConfirm: false, previewNeedsFDA: true,
                              elevatedRealRunGUI: false, requiresMatchPreflight: false)
        }
    }

    /// The argv table, spelled once for both surfaces.
    func argv(_ mode: RunMode) -> [String] {
        switch self {
        case .clean:
            return mode == .preview ? ["clean", "--dry-run"] : ["clean"]
        case .optimize:
            return mode == .preview ? ["optimize", "--dry-run"] : ["optimize"]
        case .uninstall(let apps, let permanent):
            if mode == .preview { return ["uninstall", "--dry-run"] + apps }
            return ["uninstall"] + (permanent ? ["--permanent"] : []) + apps
        case .purge:
            return mode == .preview ? ["purge", "--dry-run"] : ["purge"]
        case .installer:
            return mode == .preview ? ["installer", "--dry-run"] : ["installer"]
        }
    }

    /// The match-preflight command (uninstall only): pin what the resolved binary's matcher
    /// resolves BEFORE answering its prompts. `--dry-run` changes nothing
    /// and exits at its prompt on stdin EOF.
    ///
    /// Built from mo-style argv, same as every other command here, and translated for the same
    /// reason and under the same condition `mint` translates: only when `target` IS the bundled
    /// engine. The untranslated mo spelling is already the read-only one — `["uninstall",
    /// "--dry-run", <apps>]` is what a legacy `mo` documents and what its `uninstall.sh` reads —
    /// so a probe against that binary needs no translation and must not receive one.
    ///
    /// `mint` calls this with the target it resolved and hangs the result on the ticket, so the
    /// probe and the run it guards are guaranteed to be the same binary. A probe that read one
    /// binary's plan while the apply went to another would be a guard in name only.
    ///
    /// **`assertDryRun` is what makes the probe read-only, and it is the one caller that asks for
    /// it.** Translation alone drops `--dry-run` and lands on the engine's dry-run DEFAULT, which
    /// is right for every ticket `mint` builds — a preview the user asked for is allowed to inherit
    /// the default, because the worst a wrong default does there is show the wrong screen. This is
    /// not that. The pre-flight runs before the user's consent has been acted on, and since
    /// burrow-engine `df9ea3f` the command it probes with removes the `.app` itself. Flagless, its
    /// non-destructiveness was an assumption about the engine that nothing on either side asserted;
    /// with the flag it is a fact on the argv, and `wants_apply` resolves toward the dry run even on
    /// the engine's internal seams that never see argv validation. It cannot collide with `--apply`:
    /// `engineArgv` appends at most one of the two (see its doc), and the engine refuses the pair at
    /// exit 2 if anything ever did.
    ///
    /// `--permanent` is deliberately absent — the mo argv here is the PREVIEW spelling, so the probe
    /// asks what would be removed and never how. A flag that only distinguishes Trash from outright
    /// deletion has nothing to say about a run that deletes neither.
    func preflightCommand(on target: EngineTarget) -> ActionCommand? {
        guard case .uninstall(let apps, _) = self else { return nil }
        let moArgs = ["uninstall", "--dry-run"] + apps
        return ActionCommand(executable: target.path,
                             args: target.isBundledEngine
                                 ? BurrowConductor.engineArgv(fromMo: moArgs, assertDryRun: true)
                                 : moArgs,
                             stdin: "", timeout: 120, elevated: false)
    }

    /// App names for wire payloads (uninstall carries them everywhere).
    var wireApps: [String]? {
        guard case .uninstall(let apps, _) = self else { return nil }
        return apps
    }
}

struct ActionSpec: Equatable {
    enum Severity { case recoverable, irreversible }
    let severity: Severity
    let interactiveOnly: Bool
    /// GUI real runs that need their own dialog. (Agents consent per-call
    /// via confirm:true, so this never applies to the agent gate.)
    let needsExplicitConfirm: Bool
    /// Un-elevated preview scans walk TCC-protected dirs — gate on FDA.
    let previewNeedsFDA: Bool
    /// GUI real runs that elevate through the one osascript auth prompt.
    let elevatedRealRunGUI: Bool
    let requiresMatchPreflight: Bool
}

enum RunMode: String, Equatable {
    case preview, real
}

/// Which process is asking. Timeout/elevation legitimately differ per
/// surface (agents can't field auth prompts; a watched streaming run is
/// deliberately unbounded) — the catalog spells the asymmetry once.
enum ActionSurface: Equatable {
    case gui, agent
}

/// Engine-agnostic process recipe (RFC #48's engine will consume this).
struct ActionCommand: Equatable {
    /// The exact binary this recipe must be spawned against: the path `mint` resolved at the
    /// moment it decided whether to translate `args`. Carried rather than looked up again,
    /// because `args` is only correct relative to this file — a second discovery that answered
    /// differently would hand one program the other's wire format. nil when nothing resolved.
    var executable: String? = nil
    var args: [String]
    var stdin: String?
    var timeout: TimeInterval?
    var elevated: Bool

    /// What to spawn. `/usr/bin/false` for an unresolved binary reproduces exactly the
    /// degradation `MoEngine.capture` already applies to a `.mo` target it can't resolve — a
    /// clean nonzero exit rather than a crash — without asking discovery a second question.
    var spawnPath: String { executable ?? "/usr/bin/false" }
}

// MARK: - May we: the pure gate

enum ActionGate: Equatable {
    case gui(hasFullDiskAccess: Bool, userConfirmed: Bool = false, elevationGranted: Bool = false)
    case agent(actionsOptIn: Bool, irreversibleOptIn: Bool)
}

enum BlockedReason: Equatable {
    case agentCleanupsOptInOff
    case agentUninstallOptInOff

    /// Canonical refusal copy — owned here, golden-tested in the wire.
    var message: String {
        switch self {
        case .agentCleanupsOptInOff:
            return "Real cleanups are off. Turn on 'Let agents run cleanups for real' "
                + "in Burrow \u{25B8} Settings, then retry with confirm:true. "
                + "(A dry-run preview works without it.)"
        case .agentUninstallOptInOff:
            return "Uninstalls are off for agents. Real `mo uninstall` (and any "
                + "permanent delete) additionally requires 'Also allow uninstalls & "
                + "permanent deletes' in Burrow \u{25B8} Settings \u{25B8} Agent. "
                + "A dry-run preview works without it."
        }
    }
}

enum ActionPreflight: Equatable {
    /// Fail closed unless mo's matched set equals what was confirmed.
    case verifyUninstallMatch(expected: [String])
}

/// A runnable, fully-specified action. Minted ONLY by `MoActions.decide`
/// — the file-private init is the invariant that makes the gate the gate.
struct RunTicket: Equatable {
    let action: MoAction
    let mode: RunMode
    let command: ActionCommand
    let preflight: ActionPreflight?
    /// The read-only probe `preflight` requires, built against the SAME resolved binary as
    /// `command` and non-nil exactly when `preflight` is. Minted here rather than rebuilt at the
    /// call site so the guard and the run it guards cannot end up describing different files.
    let preflightCommand: ActionCommand?
    /// Interactive-only redirect text (agent purge/installer downgrade).
    let note: String?

    fileprivate init(action: MoAction, mode: RunMode, command: ActionCommand,
                     preflight: ActionPreflight?, preflightCommand: ActionCommand?,
                     note: String?) {
        self.action = action
        self.mode = mode
        self.command = command
        self.preflight = preflight
        self.preflightCommand = preflightCommand
        self.note = note
    }
}

enum Verdict: Equatable {
    case run(RunTicket)
    case needsConfirmation
    case needsFullDiskAccess
    /// GUI real purge/installer → the existing PTY checklist UI.
    case interactiveFlow
    case blocked(BlockedReason)
}

enum MoActions {
    /// The truth table. Pure: consent is data in the gate, a verdict comes
    /// out, and `.run` is the only way to obtain a ticket.
    ///
    /// `resolve` is the one impure input, and it is asked at most ONCE per call — only on the
    /// paths that actually mint, and never for a refusal. Callers that already resolved the
    /// binary for their own UI (the Software tab's confirm sheet describes what a specific binary
    /// is about to do) pass that answer in, so one user action means one resolution end to end.
    static func decide(_ action: MoAction, _ mode: RunMode, _ gate: ActionGate,
                       resolve: (_ elevated: Bool) -> EngineTarget = EngineTarget.resolve) -> Verdict {
        let spec = action.spec
        switch gate {
        case .agent(let actionsOptIn, let irreversibleOptIn):
            if mode == .preview {
                return .run(mint(action, .preview, surface: .agent, resolve: resolve))
            }
            if spec.interactiveOnly {
                // Real run is TUI-only: DOWNGRADE to a preview ticket with
                // the redirect note, instead of blocking or pretending.
                return .run(mint(action, .preview, surface: .agent,
                                 note: redirectNote(for: action), resolve: resolve))
            }
            guard actionsOptIn else { return .blocked(.agentCleanupsOptInOff) }
            if spec.severity == .irreversible, !irreversibleOptIn {
                return .blocked(.agentUninstallOptInOff)
            }
            return .run(mint(action, .real, surface: .agent, resolve: resolve))

        case .gui(let hasFDA, let userConfirmed, let elevationGranted):
            if mode == .real {
                if spec.interactiveOnly { return .interactiveFlow }
                if spec.needsExplicitConfirm, !userConfirmed { return .needsConfirmation }
                return .run(mint(action, .real, surface: .gui, resolve: resolve))
            }
            // Previews: un-elevated TCC walks need FDA; "Scan with admin"
            // resolves the gate because root bypasses TCC.
            if spec.previewNeedsFDA, !hasFDA, !elevationGranted {
                return .needsFullDiskAccess
            }
            return .run(mint(action, .preview, surface: .gui, elevated: elevationGranted,
                             resolve: resolve))
        }
    }

    private static func mint(_ action: MoAction, _ mode: RunMode,
                             surface: ActionSurface, elevated: Bool = false,
                             note: String? = nil,
                             resolve: (_ elevated: Bool) -> EngineTarget) -> RunTicket {
        let spec = action.spec
        let isElevated = elevated || (mode == .real && surface == .gui && spec.elevatedRealRunGUI)
        // THE one resolution. Elevation is settled first because it changes which lookup is
        // legitimate (elevated runs never accept a PATH hit), and the answer is then used for
        // BOTH halves of this ticket: whether to translate the argv, and what to spawn. Nothing
        // downstream resolves again — `ActionCommand.executable` carries this exact path, and
        // both call sites spawn `.executable(command.spawnPath)` rather than `.mo`.
        let target = resolve(isElevated)
        let moArgs = action.argv(mode)
        let command = ActionCommand(
            executable: target.path,
            // `action.argv(mode)` is mo-style — mo runs LIVE by default, `--dry-run` previews.
            // The engine inverts that (dry-run by default, `--apply` to run for real), so a
            // ticket bound for it is translated here, ONCE, for every surface and every mode
            // alike — `BurrowConductor.engineArgv` is the same pure mapping the streaming GUI
            // path uses, so there's exactly one place that knows the mo↔engine wire difference.
            //
            // TRANSLATE ONLY WHEN THE RESOLVED BINARY IS THE BUNDLED ENGINE. This is the same
            // path-identity guard `OperationFlow.start` applies to its fallback spawn, and it is
            // load-bearing in both directions. A shipped build always resolves the bundled engine
            // (`trustedExecutable()`/`findExecutable()` both prefer it), so translation still
            // happens there and the argv is unchanged. A build without a staged engine resolves
            // whatever discovery finds — on a dev machine that is `/opt/homebrew/bin/mo` — and
            // translating for THAT binary inverts the meaning of every ticket: engine-style
            // `["clean"]`, minted for a PREVIEW because the engine's default is dry-run, is a
            // legacy `mo`'s LIVE clean. A preview that deletes is the highest-severity bug this
            // file can produce, so it may not depend on which build the code happens to be in.
            args: target.isBundledEngine ? BurrowConductor.engineArgv(fromMo: moArgs) : moArgs,
            // mo uninstall is interactive ("Proceed? [y/N]" + "Enter confirm");
            // feed yes so a non-TTY run doesn't block forever. The gate +
            // preflight are the consent, not these answers.
            stdin: (mode == .real && spec.requiresMatchPreflight)
                ? String(repeating: "y\n", count: 4) : nil,
            timeout: timeout(action, mode, surface),
            elevated: isElevated)
        let needsPreflight = mode == .real && spec.requiresMatchPreflight
        return RunTicket(action: action, mode: mode, command: command,
                         preflight: needsPreflight
                             ? .verifyUninstallMatch(expected: action.wireApps ?? []) : nil,
                         // Built from the SAME `target`, so the probe reads the plan of the
                         // binary that is about to act on it — and reuses the resolution rather
                         // than making a second one.
                         preflightCommand: needsPreflight ? action.preflightCommand(on: target) : nil,
                         note: note)
    }

    /// Timeout policy, once. GUI streaming runs are watched and cancellable
    /// → explicitly unbounded; agent captures must never hang an MCP loop.
    /// Uninstall is a capture on both surfaces → one number (600 s — this
    /// deliberately unifies the GUI's old 300 s with MCP's 600 s).
    private static func timeout(_ action: MoAction, _ mode: RunMode,
                                _ surface: ActionSurface) -> TimeInterval? {
        if case .uninstall = action, mode == .real { return 600 }
        switch surface {
        case .gui: return nil
        case .agent: return mode == .preview ? 180 : 600
        }
    }

    private static func redirectNote(for action: MoAction) -> String {
        "Real `mo \(action.commandName)` is an interactive selection flow — "
            + "run it from the Burrow app. This is the preview."
    }
}

// MARK: - The frozen MCP wire format

/// Owner of the action-tool JSON contract. Field names, refusal prose, and
/// the redirect note are golden-tested; keys are emitted sorted so the
/// bytes are stable. Additive changes only.
enum ActionWire {
    /// `error` / `kind` are the engine's classified failure, emitted ONLY when there was one —
    /// additive, so every existing success/preview payload stays byte-identical. They exist
    /// because the repoint moved the reason: the Rust engine writes an `ok:false` envelope to
    /// stdout and nothing to stderr, so a failed action used to arrive as a bare non-zero
    /// `exit_code` with the whole envelope stuffed into `output` as a string an agent had to
    /// re-parse.
    static func result(command: String, dryRun: Bool, ran: Bool, exitCode: Int32,
                       output: String, apps: [String]? = nil, permanent: Bool? = nil,
                       note: String? = nil, timedOutAfter: TimeInterval? = nil,
                       error: String? = nil, kind: String? = nil) -> String {
        let stripped = Ansi.strip(output)
        var obj: [String: Any] = [
            "command": command,
            "dry_run": dryRun,
            "ran": ran,
            "exit_code": Int(exitCode),
            "output": stripped,
        ]
        // Parse-once: the same parser that backs the GUI report cards gives
        // agents structured freed-bytes. Additive — raw output stays.
        if let summary = summaryObject(stripped) { obj["summary"] = summary }
        if let apps { obj["apps"] = apps }
        if let permanent { obj["permanent"] = permanent }
        if let error, !error.isEmpty { obj["error"] = error }
        if let kind, !kind.isEmpty { obj["kind"] = kind }
        if let note {
            obj["interactive_only"] = true
            obj["note"] = note
        }
        // A killed run otherwise reads as a bare non-zero exit with empty
        // output (observed in the wild as `exit_code: 9, output: ""`) —
        // say what actually happened.
        if let timedOutAfter {
            obj["timed_out"] = true
            obj["hint"] = "mo \(command) was killed after \(Int(timedOutAfter))s without finishing"
                + " — retry, or run it from the Burrow app"
        }
        return json(obj)
    }

    static func blocked(command: String, reason: BlockedReason, apps: [String]? = nil) -> String {
        var obj: [String: Any] = [
            "command": command,
            "ran": false,
            "blocked": true,
            "reason": reason.message,
        ]
        if let apps { obj["apps"] = apps }
        return json(obj)
    }

    /// `reason` is `UninstallGuard.abortReason`'s verdict — the ONE sentence a GUI user and an
    /// agent both see, so neither surface invents its own guess at why nothing was removed.
    ///
    /// `matched` is the set the resolved binary said it would act on, when it said anything: the
    /// echoed `apps[].query` from the engine, the parsed display names from a legacy `mo`, and nil
    /// when the dry run was refused or unreadable. `engineError` is the dry run's OWN reason,
    /// present only when that run itself failed — without it, an engine failure (a bad bundle id, a
    /// permission denial) came back wearing a generic message that described the wrong thing.
    ///
    /// None of it changes the outcome: this function only ever emits `ran: false`.
    static func uninstallAbort(apps: [String], reason: String,
                               matched: [String]? = nil, engineError: String? = nil) -> String {
        var obj: [String: Any] = ["command": "uninstall", "ran": false, "apps": apps,
                                  "error": "aborted: " + reason]
        if let engineError, !engineError.isEmpty { obj["engine_error"] = engineError }
        if let matched { obj["matched"] = matched }
        return json(obj)
    }

    private static func summaryObject(_ strippedOutput: String) -> [String: String]? {
        let lines = strippedOutput.components(separatedBy: "\n")
        guard let summary = parseTaskReport(lines).summary else { return nil }
        var obj: [String: String] = [:]
        if !summary.space.isEmpty { obj["space"] = summary.space }
        if !summary.items.isEmpty { obj["items"] = summary.items }
        if !summary.categories.isEmpty { obj["categories"] = summary.categories }
        if !summary.freeChange.isEmpty { obj["free_change"] = summary.freeChange }
        if !summary.freeNow.isEmpty { obj["free_now"] = summary.freeNow }
        return obj.isEmpty ? nil : obj
    }

    private static func json(_ obj: [String: Any]) -> String {
        if let d = try? JSONSerialization.data(withJSONObject: obj,
                                               options: [.withoutEscapingSlashes, .sortedKeys]),
           let s = String(data: d, encoding: .utf8) {
            return s
        }
        return "{\"error\":\"encode failed\"}"
    }
}
