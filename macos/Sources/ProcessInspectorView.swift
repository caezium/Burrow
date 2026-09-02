//
//  ProcessInspectorView.swift
//  Burrow
//
//  Structured per-process inspector (PRD §α 55/56), modelled on ProcessSpy's
//  panel but in Burrow's identity: an identity header with signing/arch/sandbox
//  chips, then titled sections — Identity & Time, Process Details, Security,
//  Resource Usage (with a user/sys split bar), Disk I/O, Network, Hierarchy.
//  All facts come from unprivileged readers (ProcessOrigin, ProcessDeepMetrics,
//  CodeSignInfo, MachOArch, NetUsage); each pure core is tested, the syscalls
//  are the seam.
//

import SwiftUI
import AppKit

/// Identifiable wrapper so `.sheet(item:)` can drive the inspector without
/// making the widely-Codable `ProcessInfo` itself Identifiable.
struct ProcessInspectTarget: Identifiable {
    let proc: ProcessInfo
    var id: Int { proc.pid }
}

struct ProcessInspectorView: View {
    let proc: ProcessInfo
    /// The current process set — parent/children + the ProcessOrigin chain.
    let processes: [ProcessInfo]
    @Environment(\.dismiss) private var dismiss

    @State private var net: NetUsage.Rates?
    @State private var measuringNet = true
    @State private var deep: ProcessDeepMetrics.Metrics?
    @State private var sign: CodeSignInfo.Info?
    @State private var arch = ""
    @State private var path: String?
    /// On-disk binary gone (deleted/replaced after launch). It's a `stat()`, so
    /// it's resolved once in `load()` off-main rather than recomputed on every
    /// body redraw the way a computed `fileExists` property would be.
    @State private var binaryMissing = false

    private var accent: Color { Tool.status.accent }

    private var originTable: [Int: ProcessOrigin.Info] {
        Dictionary(processes.map { ($0.pid, ProcessOrigin.Info(name: $0.name, ppid: $0.ppid ?? 0)) },
                   uniquingKeysWith: { a, _ in a })
    }
    private var origin: ProcessOrigin.Origin { ProcessOrigin.classify(pid: proc.pid, table: originTable) }
    private var parent: ProcessInfo? { proc.ppid.flatMap { ppid in processes.first { $0.pid == ppid } } }
    private var children: [ProcessInfo] { processes.filter { $0.ppid == proc.pid } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Brand.hairline).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    identitySection
                    detailsSection
                    securitySection
                    resourceSection
                    ioNetworkSection
                    if !children.isEmpty { hierarchySection }
                }
                .padding(18)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: 540, height: 620)
        .task(id: proc.pid) { await load() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            AppIconView(proc: proc).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(proc.name).font(Brand.serif(19, .medium)).foregroundStyle(Brand.textPrimary).lineLimit(1)
                HStack(spacing: 6) {
                    Text(verbatim: "PID \(proc.pid)").font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                    if let d = deep, d.runtimeSeconds > 0 {
                        Text(verbatim: "· up \(Fmt.uptime(UInt64(max(0, d.runtimeSeconds))))")
                            .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                    }
                }
            }
            Spacer()
            chips
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: Brand.scaled(16))).foregroundStyle(Brand.textTertiary)
            }
            .buttonStyle(.plain).accessibilityLabel(NSLocalizedString("Close", comment: ""))
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    @ViewBuilder private var chips: some View {
        HStack(spacing: 5) {
            if !arch.isEmpty { chip(arch, Brand.textSecondary) }
            if let s = sign {
                chip(s.valid ? NSLocalizedString("Signed", comment: "") : NSLocalizedString("Unsigned", comment: ""),
                     s.valid ? Brand.green : Brand.red)
                if s.sandboxed { chip(NSLocalizedString("Sandboxed", comment: ""), Brand.blue) }
                if s.hardened { chip(NSLocalizedString("Hardened", comment: ""), accent) }
            }
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(Brand.mono(9, .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    // MARK: Sections

    private var identitySection: some View {
        section("Identity & Time", "clock") {
            if let d = deep, d.runtimeSeconds > 0 {
                kv("Started", Self.startedText(runtimeSeconds: d.runtimeSeconds))
                kv("Running", Fmt.uptime(UInt64(max(0, d.runtimeSeconds))))
            }
            kv("Origin", originText, valueColor: originTint)
        }
    }

    private var detailsSection: some View {
        section("Process Details", "doc.text") {
            kvMono("Program", path ?? NSLocalizedString("Unknown", comment: ""),
                   valueColor: binaryMissing ? Brand.red : Brand.textPrimary)
            if binaryMissing {
                note(NSLocalizedString("Program file no longer exists — deleted or replaced after launch.", comment: ""), Brand.red)
            }
            if let p = parent { kv("Parent", "\(p.name) · \(p.pid)") }
            kv("Command", proc.command, mono: true)
        }
    }

    private var securitySection: some View {
        section("Security", "lock.shield") {
            if let s = sign {
                kv("Signature", s.signer ?? NSLocalizedString("ad-hoc / unsigned", comment: ""),
                   valueColor: s.valid ? Brand.textPrimary : Brand.red)
                if let t = s.teamID, !t.isEmpty, t != s.signer { kvMono("Team ID", t) }
                kv("Hardened runtime", s.hardened ? yes : no, valueColor: s.hardened ? Brand.green : Brand.textSecondary)
                kv("App Sandbox", s.sandboxed ? yes : no, valueColor: s.sandboxed ? Brand.green : Brand.textSecondary)
            } else {
                kv("Signature", NSLocalizedString("not determined", comment: ""), valueColor: Brand.textTertiary)
            }
            if !arch.isEmpty { kv("Architecture", arch) }
        }
    }

    private var resourceSection: some View {
        section("Resource Usage", "speedometer") {
            kv("CPU", String(format: "%.1f%%", proc.cpu),
               valueColor: proc.cpu > 50 ? Brand.orange : (proc.cpu > 20 ? Brand.gold : Brand.textPrimary))
            if let d = deep {
                userSysRow(d)
                kv("Memory", Fmt.bytes(d.footprintBytes))
                kv("Peak memory", Fmt.bytes(d.peakFootprintBytes), valueColor: Brand.textSecondary)
                kv("Page-ins", Fmt.bytes(d.pageIns), valueColor: Brand.textSecondary)
                kv("Threads", "\(d.threads)")
            }
        }
    }

    private var ioNetworkSection: some View {
        section("Disk & Network", "arrow.up.arrow.down") {
            if let d = deep {
                kv("Disk read", Fmt.bytes(d.diskReadBytes), valueColor: Brand.textSecondary)
                kv("Disk written", Fmt.bytes(d.diskWriteBytes), valueColor: Brand.textSecondary)
            }
            kv("Network", netText, valueColor: Brand.textSecondary)
        }
    }

    private var hierarchySection: some View {
        section("Hierarchy", "list.bullet.indent") {
            ForEach(Array(children.prefix(10).enumerated()), id: \.offset) { _, c in
                HStack(spacing: 8) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: Brand.scaled(9))).foregroundStyle(Brand.textTertiary)
                    Text(c.name).font(Brand.sans(12)).foregroundStyle(Brand.textPrimary).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(verbatim: "\(c.pid)").font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                    Text(String(format: "%.1f%%", c.cpu)).font(Brand.mono(10)).foregroundStyle(Brand.textSecondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
            if children.count > 10 {
                Text(String(format: NSLocalizedString("+%d more", comment: ""), children.count - 10))
                    .font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
            }
        }
    }

    // MARK: Section + row builders

    private func section<C: View>(_ title: String, _ glyph: String, @ViewBuilder _ rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: title, glyph: glyph, color: accent)
            VStack(alignment: .leading, spacing: 7) { rows() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Brand.insetFill))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Brand.hairline, lineWidth: 1))
        }
    }

    private func kv(_ label: String, _ value: String, valueColor: Color = Brand.textPrimary, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(NSLocalizedString(label, comment: "")).font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                .frame(width: 116, alignment: .leading)
            Text(value).font(mono ? Brand.mono(11) : Brand.sans(12)).foregroundStyle(valueColor)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func kvMono(_ label: String, _ value: String, valueColor: Color = Brand.textPrimary) -> some View {
        kv(label, value, valueColor: valueColor, mono: true)
    }

    private func note(_ text: String, _ color: Color) -> some View {
        Text(text).font(Brand.mono(9)).foregroundStyle(color.opacity(0.9))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// CPU time row with a user/sys split bar (ProcessSpy's User/Sys).
    private func userSysRow(_ d: ProcessDeepMetrics.Metrics) -> some View {
        let total = d.userSeconds + d.systemSeconds
        let frac = ProcessDeepMetrics.userFraction(userSeconds: d.userSeconds, systemSeconds: d.systemSeconds) ?? 0
        return HStack(alignment: .center, spacing: 10) {
            Text(NSLocalizedString("CPU time", comment: "")).font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                .frame(width: 116, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(String(format: NSLocalizedString("%.1fs · %.0f%% user / %.0f%% system", comment: ""),
                            total, frac * 100, (1 - frac) * 100))
                    .font(Brand.mono(10)).foregroundStyle(Brand.textSecondary)
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        Capsule().fill(accent).frame(width: max(0, geo.size.width * frac))
                        Capsule().fill(Brand.textTertiary.opacity(0.5))
                    }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Data

    private func load() async {
        let pid = proc.pid
        deep = ProcessDeepMetrics.read(pid: pid)
        let p = ProcessActions.executablePath(pid: pid)
        path = p
        // Fold the binary-exists stat() into the off-main block — the inspector
        // body reads `binaryMissing` on every redraw, so a computed fileExists
        // would be a syscall per render.
        let (s, a, missing): (CodeSignInfo.Info?, String, Bool) = await Task.detached(priority: .utility) {
            (CodeSignInfo.read(pid: pid),
             p.map(MachOArch.label(path:)) ?? "",
             p.map { !FileManager.default.fileExists(atPath: $0) } ?? false)
        }.value
        sign = s; arch = a; binaryMissing = missing
        let r = await Task.detached(priority: .utility) { NetUsage.sample()[pid] }.value
        net = r; measuringNet = false
    }

    private var netText: String {
        if measuringNet { return NSLocalizedString("measuring…", comment: "") }
        guard let net, net.down > 0 || net.up > 0 else { return NSLocalizedString("idle", comment: "") }
        return String(format: NSLocalizedString("↓ %@/s   ↑ %@/s", comment: ""),
                      Fmt.bytes(net.down), Fmt.bytes(net.up))
    }

    private var yes: String { NSLocalizedString("Yes", comment: "") }
    private var no: String { NSLocalizedString("No", comment: "") }

    private var originText: String {
        switch origin {
        case .login:        return NSLocalizedString("Launched at login / from the Dock", comment: "")
        case .shell(let s): return String(format: NSLocalizedString("Started from a %@ shell", comment: ""), s)
        case .ssh:          return NSLocalizedString("Started over SSH (remote session)", comment: "")
        }
    }
    private var originTint: Color {
        switch origin {
        case .login: return Brand.textPrimary
        case .shell: return Brand.gold
        case .ssh:   return Brand.orange
        }
    }

    private static let startedFmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()
    /// Approximate wall-clock start time from the runtime (now − runtime).
    private static func startedText(runtimeSeconds: Double) -> String {
        startedFmt.localizedString(fromTimeInterval: -runtimeSeconds)   // cached formatter (#240)
    }
}
