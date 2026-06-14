//
//  PrivilegeBroker.swift
//  Burrow
//
//  The elevated-execution seam (issue #48). One elevated `mo` run = one
//  osascript `do shell script … with administrator privileges` = one
//  macOS auth prompt. That spawn was previously hand-rolled inline in
//  `MoleCLI.runElevated` against a raw `Process`, so the riskiest code in
//  the app — the path that runs as ROOT — was the path no test could reach.
//
//  This is the sibling of `MoleProcessPort` (the #29 capture-spawn runner):
//  `PrivilegeBroker` owns the one-shot elevated invocation behind a port so
//  production keeps spawning real osascript via `SystemPrivilegeBroker`,
//  while tests inject a fake to drive the build-the-osascript-spec quoting
//  and the auth-cancel classification IN MEMORY — no auth dialog, no sudo.
//
//  Streamed elevated runs stay in OperationFlow's SystemProcessPort (output
//  tailed from a temp log); this seam covers the one-shot config commands
//  (`mo touchid enable/disable`) where the only signal is the exit status.
//

import Foundation

// MARK: - Outcome

/// What a one-shot elevated run produced. Richer than the raw exit code the
/// old `runElevated` returned: the auth-cancel case is classified ONCE, by
/// the shared engine rule (`AuthCancel`), instead of every caller re-deriving
/// "nonzero ⇒ maybe the prompt was dismissed".
enum ElevatedOutcome: Equatable {
    /// The command ran and exited with this status (0 = success).
    case exited(Int32)
    /// The macOS auth prompt was dismissed before the command ran — osascript
    /// returns the user-cancelled error (-128) and the command never executed.
    case authCancelled
    /// The osascript spawn itself failed to launch (no usable `mo`, Process
    /// threw). Distinct from a command that ran and failed.
    case launchFailed
}

extension ElevatedOutcome {
    /// Back-compat shim for call sites that still branch on an `Int32`. Both
    /// failure shapes collapse to a nonzero code, preserving the exact
    /// behaviour of the old `runElevated -> Int32` contract.
    var exitCode: Int32 {
        switch self {
        case .exited(let code): return code
        case .authCancelled: return 1
        case .launchFailed: return 127
        }
    }
}

// MARK: - Port

/// The one elevated-spawn boundary. `openElevated` builds the osascript
/// invocation (via `MoleCLI.elevatedScript`, the one shared two-pass quoter),
/// runs it once, and classifies the result. Production spawns real osascript;
/// tests script the outcome without touching the GUI.
protocol PrivilegeBroker: Sendable {
    /// Run `executable` + `args` once with administrator rights. `executable`
    /// MUST come from a trusted location (never a PATH lookup) — running an
    /// attacker-shadowed binary as root is the whole threat model here.
    func openElevated(executable: String, args: [String]) -> ElevatedOutcome
}

// MARK: - Production witness

/// Spawns the real `/usr/bin/osascript` with the `do shell script …` source
/// and waits for it. Mechanically identical to the old inline `runElevated`
/// body — only the result classification is new (auth-cancel is now named,
/// not folded into a bare nonzero exit).
struct SystemPrivilegeBroker: PrivilegeBroker {
    /// osascript's exit status when the user dismisses the auth dialog: it
    /// surfaces AppleScript's `userCanceledErr` (-128) as a process exit of
    /// 1, but the canonical signal is the error number. We classify on
    /// "produced no output" the way the streaming path does, so a genuine
    /// command failure (which DID run and print) is never mistaken for a
    /// cancel.
    func openElevated(executable: String, args: [String]) -> ElevatedOutcome {
        let script = MoleCLI.elevatedScript(executable: executable, args: args)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let outPipe = Pipe(), errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
            // Drain both pipes to EOF before reaping so neither can fill and
            // wedge osascript; small output, so a blocking read is fine.
            let out = outPipe.fileHandleForReading.readDataToEndOfFile()
            let err = errPipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let code = task.terminationStatus
            let sawOutput = !out.isEmpty || !err.isEmpty
            return AuthCancel.outcome(exitCode: code, sawOutput: sawOutput)
        } catch {
            return .launchFailed
        }
    }
}

// MARK: - Auth-cancel classification (the one engine rule)

/// The single auth-cancel rule, shared by every elevated path (issue #48's
/// "one error taxonomy"). An elevated run that exits nonzero having produced
/// NOTHING is a dismissed auth prompt, not a command failure — output proves
/// the command actually ran under root. Pure → exhaustively table-tested.
///
/// `SystemProcessPort.finalEvent` (the streaming runner) and
/// `SystemPrivilegeBroker.openElevated` (the one-shot runner) both route
/// through `isAuthCancelled` so the two can't drift apart.
enum AuthCancel {
    /// The primitive: does this elevated result look like a dismissed prompt?
    /// `elevated` is always true at the one-shot call site (every run here is
    /// elevated) but kept as a parameter so the streaming path — which spawns
    /// plain runs too — shares the exact same predicate.
    static func isAuthCancelled(elevated: Bool, exitCode: Int32, sawOutput: Bool) -> Bool {
        elevated && exitCode != 0 && !sawOutput
    }

    /// Classify a one-shot elevated result (always elevated here).
    static func outcome(exitCode: Int32, sawOutput: Bool) -> ElevatedOutcome {
        if isAuthCancelled(elevated: true, exitCode: exitCode, sawOutput: sawOutput) {
            return .authCancelled
        }
        return .exited(exitCode)
    }
}
