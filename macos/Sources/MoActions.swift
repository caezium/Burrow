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
//  as data in the gate, verdicts come out.
//

import Foundation

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

    /// The match-preflight command (uninstall only): pin what mo's matcher
    /// resolves BEFORE answering its prompts. `--dry-run` changes nothing
    /// and exits at its prompt on stdin EOF.
    ///
    /// Built from mo-style argv, same as every other command here, so it goes through the same
    /// `BurrowConductor.engineArgv` translation `mint` applies — this bypasses `mint` (it isn't a
    /// runnable ticket, just the probe `execute()` runs before answering any prompt), so without
    /// this it would reach the engine untranslated like every other pre-repoint call site did.
    var preflightCommand: ActionCommand? {
        guard case .uninstall(let apps, _) = self else { return nil }
        return ActionCommand(args: BurrowConductor.engineArgv(fromMo: ["uninstall", "--dry-run"] + apps),
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
    var args: [String]
    var stdin: String?
    var timeout: TimeInterval?
    var elevated: Bool
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
    /// Interactive-only redirect text (agent purge/installer downgrade).
    let note: String?

    fileprivate init(action: MoAction, mode: RunMode, command: ActionCommand,
                     preflight: ActionPreflight?, note: String?) {
        self.action = action
        self.mode = mode
        self.command = command
        self.preflight = preflight
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
    static func decide(_ action: MoAction, _ mode: RunMode, _ gate: ActionGate) -> Verdict {
        let spec = action.spec
        switch gate {
        case .agent(let actionsOptIn, let irreversibleOptIn):
            if mode == .preview {
                return .run(mint(action, .preview, surface: .agent))
            }
            if spec.interactiveOnly {
                // Real run is TUI-only: DOWNGRADE to a preview ticket with
                // the redirect note, instead of blocking or pretending.
                return .run(mint(action, .preview, surface: .agent,
                                 note: redirectNote(for: action)))
            }
            guard actionsOptIn else { return .blocked(.agentCleanupsOptInOff) }
            if spec.severity == .irreversible, !irreversibleOptIn {
                return .blocked(.agentUninstallOptInOff)
            }
            return .run(mint(action, .real, surface: .agent))

        case .gui(let hasFDA, let userConfirmed, let elevationGranted):
            if mode == .real {
                if spec.interactiveOnly { return .interactiveFlow }
                if spec.needsExplicitConfirm, !userConfirmed { return .needsConfirmation }
                return .run(mint(action, .real, surface: .gui))
            }
            // Previews: un-elevated TCC walks need FDA; "Scan with admin"
            // resolves the gate because root bypasses TCC.
            if spec.previewNeedsFDA, !hasFDA, !elevationGranted {
                return .needsFullDiskAccess
            }
            return .run(mint(action, .preview, surface: .gui, elevated: elevationGranted))
        }
    }

    private static func mint(_ action: MoAction, _ mode: RunMode,
                             surface: ActionSurface, elevated: Bool = false,
                             note: String? = nil) -> RunTicket {
        let spec = action.spec
        let isElevated = elevated || (mode == .real && surface == .gui && spec.elevatedRealRunGUI)
        let command = ActionCommand(
            // `action.argv(mode)` is mo-style — mo runs LIVE by default, `--dry-run` previews.
            // The bundled binary every RunTicket ultimately reaches is the engine (post-repoint),
            // which inverts that (dry-run by default, `--apply` to run for real), so the mo-style
            // table above is translated here, ONCE, for every surface and every mode alike —
            // `BurrowConductor.engineArgv` is the same pure mapping the streaming GUI path uses,
            // so there's exactly one place that knows the mo↔engine wire difference. Getting this
            // backwards is the highest-severity class of bug in this file: a preview that gains
            // `--apply` deletes on a "just show me what would happen" request.
            args: BurrowConductor.engineArgv(fromMo: action.argv(mode)),
            // mo uninstall is interactive ("Proceed? [y/N]" + "Enter confirm");
            // feed yes so a non-TTY run doesn't block forever. The gate +
            // preflight are the consent, not these answers.
            stdin: (mode == .real && spec.requiresMatchPreflight)
                ? String(repeating: "y\n", count: 4) : nil,
            timeout: timeout(action, mode, surface),
            elevated: isElevated)
        return RunTicket(action: action, mode: mode, command: command,
                         preflight: (mode == .real && spec.requiresMatchPreflight)
                             ? .verifyUninstallMatch(expected: action.wireApps ?? []) : nil,
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
