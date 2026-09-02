//
//  DoctorView.swift
//  Burrow
//
//  Diagnostics Home section (roadmap I). Renders Doctor.report — engine,
//  Full Disk Access, memory pressure, disk headroom, recent errors — from the
//  latest snapshot + live permission/engine checks. Same verdict logic as the
//  burrow_doctor MCP tool.
//
//  NOTE (hand-test): verify the checks populate and the ok/warn/fail colours
//  read correctly against a real machine.
//

import SwiftUI
import AppKit

struct DoctorView: View {
    let db: DB
    @State private var checks: [Doctor.Check] = []

    /// The rarely-changing, subprocess-backed posture probes, cached across
    /// reopens with a short TTL. #239
    private typealias Probes = (backup: Int?, smart: Bool?,
                                sip: SecurityPosture.State, gatekeeper: SecurityPosture.State,
                                fileVault: SecurityPosture.State, firewall: SecurityPosture.State,
                                volumes: Int, iface: String?)
    private static var cachedProbes: (at: Date, value: Probes)?
    private static let probeTTL: TimeInterval = 120

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(NSLocalizedString("Diagnostics", comment: ""))
                        .font(Brand.serif(22, .medium)).foregroundStyle(Brand.textPrimary)
                    Spacer()
                    Button { copyDiagnostics() } label: {
                        Label(NSLocalizedString("Copy", comment: ""), systemImage: "doc.on.doc")
                            .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                    }
                    .buttonStyle(.plain).disabled(checks.isEmpty)
                }

                if checks.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(NSLocalizedString("Running checks…", comment: ""))
                            .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                    }
                    .padding(.vertical, 8)
                } else {
                    // One borderless card; checks separated by hairlines rather
                    // than boxed individually — matches the dashboard's read.
                    GlassCard {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(checks.enumerated()), id: \.offset) { i, c in
                                if i > 0 {
                                    Rectangle().fill(Brand.hairline).frame(height: 1)
                                }
                                row(c)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .fadeEdges()
        .task { await reload() }
    }

    private func row(_ c: Doctor.Check) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: glyph(c.level)).font(.system(size: 15))
                .foregroundStyle(tint(c.level)).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name).font(Brand.sans(13, .semibold)).foregroundStyle(Brand.textPrimary)
                Text(c.detail).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(label(c.level)).font(Brand.mono(9, .medium)).foregroundStyle(tint(c.level))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(tint(c.level).opacity(0.14)))
        }
        .padding(.vertical, 10)
    }

    private func glyph(_ l: Doctor.Level) -> String {
        switch l {
        case .ok:   return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        }
    }

    private func tint(_ l: Doctor.Level) -> Color {
        switch l {
        case .ok:   return Brand.green
        case .warn: return Brand.gold
        case .fail: return Brand.red
        }
    }

    private func label(_ l: Doctor.Level) -> String {
        switch l {
        case .ok:   return NSLocalizedString("ok", comment: "")
        case .warn: return NSLocalizedString("warn", comment: "")
        case .fail: return NSLocalizedString("fail", comment: "")
        }
    }

    private func reload() async {
        let latest = MetricsStore(db: db).latest()?.status
        var free: Int64 = 0, total: Int64 = 0
        if let d = latest?.disks.max(by: { $0.total < $1.total }) {
            total = Int64(d.total)
            free = Int64(d.total > d.used ? d.total - d.used : 0)
        }
        let moInstalled: Bool
        if case .installed = EngineRunner.shared.availability() { moInstalled = true } else { moInstalled = false }
        let p = (latest?.memory.pressure ?? "").lowercased()
        let pressure: Doctor.MemoryPressure = p.contains("critical") ? .critical
            : (p.contains("warn") ? .warning : .normal)
        let fdaDiagnosis = Privacy.diagnoseFullDiskAccess()
        let fullDiskAccess = fdaDiagnosis.hasAccess
        let recentErrorCount = MetricsStore.driftCounters.decodeSkippedTotal
        // `tmutil latestbackup` and `system_profiler SPNVMeDataType` each spawn a
        // subprocess and block on waitUntilExit() — system_profiler routinely
        // takes seconds. Running them inline here (`.task` is MainActor-isolated)
        // froze the main thread long enough to trip Sentry's ≥2000ms App Hang
        // detector. Probe off the main thread, then publish on the main actor.
        let cpuLoad = latest?.cpu.usage
        let battHealth: Int? = (latest?.batteries?.first?.capacity).flatMap { $0 > 0 ? $0 : nil }
        let displays = NSScreen.screens.count   // main-actor; reload is @MainActor
        // Security posture (SIP/Gatekeeper/FileVault/firewall), SMART and the
        // last-backup age change ~never, but each Doctor reopen used to re-spawn
        // system_profiler + tmutil + four security tools. Cache the whole probe
        // set with a short TTL so rapid reopens are instant. #239
        let probes: Probes
        if let c = Self.cachedProbes, Date().timeIntervalSince(c.at) < Self.probeTTL {
            probes = c.value
        } else {
            probes = await Task.detached(priority: .utility) {
                (backup: BackupStatus.lastBackupDaysAgo(),
                 smart: DiskHealth.smartVerified(),
                 sip: SecurityPosture.sip(DoctorView.run("/usr/bin/csrutil", ["status"])),
                 gatekeeper: SecurityPosture.gatekeeper(DoctorView.run("/usr/sbin/spctl", ["--status"])),
                 fileVault: SecurityPosture.fileVault(DoctorView.run("/usr/bin/fdesetup", ["status"])),
                 firewall: SecurityPosture.firewall(DoctorView.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"])),
                 volumes: DoctorView.externalVolumeCount(),
                 iface: Connectivity.defaultRoute(fromRouteGet: DoctorView.run("/sbin/route", ["-n", "get", "default"])).interface)
            }.value
            Self.cachedProbes = (Date(), probes)
        }
        checks = Doctor.report(.init(
            fullDiskAccess: fullDiskAccess,
            fullDiskAccessConclusive: fdaDiagnosis.conclusive,
            moInstalled: moInstalled, pressure: pressure,
            diskFreeBytes: free, diskTotalBytes: total,
            recentErrorCount: recentErrorCount,
            lastBackupDaysAgo: probes.backup,
            smartVerified: probes.smart,
            sip: probes.sip, gatekeeper: probes.gatekeeper,
            fileVault: probes.fileVault, firewall: probes.firewall,
            batteryHealthPct: battHealth,
            cpuLoadPercent: cpuLoad,
            displayCount: displays,
            externalVolumeCount: probes.volumes,
            networkInterface: probes.iface))
    }

    /// Count of mounted non-internal (external/removable) volumes, for the
    /// Doctor context line. Off-main (FileManager volume reads can touch disk).
    private static func externalVolumeCount() -> Int {
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsInternalKey],
                                                         options: [.skipHiddenVolumes]) ?? []
        return vols.filter {
            (try? $0.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal) == false
        }.count
    }

    /// Capture a short system command's stdout (off-main; used for the security
    /// posture probes). Self-contained so it doesn't depend on the engine seam.
    private static func run(_ path: String, _ args: [String]) -> String {
        ShellProbe.run(path, args, timeout: 10) ?? ""   // timeout-guarded (#239)
    }

    private func copyDiagnostics() {
        let text = checks.map { "[\(label($0.level).uppercased())] \($0.name): \($0.detail)" }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
