//
//  ProcessActions.swift
//  Burrow
//
//  Per-process actions + best-effort energy for the Status process
//  table (design 3.2) and the popover's rows (3.5):
//
//    * PWR — cumulative billed energy via proc_pid_rusage
//      (ri_energy_billed), shown in mWh; "—" where the kernel reports
//      nothing. Never estimated.
//    * Row menu — Pin, Reveal in Finder, Copy name / PID, Quit
//      (SIGTERM) and Force Kill (SIGKILL) for own-user processes only;
//      root-owned rows get reveal/copy alone.
//
//  Plus the pure aggregates the popover reads: CleanWatch lifetime
//  totals from `mo history`, and the top-drain pick from snapshot
//  process lists.
//

import Foundation
import AppKit
import Darwin

enum ProcessActions {
    struct Identity: Equatable, Sendable {
        let pid: Int
        let ownerUID: uid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
        let executablePath: String?
    }

    struct TerminationTarget: Equatable, Sendable {
        let displayName: String
        let identity: Identity

        /// Text shown before confirmation comes from the captured snapshot,
        /// not a mutable live row. PID + owner + process birth time identify
        /// the process instance; the path also catches an in-place `exec`.
        var confirmationDetails: String {
            let started = String(format: "%llu.%06llu", identity.startSeconds, identity.startMicroseconds)
            let path = identity.executablePath ?? NSLocalizedString("executable path unavailable", comment: "")
            return "\(displayName) · PID \(identity.pid) · user \(identity.ownerUID) · started \(started)\n\(path)"
        }
    }

    enum TerminationResult: Equatable {
        case sent
        case cancelled
        case stale
        case notOwned
        case signalFailed
    }

    /// Cumulative billed energy for a pid, in nanojoules. nil when the
    /// kernel won't say (permission, exited, or platform). Flavor 4 is
    /// the first rusage_info with ri_energy_billed — pinned numerically
    /// so the C macro doesn't need to import.
    static func energyNanojoules(pid: Int) -> UInt64? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: (rusage_info_t?).self, capacity: 1) {
                proc_pid_rusage(Int32(pid), 4, $0)
            }
        }
        guard result == 0, usage.ri_billed_energy > 0 else { return nil }
        return usage.ri_billed_energy
    }

    /// "—" / "<1" / "25" — cumulative mWh, no invented precision.
    static func energyText(nanojoules: UInt64?) -> String {
        guard let nj = nanojoules, nj > 0 else { return "—" }
        let mWh = Double(nj) / 3_600_000_000
        if mWh < 1 { return "<1" }
        return String(format: "%.0f", mWh)
    }

    /// Whether this process belongs to the current user — the
    /// requirement for Quit / Force Kill. Root-owned rows are read-only.
    static func isOwnProcess(pid: Int) -> Bool {
        identity(pid: pid)?.ownerUID == getuid()
    }

    /// Executable path for reveal-in-Finder. nil for system stubs.
    static func executablePath(pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let n = proc_pidpath(Int32(pid), &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Immutable process instance captured before a destructive confirmation.
    /// A PID alone is unsafe because macOS can reuse it after the old process
    /// exits while the alert is still open.
    static func identity(pid: Int) -> Identity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let got = proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, &info, size)
        guard got == size else { return nil }
        return Identity(
            pid: pid,
            ownerUID: info.pbi_uid,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec,
            executablePath: executablePath(pid: pid)
        )
    }

    static func terminationTarget(pid: Int, displayName: String) -> TerminationTarget? {
        guard let identity = identity(pid: pid), identity.ownerUID == getuid() else { return nil }
        return TerminationTarget(displayName: displayName, identity: identity)
    }

    /// Re-read the owner and immutable identity immediately before signaling.
    /// Any exit, PID reuse, owner change, or `exec` fails closed.
    static func terminate(_ target: TerminationTarget, force: Bool) -> TerminationResult {
        terminate(
            target,
            force: force,
            currentUID: getuid(),
            readIdentity: identity(pid:),
            sendSignal: { Darwin.kill($0, $1) }
        )
    }

    static func terminate(
        _ target: TerminationTarget,
        force: Bool,
        currentUID: uid_t,
        readIdentity: (Int) -> Identity?,
        sendSignal: (Int32, Int32) -> Int32
    ) -> TerminationResult {
        guard target.identity.ownerUID == currentUID else { return .notOwned }
        guard let current = readIdentity(target.identity.pid) else { return .stale }
        guard current.ownerUID == currentUID else { return .notOwned }
        guard current == target.identity else { return .stale }
        let signal = force ? SIGKILL : SIGTERM
        return sendSignal(Int32(target.identity.pid), signal) == 0 ? .sent : .signalFailed
    }

    static func terminateIfConfirmed(
        _ target: TerminationTarget,
        force: Bool,
        confirmed: Bool,
        currentUID: uid_t,
        readIdentity: (Int) -> Identity?,
        sendSignal: (Int32, Int32) -> Int32
    ) -> TerminationResult {
        guard confirmed else { return .cancelled }
        return terminate(
            target,
            force: force,
            currentUID: currentUID,
            readIdentity: readIdentity,
            sendSignal: sendSignal
        )
    }

    /// One confirmation path for every visible Quit… / Force Kill… action.
    /// `onRefresh` runs after a confirmed attempt, including stale failures,
    /// so callers discard the row that led to the action.
    @MainActor @discardableResult
    static func confirmTermination(
        pid: Int,
        displayName: String,
        force: Bool = false,
        onRefresh: @escaping () -> Void = {}
    ) -> TerminationResult? {
        guard let target = terminationTarget(pid: pid, displayName: displayName) else {
            presentTerminationFailure(.stale)
            onRefresh()
            return .stale
        }

        return confirmTermination(target, force: force, onRefresh: onRefresh)
    }

    /// Present and act on one immutable candidate. Callers that discover a
    /// process asynchronously can pass the exact PID/owner/start/path snapshot
    /// they intend to show; the same value is then re-read and compared before
    /// any signal is sent.
    @MainActor @discardableResult
    static func confirmTermination(
        _ target: TerminationTarget,
        force: Bool = false,
        onRefresh: @escaping () -> Void = {}
    ) -> TerminationResult? {
        let alert = NSAlert()
        alert.messageText = force
            ? String(format: NSLocalizedString("Force kill %@?", comment: ""), target.displayName)
            : String(format: NSLocalizedString("Quit %@?", comment: ""), target.displayName)
        let consequence = force
            ? NSLocalizedString("SIGKILL ends it immediately, so unsaved work in this process is lost.", comment: "")
            : NSLocalizedString("SIGTERM asks the process to quit. It may save and exit, or ignore the request.", comment: "")
        alert.informativeText = "\(target.confirmationDetails)\n\n\(consequence)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: force
            ? NSLocalizedString("Force Kill", comment: "")
            : NSLocalizedString("Quit Process", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        guard alert.runModalQuiet() == .alertFirstButtonReturn else { return nil }

        let result = terminate(target, force: force)
        if result != .sent { presentTerminationFailure(result) }
        onRefresh()
        return result
    }

    @MainActor
    private static func presentTerminationFailure(_ result: TerminationResult) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Process wasn't quit", comment: "")
        switch result {
        case .stale:
            alert.informativeText = NSLocalizedString(
                "The process exited or its identity changed while the confirmation was open. The process list was refreshed and no signal was sent.",
                comment: ""
            )
        case .notOwned:
            alert.informativeText = NSLocalizedString(
                "The process is no longer owned by your user account. The process list was refreshed and no signal was sent.",
                comment: ""
            )
        case .signalFailed:
            alert.informativeText = NSLocalizedString(
                "macOS refused the signal or the process exited at the last moment. The process list was refreshed.",
                comment: ""
            )
        case .sent, .cancelled:
            return
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.runModalQuiet()
    }

    /// SIGSTOP — pause a process (freeze it without killing). Reversible via
    /// `resume`; own-user processes only (PRD §α Process Inspector).
    @discardableResult
    static func suspend(pid: Int) -> Bool { kill(Int32(pid), SIGSTOP) == 0 }

    /// SIGCONT — resume a previously suspended process.
    @discardableResult
    static func resume(pid: Int) -> Bool { kill(Int32(pid), SIGCONT) == 0 }
}

/// The full live process list for the Status table. `mo status --json`
/// caps `top_processes` at five, which left the tall process card showing
/// five rows over dead space — so the table samples the whole set itself
/// via `ps` (the unprivileged sysctl path; works for every user's
/// processes, no TTY, no elevation). CPU% is the kernel's decaying
/// average — the same figure `ps`/`top` print. Parsing is a pure function
/// of the output text (ProcessSamplerTests).
enum ProcessSampler {
    /// `=` headers suppress the title row; `comm` goes LAST because it is
    /// the executable path and may contain spaces.
    static let psArgs = ["axo", "pid=,ppid=,pcpu=,pmem=,rss=,comm="]

    /// One `ps` pass → rows sorted by CPU desc. Blocking (≈10–30 ms);
    /// call off the main thread. Empty on spawn failure — callers fall
    /// back to the snapshot's engine-provided top five.
    static func sample() -> [ProcessInfo] {
        guard let res = try? MoleCLI.run(args: psArgs, executable: "/bin/ps", timeout: 5),
              res.exitCode == 0 else { return [] }
        return parse(res.stdout)
    }

    /// Pure parser: "pid ppid %cpu %mem rss path…" per line. Malformed
    /// lines are skipped, never invented. rss arrives in KiB → bytes.
    static func parse(_ output: String) -> [ProcessInfo] {
        var rows: [ProcessInfo] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard fields.count == 6,
                  let pid = Int(fields[0]), let ppid = Int(fields[1]),
                  let cpu = Double(fields[2]), let mem = Double(fields[3]),
                  let rssKiB = UInt64(fields[4]) else { continue }
            let command = String(fields[5]).trimmingCharacters(in: .whitespaces)
            let name = (command as NSString).lastPathComponent
            guard !name.isEmpty else { continue }
            rows.append(ProcessInfo(pid: pid, ppid: ppid, name: name, command: command,
                                    cpu: cpu, memory: mem,
                                    memoryBytes: rssKiB > 0 ? rssKiB * 1024 : nil))
        }
        return rows.sorted { $0.cpu > $1.cpu }
    }
}

/// Lifetime cleanup totals for the popover's "Clean Watch" footer.
enum CleanWatch {
    struct Totals: Equatable {
        let cleanedBytes: Int64
        let uninstalledApps: Int
        let optimizeRuns: Int

        var isEmpty: Bool { cleanedBytes == 0 && uninstalledApps == 0 && optimizeRuns == 0 }
    }

    static func totals(from sessions: [HistorySession]) -> Totals {
        var bytes: Int64 = 0
        var uninstalled = 0
        var optimizes = 0
        for s in sessions {
            switch s.command {
            case "clean", "purge", "installer":
                bytes += CleanList.parseSize(s.size)
            case "uninstall":
                uninstalled += max(s.items, 0)
            case "optimize":
                optimizes += 1
            default:
                break
            }
        }
        return Totals(cleanedBytes: bytes, uninstalledApps: uninstalled, optimizeRuns: optimizes)
    }
}

/// "⚡ Top drain" for the battery card: the process with the highest
/// average CPU across the sampled snapshots. Upgrades to true energy
/// ranking when per-process PWR history lands.
enum TopDrain {
    static func heaviest(_ processLists: [[ProcessInfo]]) -> (name: String, avgCPU: Double)? {
        var sums: [String: (total: Double, count: Int)] = [:]
        for list in processLists {
            for p in list {
                let acc = sums[p.name] ?? (0, 0)
                sums[p.name] = (acc.total + p.cpu, acc.count + 1)
            }
        }
        guard let best = sums.max(by: { ($0.value.total / Double($0.value.count)) < ($1.value.total / Double($1.value.count)) }),
              best.value.count > 0 else { return nil }
        return (best.key, best.value.total / Double(best.value.count))
    }
}
