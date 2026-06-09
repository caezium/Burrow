//
//  PopupView.swift
//  Burrow
//
//  The menu-bar HUD — Burrow's take on mole.fit's menu-bar popover, on
//  the same brand + data path as the Status tab. It reuses the Status
//  data model exactly: live values from `Sampler.lastSnapshot`, mini
//  sparklines from `DB.findRangeSampled(prefix: Sampler.snapshotPrefix)`,
//  rendered with the shared Brand components (Eyebrow / MiniChart /
//  HealthRing / ProgressBar). The popover stays owned by
//  StatusBarController; this is just the SwiftUI it hosts.
//

import SwiftUI
import AppKit

struct PopupView: View {
    @StateObject private var model: HUDModel
    @ObservedObject private var ops = OperationCenter.shared
    private weak var delegate: AppDelegate?

    init(db: DB, sampler: Sampler, delegate: AppDelegate) {
        _model = StateObject(wrappedValue: HUDModel(db: db, sampler: sampler))
        self.delegate = delegate
    }

    var body: some View {
        // No ScrollView: the popover sizes to this content, so there's no
        // scrollbar (which, with "always show scrollbars", was eating width
        // and shifting everything left). Kept compact so it fits on screen.
        // No custom background — the popover's own dark material paints both
        // the box and the arrow, so they match.
        VStack(alignment: .leading, spacing: 9) {
            header
            if ops.hasActivity { activitySection }   // running jobs up top, where they're seen
            if let s = model.snap {
                healthHero(s)
                metricGrid(s)
                DiskBatteryRows(s: s)
                topProcesses(s)
            } else {
                waiting
            }
            Rectangle().fill(Brand.hairline).frame(height: 1)
            footer
        }
        .padding(13)
        .frame(width: 334)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.colorScheme, .dark)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 7) {
            BurrowMark().frame(width: 18, height: 18)
            Text("Burrow").font(Brand.sans(13, .semibold)).foregroundStyle(Brand.textPrimary)
            Spacer()
            Text(model.freshness).font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
        }
    }

    private var waiting: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Waiting for the first sample…")
                .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
    }

    // MARK: Activity (cards for running / just-finished jobs, at the bottom)

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Eyebrow(text: "Activity", glyph: "bolt.fill", color: Brand.gold)
                Spacer()
                if runningCount > 0 {
                    Text("\(runningCount) running").font(Brand.mono(9, .medium)).foregroundStyle(Brand.gold)
                }
            }
            ForEach(ops.ops) { op in opRow(op) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Brand.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Brand.hairline, lineWidth: 1))
    }

    private var runningCount: Int { ops.ops.filter { $0.phase == .running }.count }

    @ViewBuilder
    private func opRow(_ op: OperationCenter.Op) -> some View {
        let accent = opAccent(op.label)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                opIcon(op.phase, accent: accent)
                Text(op.label).font(Brand.sans(11, .medium)).foregroundStyle(Brand.textPrimary).lineLimit(1)
                Spacer(minLength: 4)
                opStatus(op)
            }
            if !op.detail.isEmpty {
                Text(op.detail).font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                    .lineLimit(1).truncationMode(.middle).padding(.leading, 23)
            }
            if op.phase == .running {
                IndeterminateBar(color: accent).padding(.leading, 23)
            }
        }
    }

    @ViewBuilder
    private func opIcon(_ phase: OperationCenter.Phase, accent: Color) -> some View {
        switch phase {
        case .running:
            Circle().fill(accent).frame(width: 8, height: 8)
                .shadow(color: accent.opacity(0.6), radius: 3).padding(3.5)
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Brand.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(Brand.red)
        }
    }

    @ViewBuilder
    private func opStatus(_ op: OperationCenter.Op) -> some View {
        switch op.phase {
        case .running:
            TimelineView(.periodic(from: Date(), by: 1)) { ctx in
                Text(Self.elapsed(from: op.startedAt, to: ctx.date))
                    .font(Brand.mono(9)).foregroundStyle(Brand.textSecondary)
            }
        case .done:
            Text("done").font(Brand.mono(9, .medium)).foregroundStyle(Brand.green)
        case .failed:
            Text("failed").font(Brand.mono(9, .medium)).foregroundStyle(Brand.red)
        }
    }

    /// Tint a job by its verb so the menu-bar HUD echoes the tool colours.
    private func opAccent(_ label: String) -> Color {
        let l = label.lowercased()
        if l.contains("clean") { return Tool.clean.accent }
        if l.contains("optimi") { return Tool.optimize.accent }
        if l.contains("analy") { return Tool.analyze.accent }
        if l.contains("uninstall") { return Tool.apps.accent }
        return Brand.gold
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s < 60 ? "\(s)s" : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Thin indeterminate progress bar for a running op — conveys "still
    /// working" without a fake percentage we don't have.
    private struct IndeterminateBar: View {
        let color: Color
        @State private var animate = false
        var body: some View {
            GeometryReader { geo in
                Capsule().fill(color.opacity(0.16))
                    .overlay(alignment: .leading) {
                        Capsule().fill(color)
                            .frame(width: geo.size.width * 0.35)
                            .offset(x: animate ? geo.size.width * 0.65 : 0)
                    }
                    .clipShape(Capsule())
            }
            .frame(height: 3)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { animate = true }
            }
        }
    }

    // MARK: Health hero

    private func healthHero(_ s: MoleStatus) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Eyebrow(text: "Health", glyph: "checkmark.seal.fill", color: Brand.gold)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(s.healthScore)").font(Brand.mono(24, .semibold)).foregroundStyle(Brand.textPrimary)
                    Text(HealthRating.label(s.healthScore)).font(Brand.sans(11, .medium))
                        .foregroundStyle(HealthRating.color(s.healthScore))
                }
                Text(specLine(s)).font(Brand.mono(9)).foregroundStyle(Brand.textTertiary).lineLimit(1)
            }
            Spacer()
            HealthRing(score: s.healthScore, color: HealthRating.color(s.healthScore))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Brand.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Brand.hairline, lineWidth: 1))
    }

    private func specLine(_ s: MoleStatus) -> String {
        let cpu = s.hardware.cpuModel.replacingOccurrences(of: "Apple ", with: "")
        return String(format: NSLocalizedString("%@ · %@ · up %@", comment: ""),
                      cpu, s.hardware.totalRam, Fmt.uptime(s.uptimeSeconds))
    }

    // MARK: Metric grid

    private func metricGrid(_ s: MoleStatus) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            HUDTile(eyebrow: "CPU", glyph: "cpu", accent: Brand.green,
                    value: String(format: "%.0f", s.cpu.usage), unit: "%",
                    values: model.cpuHist, style: .bars,
                    foot: String(format: "load %.2f", s.cpu.load1))
            HUDTile(eyebrow: "Memory", glyph: "memorychip", accent: Brand.amber,
                    value: String(format: "%.0f", s.memory.usedPercent), unit: "%",
                    values: model.memHist, style: .area,
                    foot: String(format: "%.1f/%.0f GB", Double(s.memory.used) / 1_073_741_824, Double(s.memory.total) / 1_073_741_824))
            HUDTile(eyebrow: "Network", glyph: "network", accent: Brand.green,
                    value: netValue(s).0, unit: netValue(s).1,
                    values: model.netHist, style: .area,
                    foot: netFoot(s))
            HUDTile(eyebrow: "GPU", glyph: "cpu.fill", accent: Brand.orange,
                    value: gpuValue(s).0, unit: gpuValue(s).1,
                    values: model.gpuHist, style: .area,
                    foot: (s.gpu?.first?.name ?? "GPU").replacingOccurrences(of: "Apple ", with: ""))
        }
    }

    private func netValue(_ s: MoleStatus) -> (String, String) {
        let total = s.network.reduce(0.0) { $0 + $1.rxRateMbs + $1.txRateMbs }
        return total < 1 ? (String(format: "%.0f", total * 1024), "KB/s") : (String(format: "%.1f", total), "MB/s")
    }
    private func netFoot(_ s: MoleStatus) -> String {
        let n = s.network.first(where: { !$0.ip.isEmpty }) ?? s.network.first
        return n.map { String(format: NSLocalizedString("↓ %d ↑ %d KB/s", comment: ""),
                              Int($0.rxRateMbs * 1024), Int($0.txRateMbs * 1024)) } ?? "—"
    }
    private func gpuValue(_ s: MoleStatus) -> (String, String) {
        let u = s.gpu?.first?.usage ?? -1
        return u >= 0 ? (String(format: "%.0f", u), "%") : ("—", "")
    }

    // MARK: Top processes

    private func topProcesses(_ s: MoleStatus) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Eyebrow(text: "Top processes", glyph: "list.bullet", color: Brand.textSecondary)
            ForEach(Array((s.topProcesses ?? []).prefix(4).enumerated()), id: \.offset) { _, p in
                HStack(spacing: 8) {
                    Image(nsImage: AppIcon.image(for: p) ?? PopupView.blankIcon)
                        .resizable().frame(width: 15, height: 15)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    Text(p.name).font(Brand.sans(11)).foregroundStyle(Brand.textPrimary).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(String(format: "%.1f%%", p.cpu)).font(Brand.mono(10))
                        .foregroundStyle(p.cpu > 30 ? Brand.orange : Brand.textSecondary)
                }
            }
        }
    }

    private static let blankIcon = NSImage(size: NSSize(width: 15, height: 15))

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 8) {
            // Icon pills — text labels for every tool overflow the narrow
            // popover; glyphs (tinted by tool) stay compact and tidy.
            HStack(spacing: 6) {
                ForEach(Tool.navOrder) { tool in
                    Button { open(.tool(tool)) } label: {
                        Image(systemName: tool.glyph)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(tool.accent)
                            .frame(width: 30, height: 26)
                            .background(Capsule().fill(Brand.chipFill))
                    }
                    .buttonStyle(.plain)
                    .help(tool.title)
                }
            }
            .frame(maxWidth: .infinity)
            HStack(spacing: 12) {
                iconButton("clock.arrow.circlepath") { openHistory() }
                iconButton("gearshape") { openSettings() }
                Spacer()
                Button(NSLocalizedString("Open Burrow", comment: "")) { open(.home) }
                    .buttonStyle(.plain)
                    .font(Brand.sans(11, .semibold)).foregroundStyle(Brand.textPrimary)
                iconButton("power") { NSApp.terminate(nil) }
            }
            // `verbatim:` so the port isn't localized into "9,277".
            Text(verbatim: Store.queryServerEnabled
                 ? "MCP · 127.0.0.1:\(Store.queryServerPort) + stdio"
                 : "MCP · stdio (burrow --mcp)")
                .font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Brand.textSecondary)
        }.buttonStyle(.plain)
    }

    private func open(_ pane: Pane) {
        if #available(macOS 14, *) { delegate?.openMainWindow(initial: pane) }
    }
    private func openSettings() { open(.settings) }
    private func openHistory() { open(.home) }   // History lives in Home now
}

// MARK: - Compact tile

private struct HUDTile: View {
    let eyebrow: String
    let glyph: String
    let accent: Color
    let value: String
    var unit: String = ""
    let values: [Double]
    var style: MiniChart.Style = .area
    var foot: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Eyebrow(text: eyebrow, glyph: glyph, color: accent)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(Brand.mono(15, .semibold)).foregroundStyle(Brand.textPrimary)
                if !unit.isEmpty { Text(unit).font(Brand.mono(9)).foregroundStyle(Brand.textSecondary) }
            }
            MiniChart(values: values, color: accent, style: style).frame(height: 13)
            if let f = foot {
                Text(f).font(Brand.mono(8.5)).foregroundStyle(Brand.textTertiary).lineLimit(1)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Brand.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Brand.hairline, lineWidth: 1))
    }
}

// MARK: - Disk + Battery rows

private struct DiskBatteryRows: View {
    let s: MoleStatus

    var body: some View {
        HStack(spacing: 8) {
            if let disk = s.disks.first {
                bar(eyebrow: "Disk", glyph: "internaldrive", accent: disk.usedPercent >= 90 ? Brand.red : Brand.blue,
                    value: Fmt.gb((Double(disk.total) - Double(disk.used)) / 1_073_741_824) + " GB",
                    detail: String(format: NSLocalizedString("%.0f%% used", comment: ""), disk.usedPercent),
                    fraction: disk.usedPercent / 100,
                    barColor: disk.usedPercent >= 90 ? Brand.red : Brand.blue)
            }
            if let b = s.batteries?.first {
                bar(eyebrow: "Battery", glyph: "battery.100",
                    accent: b.percent <= 20 ? Brand.red : Brand.green,
                    value: String(format: "%.0f%%", b.percent),
                    detail: b.status == "charging"
                        ? NSLocalizedString("charging", comment: "")
                        : String(format: NSLocalizedString("%@ left", comment: ""), b.timeLeft),
                    fraction: b.percent / 100,
                    barColor: b.percent <= 20 ? Brand.red : Brand.green)
            }
        }
    }

    private func bar(eyebrow: String, glyph: String, accent: Color,
                     value: String, detail: String, fraction: Double, barColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Eyebrow(text: eyebrow, glyph: glyph, color: accent)
                Spacer()
                Text(detail).font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
            }
            Text(value).font(Brand.mono(13, .semibold)).foregroundStyle(Brand.textPrimary)
            ProgressBar(fraction: fraction, color: barColor)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Brand.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Brand.hairline, lineWidth: 1))
    }
}

// MARK: - Shared health rating (also used by Status)

enum HealthRating {
    static func label(_ score: Int) -> String {
        switch score {
        case 90...:   return NSLocalizedString("Excellent", comment: "")
        case 75..<90: return NSLocalizedString("Good", comment: "")
        case 60..<75: return NSLocalizedString("Fair", comment: "")
        case 40..<60: return NSLocalizedString("Poor", comment: "")
        default:      return NSLocalizedString("Critical", comment: "")
        }
    }
    static func color(_ score: Int) -> Color {
        switch score {
        case 75...:   return Brand.green
        case 60..<75: return Brand.gold
        case 40..<60: return Brand.orange
        default:      return Brand.red
        }
    }
}

// MARK: - Model (same data path as StatusModel, lighter)

@MainActor
final class HUDModel: ObservableObject {
    @Published var snap: MoleStatus?
    @Published var freshness = "—"
    @Published var cpuHist: [Double] = []
    @Published var memHist: [Double] = []
    @Published var netHist: [Double] = []
    @Published var gpuHist: [Double] = []

    private let db: DB
    private let sampler: Sampler
    private var liveTimer: Timer?
    private var histTimer: Timer?

    init(db: DB, sampler: Sampler) {
        self.db = db
        self.sampler = sampler
    }

    func start() {
        refreshCurrent()
        refreshHistory()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCurrent() }
        }
        histTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshHistory() }
        }
    }

    func stop() {
        liveTimer?.invalidate(); liveTimer = nil
        histTimer?.invalidate(); histTimer = nil
    }

    private func refreshCurrent() {
        snap = sampler.lastSnapshot
        if let when = sampler.lastSampleAt {
            freshness = String(format: NSLocalizedString("%ds ago", comment: ""), Int(Date().timeIntervalSince(when)))
        } else {
            freshness = NSLocalizedString("no samples yet", comment: "")
        }
    }

    private func refreshHistory() {
        let now = Int(Date().timeIntervalSince1970)
        var cpu: [Double] = [], mem: [Double] = [], net: [Double] = [], gpu: [Double] = []
        for stored in SnapshotStore.range(db, since: now - 30 * 60, until: now, maxPoints: 30) {
            let s = stored.status
            cpu.append(s.cpu.usage)
            mem.append(s.memory.usedPercent)
            net.append(s.network.reduce(0.0) { $0 + $1.rxRateMbs + $1.txRateMbs })
            gpu.append(max(0, s.gpu?.first?.usage ?? 0))
        }
        cpuHist = cpu; memHist = mem; netHist = net; gpuHist = gpu
    }
}
