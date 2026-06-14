//
//  OperationFlow.swift
//  Burrow
//
//  The run-a-tool lifecycle, owned once: Full Disk Access gate → optional
//  elevation → spawn → stream → reduce → report → OperationCenter
//  begin/detail/end → done/failed/cancelled. Operation views shrink to
//  layout + localized copy; per-tool variation is DATA in a ToolOperation
//  descriptor (args, stdin, gate, elevation, a pure reduce closure) —
//  never a subclass.
//
//  The process boundary is one method behind ProcessPort. Production uses
//  SystemProcessPort for the streaming op runs (Clean/Optimize); tests
//  script a fake. This is the sibling of MoleProcess (the #29 capture-spawn
//  runner): SystemProcessPort streams long-running ops, MoleProcess captures
//  one-shot output — they coexist by use-case.
//

import Foundation
import SwiftUI

// MARK: - Process port

struct ProcessSpec: Sendable, Equatable {
    var executable: String
    var arguments: [String]
    var stdin: String?
    var elevated: Bool
    var timeout: TimeInterval?
}

enum ProcessEvent: Sendable {
    case line(String)        // ANSI-stripped, newline-split
    case exited(Int32)
    /// The elevated run's auth prompt was dismissed: osascript exited
    /// nonzero having produced nothing. Classified by the RUNNER (issue
    /// #48's one error taxonomy), not by view-level heuristics.
    case authCancelled
}

/// The one process boundary the flow needs: spawn per the spec, stream
/// stripped lines, then a single `.exited`. Cancelling the consuming task
/// terminates the child (via the stream's onTermination).
protocol ProcessPort: Sendable {
    func events(_ spec: ProcessSpec) -> AsyncStream<ProcessEvent>
}

// MARK: - Tool descriptor

/// All per-tool variation as data. `reduce` is a pure function from the
/// accumulated output lines to whatever the view renders (a TaskReport
/// tuple, a transcript, parsed JSON) — tested separately, never inside
/// the view.
struct ToolOperation<Report: Sendable> {
    enum Executable { case mo, path(String) }
    enum Gate { case none, fullDiskAccess(adminBypass: Bool) }

    /// OperationCenter HUD label; nil = the run isn't surfaced there.
    var label: String?
    var executable: Executable = .mo
    var arguments: [String]
    var stdin: String? = nil
    var gate: Gate = .none
    var elevated: Bool = false
    var timeout: TimeInterval? = nil
    var reduce: @Sendable ([String]) -> Report
    /// Optional line → HUD detail mapping (clean/optimize use
    /// TaskReportText.line); nil shows the raw line.
    var hudLine: (@Sendable (String) -> String)? = nil
    /// Post a user notification when this run finishes — real cleans /
    /// optimize / uninstalls, never previews. The post itself lives in
    /// OperationCenter.end → BurrowNotifier.
    var notifyOnEnd: Bool = false
    /// Final OperationCenter detail derived from the finished report —
    /// the result line a completion notification carries (freed bytes
    /// etc.). nil keeps the last streamed line.
    var finalDetail: (@Sendable (Report) -> String)? = nil

    /// "Scan with admin": the same operation, elevated — root bypasses TCC
    /// so the gate no longer applies.
    func elevated(_ on: Bool = true) -> Self {
        var c = self
        c.elevated = on
        return c
    }
}

// MARK: - The flow

@MainActor
final class OperationFlow<Report: Sendable>: ObservableObject {
    enum Outcome {
        case done(exit: Int32)
        case failed(String)
        case cancelled
    }
    enum State {
        case idle
        /// FDA missing; the pending operation rides along — resolution is
        /// just `start(pending)` (recheck) or `start(pending.elevated())`.
        case gated(pending: ToolOperation<Report>)
        case running
        case finished(Outcome)
    }

    @Published private(set) var state: State = .idle
    /// Live during the run (recomputed per streamed line), final at exit.
    @Published private(set) var report: Report?

    /// Stop only works for un-elevated runs: the root `mo` is a child of
    /// the privileged shell, and SIGTERMing our osascript messenger would
    /// just orphan it mid-delete while the UI claims "Stopped."
    var canCancel: Bool {
        if case .running = state { return !currentElevated }
        return false
    }

    /// Stable across runs on purpose (dry-run → real run): OperationCenter
    /// folds re-begun ids into one HUD row.
    let opID = UUID()

    private let process: any ProcessPort
    private let hasFullDiskAccess: () -> Bool
    /// Resolves the mo executable; elevated runs use trusted locations only
    /// (never a PATH lookup a user-writable directory could shadow).
    private let resolveMo: (_ elevated: Bool) -> String?
    private let center: OperationCenter

    private var task: Task<Void, Never>?
    private var currentElevated = false
    private var currentLabel: String?
    private var cancelRequested = false
    /// One-shot per run: Burrow has already reclaimed focus from the auth
    /// dialog, don't keep stealing it.
    private var reactivated = false

    /// Pull key focus back to Burrow after an elevated run's auth dialog
    /// relinquished it elsewhere. No-op for un-elevated runs (no dialog) and
    /// after the first call.
    private func reactivateIfElevated(_ op: ToolOperation<Report>) {
        guard op.elevated, !reactivated else { return }
        reactivated = true
        NSApp.activate(ignoringOtherApps: true)
    }

    init(process: any ProcessPort = SystemProcessPort(),
         hasFullDiskAccess: @escaping () -> Bool = Privacy.hasFullDiskAccess,
         resolveMo: @escaping (_ elevated: Bool) -> String? = {
             $0 ? MoleCLI.trustedExecutable() : MoleCLI.findExecutable()
         },
         center: OperationCenter = .shared) {
        self.process = process
        self.hasFullDiskAccess = hasFullDiskAccess
        self.resolveMo = resolveMo
        self.center = center
    }

    func start(_ op: ToolOperation<Report>) {
        if case .running = state { return }

        if case .fullDiskAccess = op.gate, !op.elevated, !hasFullDiskAccess() {
            state = .gated(pending: op)
            return
        }

        let exe: String?
        switch op.executable {
        case .mo: exe = resolveMo(op.elevated)
        case .path(let p): exe = p
        }
        guard let executable = exe else {
            state = .finished(.failed(op.elevated
                ? "mo not found in a trusted location (Homebrew)" : "mo not found"))
            return
        }

        let spec = ProcessSpec(executable: executable, arguments: op.arguments,
                               stdin: op.stdin, elevated: op.elevated, timeout: op.timeout)
        state = .running
        report = nil
        currentElevated = op.elevated
        currentLabel = op.label
        cancelRequested = false
        reactivated = false
        if let label = op.label { center.begin(opID, label: label, notifiesOnEnd: op.notifyOnEnd) }

        let stream = process.events(spec)
        let id = opID
        task = Task { [weak self] in
            var lines: [String] = []
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .line(let l):
                    // The macOS auth dialog (osascript) takes key focus and
                    // hands it back to whatever, not us — so the first output
                    // of an elevated run (auth just cleared) is the cue to pull
                    // focus back to Burrow, instead of making the user ⌘-tab.
                    self.reactivateIfElevated(op)
                    lines.append(l)
                    self.report = op.reduce(lines)
                    if op.label != nil, !l.trimmingCharacters(in: .whitespaces).isEmpty {
                        self.center.detail(id, (op.hudLine ?? { $0 })(l))
                    }
                case .exited(let code):
                    guard !self.cancelRequested else { return }
                    self.reactivateIfElevated(op)   // backstop: no-output runs
                    self.report = op.reduce(lines)
                    self.state = .finished(.done(exit: code))
                    if op.label != nil {
                        // Replace the last streamed line with the parsed
                        // result line where the op provides one — that's
                        // what a completion notification shows.
                        let detail = self.report.map { op.finalDetail?($0) ?? "" } ?? ""
                        self.center.end(id, success: code == 0, detail: detail)
                    }
                case .authCancelled:
                    // Auth-cancel is classified by the runner now (#48 taxonomy),
                    // not by a view-level "elevated + nonzero + no output" guess.
                    guard !self.cancelRequested else { return }
                    self.reactivateIfElevated(op)
                    self.report = op.reduce(lines)
                    self.state = .finished(.failed(NSLocalizedString("authorization cancelled", comment: "")))
                    if op.label != nil { self.center.end(id, success: false) }
                }
            }
        }
    }

    func cancel() {
        guard canCancel else { return }
        cancelRequested = true
        task?.cancel()            // stream onTermination terminates the child
        state = .finished(.cancelled)
        if currentLabel != nil { center.end(opID, success: false) }
    }

    /// Back to the idle hero — the report screen's "Back" button.
    func reset() {
        state = .idle
        report = nil
    }
}

// MARK: - The mo report shape

/// What clean/optimize render: themed task groups + the run summary.
typealias TaskRunReport = (groups: [TaskGroup], summary: TaskSummary?)

extension ToolOperation where Report == TaskRunReport {
    /// A streaming `mo` run rendered through TaskReportView — the shape
    /// clean and optimize share. `notifyOnEnd` rides through to the
    /// completion notification, with the parsed summary (freed bytes)
    /// as the final detail line.
    static func moleStream(_ args: [String], gate: Gate = .none,
                           elevated: Bool = false, label: String?,
                           notifyOnEnd: Bool = false) -> ToolOperation {
        ToolOperation(label: label, arguments: args, gate: gate, elevated: elevated,
                      reduce: { parseTaskReport($0) },
                      hudLine: { TaskReportText.line($0) },
                      notifyOnEnd: notifyOnEnd,
                      finalDetail: { $0.summary?.completionLine ?? "" })
    }
}

// MARK: - Production adapter

/// The streaming-op spawn mechanics: plain runs stream
/// stdout+stderr through pipes; elevated runs go through ONE osascript auth
/// prompt with output tailed from a temp log (`do shell script` doesn't
/// stream); stdin is fed then closed; a timeout kills the child. All output
/// is ANSI-stripped and newline-split before it reaches the flow.
struct SystemProcessPort: ProcessPort {
    func events(_ spec: ProcessSpec) -> AsyncStream<ProcessEvent> {
        AsyncStream { cont in
            let splitter = LineSplitter()
            let t = Process()
            // One serial queue owns every splitter access, line yield, and the
            // final finish — so `cont.finish()` can never overtake a still-
            // pending `.line` from a reader. (The old readabilityHandler yielded
            // on a background queue while the termination handler finished on
            // main; with no ordering between them, finish() could land first and
            // silently drop lines — an intermittent CI failure that surfaced as
            // [] or ["a"] instead of ["a","b"].)
            let streamQ = DispatchQueue(label: "dev.caezium.burrow.opflow.stream")
            var tailTimer: Timer?
            var logHandle: FileHandle?
            var killTimer: DispatchSourceTimer?

            func emit(_ s: String) {                       // streamQ only
                for line in splitter.ingest(Ansi.strip(s)) { cont.yield(.line(line)) }
            }
            func finish(_ code: Int32) {                   // streamQ only
                for line in splitter.flush() { cont.yield(.line(line)) }
                cont.yield(Self.finalEvent(exitCode: code, elevated: spec.elevated,
                                           sawOutput: splitter.sawAnyLine))
                cont.finish()
            }

            let outPipe = Pipe(), errPipe = Pipe()

            if spec.elevated {
                // The osascript `do shell script` wrapper has no stdin channel,
                // so elevated + stdin is unsupported. No caller pairs them today
                // (stdin-fed flows like uninstall run un-elevated via MoleCLI.run);
                // assert so the unsupported combo fails loudly rather than
                // silently dropping the input if someone wires it up later.
                assert(spec.stdin == nil, "elevated runs don't support stdin")
                let safe = spec.arguments.map { $0.filter(\.isLetter) }.joined(separator: "-")
                let logPath = NSTemporaryDirectory() + "burrow-op-\(safe).log"
                FileManager.default.createFile(atPath: logPath, contents: Data())
                let script = MoleCLI.elevatedScript(executable: spec.executable,
                                                    args: spec.arguments, redirectTo: logPath)
                t.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                t.arguments = ["-e", script]
                t.standardOutput = outPipe
                t.standardError = errPipe

                let handle = FileHandle(forReadingAtPath: logPath)
                logHandle = handle
                let timer = Timer(timeInterval: 0.3, repeats: true) { _ in
                    guard let h = handle else { return }
                    let data = h.readDataToEndOfFile()
                    guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
                    streamQ.async { emit(s) }
                }
                RunLoop.main.add(timer, forMode: .common)
                tailTimer = timer

                t.terminationHandler = { proc in
                    killTimer?.cancel()
                    DispatchQueue.main.async { tailTimer?.invalidate() }
                    streamQ.async {
                        if let h = logHandle {                  // last tail of the log
                            let data = h.readDataToEndOfFile()
                            if !data.isEmpty, let s = String(data: data, encoding: .utf8) { emit(s) }
                            try? h.close()
                        }
                        finish(proc.terminationStatus)
                    }
                }
            } else {
                t.executableURL = URL(fileURLWithPath: spec.executable)
                t.arguments = spec.arguments
                t.standardOutput = outPipe
                t.standardError = errPipe
                if let stdin = spec.stdin {
                    let inPipe = Pipe()
                    t.standardInput = inPipe
                    inPipe.fileHandleForWriting.write(Data(stdin.utf8))
                    inPipe.fileHandleForWriting.closeFile()
                }
            }

            cont.onTermination = { @Sendable _ in
                DispatchQueue.main.async { tailTimer?.invalidate() }
                if t.isRunning { t.terminate() }
            }

            do {
                try t.run()
                // Armed only after a successful spawn (a suspended source
                // must never be cancelled/deallocated).
                if let timeout = spec.timeout {
                    let k = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                    k.schedule(deadline: .now() + timeout, repeating: .never)
                    k.setEventHandler { if t.isRunning { t.terminate() } }
                    k.resume()
                    killTimer = k
                }
                if !spec.elevated {
                    // Dedicated blocking reader per pipe, started only after a
                    // successful spawn (so a failed launch can't leak them).
                    // Each drains its pipe to EOF; ingest+yield hop synchronously
                    // onto streamQ; completion fires via the group ONLY once both
                    // pipes are at EOF — so finish() is strictly last and no line
                    // is lost (see streamQ note above).
                    let group = DispatchGroup()
                    for fh in [outPipe.fileHandleForReading, errPipe.fileHandleForReading] {
                        group.enter()
                        DispatchQueue.global(qos: .utility).async {
                            while case let d = fh.availableData, !d.isEmpty {
                                if let s = String(data: d, encoding: .utf8) { streamQ.sync { emit(s) } }
                            }
                            group.leave()
                        }
                    }
                    group.notify(queue: streamQ) {
                        killTimer?.cancel()
                        t.waitUntilExit()
                        finish(t.terminationStatus)
                    }
                }
            } catch {
                streamQ.async { finish(127) }
            }
        }
    }

    /// The one final-event rule (issue #48's error taxonomy): an elevated
    /// run that exits nonzero having produced NOTHING is a dismissed auth
    /// prompt, not a command failure. The predicate itself lives in
    /// `AuthCancel` so the streaming runner and the one-shot
    /// `SystemPrivilegeBroker` share one source of truth. Pure → table-tested.
    static func finalEvent(exitCode: Int32, elevated: Bool, sawOutput: Bool) -> ProcessEvent {
        if AuthCancel.isAuthCancelled(elevated: elevated, exitCode: exitCode, sawOutput: sawOutput) {
            return .authCancelled
        }
        return .exited(exitCode)
    }

    /// Buffers partial chunks and emits whole lines; thread-confined to
    /// whichever handler feeds it (pipe readability or the log tail timer).
    private final class LineSplitter: @unchecked Sendable {
        private var buffer = ""
        private var emitted = false
        private let lock = NSLock()
        /// Whether any line has been emitted — the auth-cancel classifier's
        /// "did the run produce output" input, tracked where lines are made.
        var sawAnyLine: Bool {
            lock.lock(); defer { lock.unlock() }
            return emitted
        }
        func ingest(_ s: String) -> [String] {
            lock.lock(); defer { lock.unlock() }
            buffer += s
            var parts = buffer.components(separatedBy: "\n")
            buffer = parts.removeLast()
            if !parts.isEmpty { emitted = true }
            return parts
        }
        func flush() -> [String] {
            lock.lock(); defer { lock.unlock() }
            let rest = buffer
            buffer = ""
            if !rest.isEmpty { emitted = true }
            return rest.isEmpty ? [] : [rest]
        }
    }
}
