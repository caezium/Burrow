//
//  Doctor.swift
//  Burrow
//
//  Diagnostics report (roadmap I / appendix parity gap): a one-glance health
//  check from the Help menu — permissions, memory pressure, disk headroom,
//  the engine, recent errors. This is the pure half: system facts in, ranked
//  verdicts out, so the same logic backs the Help-menu sheet and (later) a
//  `burrow_doctor` MCP tool. Gathering the facts (TCC state, pressure, log
//  scan) is the integration half.
//

import Foundation

enum Doctor {
    enum Level: Int { case ok, warn, fail }  // Int so callers can sort worst-first
    enum MemoryPressure { case normal, warning, critical }

    struct Check: Equatable {
        let name: String
        let level: Level
        let detail: String
    }

    struct Input {
        var fullDiskAccess: Bool
        /// False when every probe location was missing rather than refused,
        /// so "off" would be a guess. Defaults true to keep existing callers
        /// and tests reading the same as before.
        var fullDiskAccessConclusive: Bool = true
        var moInstalled: Bool
        var pressure: MemoryPressure
        var diskFreeBytes: Int64
        var diskTotalBytes: Int64
        var recentErrorCount: Int
        /// Days since the last Time Machine backup; nil = none found / unknown.
        var lastBackupDaysAgo: Int? = nil
        /// SMART verdict: true = verified, false = failing, nil = unreadable.
        var smartVerified: Bool? = nil
        // Security posture (PRD §Doctor). `.unknown` on every facet = no data,
        // so the Security check is omitted (keeps the MCP seam + old tests valid).
        var sip: SecurityPosture.State = .unknown
        var gatekeeper: SecurityPosture.State = .unknown
        var fileVault: SecurityPosture.State = .unknown
        var firewall: SecurityPosture.State = .unknown
        /// Battery max-capacity %; nil = desktop / no battery → omitted.
        var batteryHealthPct: Int? = nil
        /// System-wide CPU load %; nil = unknown → omitted.
        var cpuLoadPercent: Double? = nil
        // Shared-report context (PRD §Doctor story 47). nil = unknown → omitted.
        var displayCount: Int? = nil
        var externalVolumeCount: Int? = nil
        var networkInterface: String? = nil
    }

    /// One `Check` per facet, in a stable order. Each verdict is independent;
    /// callers can sort by `level` to surface failures first. The security /
    /// battery / CPU checks are appended only when their facts are present.
    static func report(_ i: Input) -> [Check] {
        var checks = [engine(i), permissions(i), memory(i), disk(i), diskHealth(i), backup(i)]
        if let s = security(i) { checks.append(s) }
        if let b = battery(i) { checks.append(b) }
        if let c = highCPU(i) { checks.append(c) }
        if let d = displays(i) { checks.append(d) }
        if let v = volumes(i) { checks.append(v) }
        if let n = network(i) { checks.append(n) }
        checks.append(errors(i))
        return checks
    }

    private static func displays(_ i: Input) -> Check? {
        guard let n = i.displayCount else { return nil }
        return Check(name: "Displays", level: .ok, detail: n == 1 ? "1 display" : "\(n) displays")
    }

    private static func volumes(_ i: Input) -> Check? {
        guard let n = i.externalVolumeCount else { return nil }
        return Check(name: "External volumes", level: .ok,
                     detail: n == 0 ? "none mounted" : "\(n) mounted")
    }

    private static func network(_ i: Input) -> Check? {
        guard let iface = i.networkInterface, !iface.isEmpty else { return nil }
        return Check(name: "Network", level: .ok, detail: "primary interface: \(iface)")
    }

    private static func security(_ i: Input) -> Check? {
        let facets: [(String, SecurityPosture.State)] = [
            ("SIP", i.sip), ("Gatekeeper", i.gatekeeper), ("FileVault", i.fileVault), ("Firewall", i.firewall)]
        guard facets.contains(where: { $0.1 != .unknown }) else { return nil }   // no data → omit
        let off = facets.filter { $0.1 == .off }.map(\.0)
        return off.isEmpty
            ? Check(name: "Security", level: .ok, detail: "SIP, Gatekeeper, FileVault, firewall all on")
            : Check(name: "Security", level: .warn, detail: "off: " + off.joined(separator: ", "))
    }

    private static func battery(_ i: Input) -> Check? {
        guard let h = i.batteryHealthPct else { return nil }
        return h < 80
            ? Check(name: "Battery health", level: .warn, detail: "\(h)% of original capacity")
            : Check(name: "Battery health", level: .ok, detail: "\(h)% capacity")
    }

    private static func highCPU(_ i: Input) -> Check? {
        guard let c = i.cpuLoadPercent else { return nil }
        return c >= 90
            ? Check(name: "CPU load", level: .warn, detail: "high — \(Int(c.rounded()))%")
            : Check(name: "CPU load", level: .ok, detail: "\(Int(c.rounded()))%")
    }

    private static func engine(_ i: Input) -> Check {
        i.moInstalled
            ? Check(name: "Engine", level: .ok, detail: "mo is installed")
            : Check(name: "Engine", level: .fail, detail: "mo is not installed — core features are unavailable")
    }

    private static func permissions(_ i: Input) -> Check {
        if i.fullDiskAccess {
            return Check(name: "Full Disk Access", level: .ok, detail: "granted")
        }
        // Nothing was refused and nothing opened — every gated location this
        // build knows about is absent. Saying "off" here is what sent users
        // round the grant/relaunch loop for nothing (#177, #181, #319).
        guard i.fullDiskAccessConclusive else {
            return Check(name: "Full Disk Access", level: .warn,
                         detail: "could not be determined on this macOS build — grant it and rerun if scans stay limited")
        }
        return Check(name: "Full Disk Access", level: .warn,
                     detail: "off — some scans and cleanups are limited")
    }

    private static func memory(_ i: Input) -> Check {
        switch i.pressure {
        case .normal:   return Check(name: "Memory pressure", level: .ok, detail: "normal")
        case .warning:  return Check(name: "Memory pressure", level: .warn, detail: "elevated")
        case .critical: return Check(name: "Memory pressure", level: .fail, detail: "critical — the system is low on memory")
        }
    }

    private static func disk(_ i: Input) -> Check {
        guard i.diskTotalBytes > 0 else {
            return Check(name: "Disk space", level: .warn, detail: "unknown")
        }
        let freePct = Double(i.diskFreeBytes) / Double(i.diskTotalBytes) * 100
        if freePct < 5 {
            return Check(name: "Disk space", level: .fail, detail: "under 5% free")
        } else if freePct < 10 {
            return Check(name: "Disk space", level: .warn, detail: "under 10% free")
        }
        return Check(name: "Disk space", level: .ok, detail: "\(Int(freePct.rounded()))% free")
    }

    private static func diskHealth(_ i: Input) -> Check {
        switch i.smartVerified {
        case .some(true):  return Check(name: "Disk health", level: .ok, detail: "SMART status: verified")
        case .some(false): return Check(name: "Disk health", level: .fail, detail: "SMART status: failing — back up now")
        case .none:        return Check(name: "Disk health", level: .ok, detail: "SMART not reported")
        }
    }

    private static func backup(_ i: Input) -> Check {
        guard let days = i.lastBackupDaysAgo else {
            return Check(name: "Backups", level: .warn, detail: "no recent Time Machine backup found")
        }
        if days > 14 {
            return Check(name: "Backups", level: .warn, detail: "last backup \(days) days ago")
        }
        return Check(name: "Backups", level: .ok, detail: "last backup \(days) day\(days == 1 ? "" : "s") ago")
    }

    private static func errors(_ i: Input) -> Check {
        i.recentErrorCount == 0
            ? Check(name: "Recent errors", level: .ok, detail: "none logged")
            : Check(name: "Recent errors", level: .warn, detail: "\(i.recentErrorCount) in recent logs")
    }
}
