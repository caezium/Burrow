//
//  ProcessWatchdog.swift
//  Burrow
//
//  The impure seam around ProcessRule (PRD §α): keeps a per-pid rolling CPU
//  buffer fed by the Status process pump, evaluates the opt-in watchdog rule
//  each tick (pure ProcessRule.fires), and dispatches the configured action —
//  notify / suspend / quit. Disabled by default (Store.processWatchdogEnabled);
//  when off it clears its buffers and does nothing. Suspend only touches an
//  own-user process; quit captures PID/owner/start/path and requires the user
//  to confirm that exact candidate before ProcessActions can signal it.
//

import Foundation
import UserNotifications

final class ProcessWatchdog {
    struct ProcessControl {
        let isOwnProcess: (Int) -> Bool
        let suspend: (Int) -> Void
        let terminationTarget: (Int, String) -> ProcessActions.TerminationTarget?
        let confirmTermination: @MainActor (
            ProcessActions.TerminationTarget,
            @escaping () -> Void
        ) -> ProcessActions.TerminationResult?
        let notify: (Int, String, Double, String?) -> Void

        init(
            isOwnProcess: @escaping (Int) -> Bool,
            suspend: @escaping (Int) -> Void,
            terminationTarget: @escaping (Int, String) -> ProcessActions.TerminationTarget?,
            confirmTermination: @escaping @MainActor (
                ProcessActions.TerminationTarget,
                @escaping () -> Void
            ) -> ProcessActions.TerminationResult?,
            notify: @escaping (Int, String, Double, String?) -> Void = { _, _, _, _ in }
        ) {
            self.isOwnProcess = isOwnProcess
            self.suspend = suspend
            self.terminationTarget = terminationTarget
            self.confirmTermination = confirmTermination
            self.notify = notify
        }

        static let live = ProcessControl(
            isOwnProcess: ProcessActions.isOwnProcess(pid:),
            suspend: { _ = ProcessActions.suspend(pid: $0) },
            terminationTarget: { ProcessActions.terminationTarget(pid: $0, displayName: $1) },
            confirmTermination: { ProcessActions.confirmTermination($0, onRefresh: $1) },
            notify: { ProcessWatchdog.notify(pid: $0, name: $1, threshold: $2, suffix: $3) }
        )
    }

    private var samples: [Int: [Double]] = [:]   // pid → recent cpu%, oldest→newest
    private var fired: Set<Int> = []             // pids already actioned (dedup until they calm)
    private let cap = 64
    private let processControl: ProcessControl
    private let configuredAction: () -> ProcessRule.Action

    init(
        processControl: ProcessControl = .live,
        configuredAction: @escaping () -> ProcessRule.Action = {
            ProcessRule.Action(rawValue: Store.processWatchdogAction) ?? .notify
        }
    ) {
        self.processControl = processControl
        self.configuredAction = configuredAction
    }

    /// Feed one process tick. Returns the processes that NEWLY fired the rule so
    /// the caller can dispatch. The pump cadence is ~2s, so the rule's
    /// sustain-seconds are converted to a sample count here.
    func step(processes: [ProcessInfo], cadenceSeconds: Int) -> [(pid: Int, name: String)] {
        guard Store.processWatchdogEnabled else {
            if !samples.isEmpty { samples.removeAll() }
            if !fired.isEmpty { fired.removeAll() }
            return []
        }
        let live = Set(processes.map { $0.pid })
        samples = samples.filter { live.contains($0.key) }   // drop exited pids
        fired = fired.intersection(live)

        let threshold = Store.processWatchdogCPU
        let sustainSamples = max(1, Store.processWatchdogSeconds / max(1, cadenceSeconds))
        let rule = ProcessRule.Rule(metric: .cpu, threshold: threshold,
                                    sustainSeconds: sustainSamples, action: action)

        var newlyFired: [(pid: Int, name: String)] = []
        for p in processes {
            var buf = samples[p.pid] ?? []
            buf.append(p.cpu)
            if buf.count > cap { buf.removeFirst(buf.count - cap) }
            samples[p.pid] = buf
            if p.cpu <= threshold { fired.remove(p.pid) }     // re-arm once it calms down
            guard !fired.contains(p.pid) else { continue }
            if ProcessRule.fires(rule, samples: buf) {
                fired.insert(p.pid)
                newlyFired.append((pid: p.pid, name: p.name))
            }
        }
        return newlyFired
    }

    /// Dispatch the configured action for a fired process.
    @MainActor
    func dispatch(pid: Int, name: String, onRefresh: @escaping () -> Void = {}) {
        let threshold = Store.processWatchdogCPU
        switch action {
        case .notify:
            processControl.notify(pid, name, threshold, nil)
        case .suspend:
            if processControl.isOwnProcess(pid) { processControl.suspend(pid) }
            processControl.notify(pid, name, threshold, NSLocalizedString("suspended", comment: ""))
        case .quit:
            guard let target = processControl.terminationTarget(pid, name) else {
                onRefresh()
                processControl.notify(pid, name, threshold,
                                      NSLocalizedString("identity changed; no action taken", comment: ""))
                return
            }
            if processControl.confirmTermination(target, onRefresh) == .sent {
                processControl.notify(pid, name, threshold,
                                      NSLocalizedString("asked to quit", comment: ""))
            }
        }
    }

    private var action: ProcessRule.Action {
        configuredAction()
    }

    private static func notify(pid: Int, name: String, threshold: Double, suffix: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("High-CPU process", comment: "")
        let base = String(format: NSLocalizedString("%@ stayed above %.0f%% CPU", comment: ""), name, threshold)
        content.body = suffix.map { "\(base) — \($0)." } ?? "\(base)."
        content.userInfo = ["pane": "status"]
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                center.add(UNNotificationRequest(identifier: "burrow.watchdog.\(pid)",
                                                 content: content, trigger: nil))
            default:
                break
            }
        }
    }
}
