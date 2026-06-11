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
        if let label = op.label { center.begin(opID, label: label) }

        let stream = process.events(spec)
        let id = opID
        task = Task { [weak self] in
            var lines: [String] = []
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .line(let l):
                    lines.append(l)
                    self.report = op.reduce(lines)
                    if op.label != nil, !l.trimmingCharacters(in: .whitespaces).isEmpty {
                        self.center.detail(id, (op.hudLine ?? { $0 })(l))
                    }
                case .exited(let code):
                    guard !self.cancelRequested else { return }
                    self.report = op.reduce(lines)
                    if op.elevated, code != 0, lines.isEmpty {
                        // The auth prompt was dismissed — osascript exits
                        // nonzero having produced nothing.
                        self.state = .finished(.failed(NSLocalizedString("authorization cancelled", comment: "")))
                        if op.label != nil { self.center.end(id, success: false) }
                    } else {
                        self.state = .finished(.done(exit: code))
                        if op.label != nil { self.center.end(id, success: code == 0) }
                    }
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
    /// clean and optimize share.
    static func moleStream(_ args: [String], gate: Gate = .none,
                           elevated: Bool = false, label: String?) -> ToolOperation {
        ToolOperation(label: label, arguments: args, gate: gate, elevated: elevated,
                      reduce: { parseTaskReport($0) },
                      hudLine: { TaskReportText.line($0) })
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
            var tailTimer: Timer?
            var logHandle: FileHandle?

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
                t.standardOutput = Pipe()
                t.standardError = Pipe()

                let handle = FileHandle(forReadingAtPath: logPath)
                logHandle = handle
                let timer = Timer(timeInterval: 0.3, repeats: true) { _ in
                    guard let h = handle else { return }
                    let data = h.readDataToEndOfFile()
                    guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
                    for line in splitter.ingest(Ansi.strip(s)) { cont.yield(.line(line)) }
                }
                RunLoop.main.add(timer, forMode: .common)
                tailTimer = timer
            } else {
                t.executableURL = URL(fileURLWithPath: spec.executable)
                t.arguments = spec.arguments
                let outPipe = Pipe(), errPipe = Pipe()
                t.standardOutput = outPipe
                t.standardError = errPipe
                let handler: @Sendable (FileHandle) -> Void = { h in
                    let d = h.availableData
                    guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
                    for line in splitter.ingest(Ansi.strip(s)) { cont.yield(.line(line)) }
                }
                outPipe.fileHandleForReading.readabilityHandler = handler
                errPipe.fileHandleForReading.readabilityHandler = handler

                if let stdin = spec.stdin {
                    let inPipe = Pipe()
                    t.standardInput = inPipe
                    inPipe.fileHandleForWriting.write(Data(stdin.utf8))
                    inPipe.fileHandleForWriting.closeFile()
                }
            }

            // Declared before the termination handler so the handler's
            // capture (of the variable box) retains the timer — an
            // unreferenced DispatchSource is deallocated before it fires.
            var killTimer: DispatchSourceTimer?

            t.terminationHandler = { proc in
                killTimer?.cancel()
                let outPipe = proc.standardOutput as? Pipe
                let errPipe = proc.standardError as? Pipe
                outPipe?.fileHandleForReading.readabilityHandler = nil
                errPipe?.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async {
                    tailTimer?.invalidate()
                    if let h = logHandle {
                        // Elevated: tail the temp log one last time.
                        let data = h.readDataToEndOfFile()
                        if !data.isEmpty, let s = String(data: data, encoding: .utf8) {
                            for line in splitter.ingest(Ansi.strip(s)) { cont.yield(.line(line)) }
                        }
                        try? h.close()
                    } else {
                        // Non-elevated: the readabilityHandler is best-effort and
                        // can miss the final chunk of a process that prints then
                        // exits immediately (e.g. `printf …; exit`) — the handler
                        // is nil'd above before that chunk is delivered. Drain
                        // whatever's left so the last line isn't dropped (this was
                        // an intermittent CI failure: got ["a"], expected ["a","b"]).
                        for pipe in [outPipe, errPipe] {
                            guard let pipe else { continue }
                            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                            if !rest.isEmpty, let s = String(data: rest, encoding: .utf8) {
                                for line in splitter.ingest(Ansi.strip(s)) { cont.yield(.line(line)) }
                            }
                        }
                    }
                    for line in splitter.flush() { cont.yield(.line(line)) }
                    cont.yield(.exited(proc.terminationStatus))
                    cont.finish()
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
            } catch {
                cont.yield(.exited(127))
                cont.finish()
            }
        }
    }

    /// Buffers partial chunks and emits whole lines; thread-confined to
    /// whichever handler feeds it (pipe readability or the log tail timer).
    private final class LineSplitter: @unchecked Sendable {
        private var buffer = ""
        private let lock = NSLock()
        func ingest(_ s: String) -> [String] {
            lock.lock(); defer { lock.unlock() }
            buffer += s
            var parts = buffer.components(separatedBy: "\n")
            buffer = parts.removeLast()
            return parts
        }
        func flush() -> [String] {
            lock.lock(); defer { lock.unlock() }
            let rest = buffer
            buffer = ""
            return rest.isEmpty ? [] : [rest]
        }
    }
}
