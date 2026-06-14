//
//  PopupView.swift
//  Burrow
//
//  The menu-bar HUD (design 3.5) — dense single-glance layout on the
//  same data path as the Status tab: header (health + headline issue +
//  free space), hardware chips row, six metric tiles with corner chips,
//  the battery card with ring gauges + top drain, top processes with a
//  per-row menu, the utility strip (Stay Awake · Wipe · Eject), and the
//  Clean Watch lifetime footer. The popover stays owned by
//  StatusBarController; this is just the SwiftUI it hosts.
//

import SwiftUI
import AppKit

struct PopupView: View {
    @StateObject private var model: HUDModel
    @ObservedObject private var ops = OperationCenter.shared
    @ObservedObject private var awake = Awake.shared
    @ObservedObject private var cleanScreen = CleanScreen.shared
    private weak var delegate: AppDelegate?

    init(db: DB, live: LiveFeed, feeds: FeedHub, delegate: AppDelegate) {
        _model = StateObject(wrappedValue: HUDModel(db: db, live: live, feeds: feeds))
        self.delegate = delegate
    }

    var body: some View {
        // No ScrollView: the popover sizes to this content, so there's no
        // scrollbar (which, with "always show scrollbars", was eating width
        // and shifting everything left). Kept compact so it fits on screen.
        VStack(alignment: .leading, spacing: 9) {
            if let s = model.snap {
                header(s)
                chipsRow(s)
            } else {
                fallbackHeader
            }
            if ops.hasActivity { activitySection }   // running jobs up top, where they're seen
            if let s = model.snap {
                metricGrid(s)
                batteryCard(s)
                topProcesses(s)
            } else {
                waiting
            }
            utilityStrip
            Rectangle().fill(Brand.hairline).frame(height: 1)
            footer
        }
        .padding(13)
        .frame(width: 334)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.colorScheme, .dark)
        // Three task-scoped subscriptions replace the old 1 s + 20 s timer
        // pair (issue #53): the snapshot and sparkline pumps are shared with
        // the Status pane, and closing the popover cancels these tasks,
        // which detaches the pumps — nothing ticks behind a closed popover.
        .task { await model.subscribeSnapshot() }
        .task { await model.subscribeSparklines() }
        .task { await model.subscribeCleanWatch() }
    }

    // MARK: Header — health glyph + score + headline issue + free space

    private func header(_ s: MoleStatus) -> some View {
        Button { open(.home) } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 13)).foregroundStyle(HealthRating.color(s.healthScore))
                Text("\(s.healthScore)").font(Brand.mono(16, .semibold)).foregroundStyle(Brand.textPrimary)
                Text(headline(s)).font(Brand.sans(11)).foregroundStyle(Brand.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                if let disk = s.disks.first {
                    Text(String(format: NSLocalizedString("%@ free", comment: ""),
                                Fmt.bytes(Int64(disk.total) - Int64(disk.used))))
                        .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Brand.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("Open Burrow", comment: ""))
        .accessibilityLabel(String(format: NSLocalizedString("Health %d. Open Burrow.", comment: ""), s.healthScore))
    }

    private func headline(_ s: MoleStatus) -> String {
        let m = s.healthScoreMsg
        if let r = m.range(of: ": ") { return String(m[r.upperBound...]) }
        return m.isEmpty ? HealthRating.label(s.healthScore) : m
    }

    private var fallbackHeader: some View {
        HStack(spacing: 7) {
            BurrowMark().frame(width: 18, height: 18)
            Text("Burrow").font(Brand.sans(13, .semibold)).foregroundStyle(Brand.textPrimary)
            Spacer()
            Text(model.freshness).font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
        }
    }

    /// chip model · RAM · macOS version · uptime
    private func chipsRow(_ s: MoleStatus) -> some View {
        HStack(spacing: 5) {
            Chip(text: s.hardware.cpuModel.replacingOccurrences(of: "Apple ", with: ""), color: Brand.textSecondary)
            Chip(text: s.hardware.totalRam, color: Brand.textSecondary)
            if !s.hardware.osVersion.isEmpty {
                Chip(text: Fmt.macOSVersion(s.hardware.osVersion), color: Brand.textSecondary)
            }
            Chip(text: String(format: NSLocalizedString("up %@", comment: ""), Fmt.uptime(s.uptimeSeconds)),
                 color: Brand.textSecondary)
            Spacer()
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

    // MARK: Activity (cards for running / just-finished jobs)

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
                Text(Fmt.elapsed(from: op.startedAt, to: ctx.date))
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

    // MARK: Metric tiles — CPU · GPU · MEM · DISK · NET · FAN

    private func metricGrid(_ s: MoleStatus) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ValueTile(variant: .hud, eyebrow: "CPU", glyph: "cpu", accent: Brand.green,
                      value: String(format: "%.0f", s.cpu.usage), unit: "%",
                      chip: (s.thermal?.cpuTemp).flatMap { $0 > 0 ? (String(format: "%.0f°C", $0), Brand.orange) : nil },
                      values: model.cpuHist, chartStyle: .bars,
                      footnote: String(format: "load %.2f", s.cpu.load1))
            ValueTile(variant: .hud, eyebrow: "GPU", glyph: "cpu.fill", accent: Brand.orange,
                      value: gpuValue(s).0, unit: gpuValue(s).1,
                      chip: (s.thermal?.gpuTemp).flatMap { $0 > 0 ? (String(format: "%.0f°C", $0), Brand.orange) : nil },
                      values: model.gpuHist, chartStyle: .bars,
                      footnote: (s.gpu?.first?.name ?? "GPU").replacingOccurrences(of: "Apple ", with: ""))
            ValueTile(variant: .hud, eyebrow: "Memory", glyph: "memorychip", accent: Brand.amber,
                      value: String(format: "%.0f", s.memory.usedPercent), unit: "%",
                      chip: memChip(s),
                      values: model.memHist, chartStyle: .area,
                      footnote: String(format: "%.1f/%.0f GB · swap %.1f GB",
                                       Fmt.gib(s.memory.used), Fmt.gib(s.memory.total), Fmt.gib(s.memory.swapUsed)))
            diskTile(s)
            ValueTile(variant: .hud, eyebrow: "Network", glyph: "network", accent: Brand.green,
                      value: netValue(s).0, unit: netValue(s).1,
                      chip: (s.network.first(where: { !$0.ip.isEmpty })?.name).map { ($0, Brand.blue) },
                      values: model.netHist, chartStyle: .area,
                      footnote: netFoot(s))
            fanTile(s)
        }
    }

    /// DISK tile: total chip, free headline, used bar + line.
    private func diskTile(_ s: MoleStatus) -> some View {
        let disk = s.disks.first
        let freeBytes = Int64(disk?.total ?? 0) - Int64(disk?.used ?? 0)
        let pct = disk?.usedPercent ?? 0
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Eyebrow(text: "Disk", glyph: "internaldrive", color: Brand.blue)
                Spacer(minLength: 2)
                Chip(text: s.hardware.diskSize, color: Brand.textSecondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(Fmt.bytes(freeBytes)).font(Brand.mono(15, .semibold)).foregroundStyle(Brand.textPrimary)
                Text("free").font(Brand.mono(9)).foregroundStyle(Brand.textSecondary)
            }
            LowSpaceBar(fraction: pct / 100).frame(height: 4)
            Text(String(format: NSLocalizedString("%@ used · %.0f%%", comment: ""),
                        Fmt.bytes(Int64(disk?.used ?? 0)), pct))
                .font(Brand.mono(8.5)).foregroundStyle(Brand.textTertiary).lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Brand.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Brand.hairline, lineWidth: 1))
    }

    /// FAN tile — read-only v1 (same rule as Status: no placebo buttons,
    /// and the RPM sparkline only exists when fans were detected; an
    /// all-zero series means parked fans, which is real data).
    private func fanTile(_ s: MoleStatus) -> some View {
        let fanCount = s.thermal?.fanCount ?? 0
        let rpm = s.thermal?.fanSpeed ?? 0
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                // Neutral on purpose — see PowerAccent (Format.swift).
                Eyebrow(text: "Fan", glyph: "fan", color: PowerAccent.fan)
                Spacer(minLength: 2)
                if fanCount > 0 {
                    Chip(text: String(format: NSLocalizedString("%d fans", comment: ""), fanCount), color: Brand.textSecondary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(fanCount > 0 ? "\(rpm)" : "—").font(Brand.mono(15, .semibold)).foregroundStyle(Brand.textPrimary)
                if fanCount > 0 { Text("RPM").font(Brand.mono(9)).foregroundStyle(Brand.textSecondary) }
            }
            if fanCount > 0 {
                MiniChart(values: model.fanHist, color: PowerAccent.fan, style: .area).frame(height: 13)
            }
            Text(fanCount > 0 ? NSLocalizedString("macOS manages speed", comment: "")
                              : NSLocalizedString("No fan data", comment: ""))
                .font(Brand.mono(8.5)).foregroundStyle(Brand.textTertiary).lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Brand.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Brand.hairline, lineWidth: 1))
    }

    private func memChip(_ s: MoleStatus) -> (String, Color)? {
        let label = s.memory.pressure.isEmpty ? "" : s.memory.pressure.lowercased()
        guard !label.isEmpty else { return nil }
        let color: Color = label == "normal" ? Brand.textSecondary : (label == "warning" ? Brand.orange : Brand.red)
        return (label, color)
    }

    private func netValue(_ s: MoleStatus) -> (String, String) {
        let total = s.network.reduce(0.0) { $0 + $1.rxRateMbs + $1.txRateMbs }
        return Fmt.rateParts(total, mbDecimals: 1)
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

    // MARK: Battery card — rings + top drain

    @ViewBuilder
    private func batteryCard(_ s: MoleStatus) -> some View {
        if let b = s.batteries?.first {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    // Accent semantics live in PowerAccent (Format.swift):
                    // red = low, green = charging/full, amber = discharging.
                    Eyebrow(text: "Battery", glyph: "battery.100",
                            color: PowerAccent.battery(percent: b.percent, status: b.status))
                    Spacer()
                    Chip(text: String(format: NSLocalizedString("%d%% Health", comment: ""), b.capacity),
                         color: b.health == "Good" ? Brand.green : Brand.gold)
                }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(String(format: "%.0f%%", b.percent))
                                .font(Brand.mono(16, .semibold)).foregroundStyle(Brand.textPrimary)
                            if !b.timeLeft.isEmpty {
                                Text(b.timeLeft).font(Brand.mono(10)).foregroundStyle(Brand.textSecondary)
                            }
                        }
                        Text(batterySubline(b))
                            .font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        RingGauge(percent: b.percent,
                                  color: PowerAccent.battery(percent: b.percent, status: b.status),
                                  glyph: "laptopcomputer", label: NSLocalizedString("Mac", comment: ""), size: 34)
                        ForEach(Array(bluetoothWithBattery(s).prefix(3).enumerated()), id: \.offset) { _, device in
                            RingGauge(percent: Double(device.batteryPercent ?? 0),
                                      color: PowerAccent.level(device.batteryPercent ?? 0),
                                      glyph: BluetoothStrip.glyph(device.name),
                                      label: device.name, size: 34)
                        }
                    }
                }
                if let drain = model.topDrain {
                    HStack(spacing: 5) {
                        Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(Brand.gold)
                        Text(String(format: NSLocalizedString("Top drain — %@ · avg %.0f%% CPU over the last hour", comment: ""),
                                    drain.name, drain.avgCPU))
                            .font(Brand.mono(9)).foregroundStyle(Brand.textSecondary).lineLimit(1)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Brand.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Brand.hairline, lineWidth: 1))
        }
    }

    private func bluetoothWithBattery(_ s: MoleStatus) -> [BluetoothDevice] {
        (s.bluetooth ?? []).filter { $0.connected && $0.batteryPercent != nil }
    }

    private func batterySubline(_ b: BatteryStatus) -> String {
        var parts = [String(format: NSLocalizedString("%d cyc", comment: ""), b.cycleCount)]
        if let t = model.snap?.thermal?.batteryTemp, t > 0 { parts.append(String(format: "%.0f°C", t)) }
        return parts.joined(separator: " · ")
    }

    // MARK: Top processes (name · CPU · memory · menu)

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
                    Text(memText(p)).font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                        .frame(width: 52, alignment: .trailing)
                    procMenu(p)
                }
            }
        }
    }

    private func memText(_ p: ProcessInfo) -> String {
        if let bytes = p.memoryBytes, bytes > 0 { return Fmt.bytes(Int64(bytes)) }
        return String(format: "%.1f%%", p.memory)
    }

    private func procMenu(_ p: ProcessInfo) -> some View {
        Menu {
            Button(NSLocalizedString("Reveal in Finder", comment: "")) {
                if let path = ProcessActions.executablePath(pid: p.pid) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
            Button(NSLocalizedString("Copy name", comment: "")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(p.name, forType: .string)
            }
            if ProcessActions.isOwnProcess(pid: p.pid) {
                Divider()
                Button(NSLocalizedString("Quit…", comment: ""), role: .destructive) {
                    if ProcessActions.quit(pid: p.pid) == false { NSSound.beep() }
                }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 10)).foregroundStyle(Brand.textTertiary)
                .frame(width: 16, height: 16).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 16)
        .accessibilityLabel(String(format: NSLocalizedString("Actions for %@", comment: ""), p.name))
    }

    private static let blankIcon = NSImage(size: NSSize(width: 15, height: 15))

    // MARK: Utility strip — Stay Awake · Wipe · Eject

    private var utilityStrip: some View {
        HStack(spacing: 6) {
            utilityButton(glyph: "cup.and.saucer.fill",
                          label: NSLocalizedString("Stay Awake", comment: ""),
                          active: awake.isActive) {
                awake.isActive ? awake.stop() : awake.start(.untilOff)
            }
            // Armed like Stay Awake while the wipe overlay is up: accent
            // toggled and the label flips to the exit hint.
            utilityButton(glyph: "rectangle.inset.filled",
                          label: cleanScreen.isActive
                              ? NSLocalizedString("esc to exit", comment: "")
                              : NSLocalizedString("Wipe", comment: ""),
                          active: cleanScreen.isActive) {
                cleanScreen.toggle()
            }
            if model.hasExternalVolumes {
                utilityButton(glyph: "eject.fill",
                              label: NSLocalizedString("Eject", comment: ""),
                              active: false) {
                    model.ejectExternals()
                }
            }
            Spacer()
        }
    }

    private func utilityButton(glyph: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: glyph).font(.system(size: 10, weight: .medium))
                Text(label).font(Brand.mono(10, .medium))
            }
            .foregroundStyle(active ? Brand.gold : Brand.textSecondary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(active ? Brand.gold.opacity(0.16) : Brand.chipFill))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(active ? NSLocalizedString("on", comment: "") : "")
    }

    // MARK: Footer — Clean Watch + tool pills + MCP line

    private var footer: some View {
        VStack(spacing: 8) {
            // Clean Watch: lifetime aggregates from `mo history`. Hidden
            // when the engine has no history (older moles) — zeros would
            // read as "you never cleaned".
            if let totals = model.cleanWatch, !totals.isEmpty {
                HStack(spacing: 10) {
                    Eyebrow(text: "Clean Watch", glyph: "sparkles", color: Tool.clean.accent)
                    Spacer()
                    Text(String(format: NSLocalizedString("%@ cleaned · %d uninstalled · %d optimized", comment: ""),
                                Fmt.bytes(totals.cleanedBytes), totals.uninstalledApps, totals.optimizeRuns))
                        .font(Brand.mono(9)).foregroundStyle(Brand.textSecondary)
                }
            }
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

// MARK: - Model (same data path as StatusModel, lighter)

@MainActor
final class HUDModel: ObservableObject {
    @Published var snap: MoleStatus?
    @Published var freshness = "—"
    @Published var cpuHist: [Double] = []
    @Published var memHist: [Double] = []
    @Published var netHist: [Double] = []
    @Published var gpuHist: [Double] = []
    /// Fan RPM series — kept only for snapshots that reported fans
    /// (fanCount > 0); see the fan tile's rule.
    @Published var fanHist: [Double] = []
    /// Heaviest process by average CPU over the last hour of samples.
    @Published var topDrain: (name: String, avgCPU: Double)?
    /// Lifetime cleanup totals from `mo history`; nil = not loaded or
    /// engine has no history command.
    @Published var cleanWatch: CleanWatch.Totals?

    private let db: DB
    private let live: LiveFeed
    private let feeds: FeedHub

    init(db: DB, live: LiveFeed, feeds: FeedHub) {
        self.db = db
        self.live = live
        self.feeds = feeds
    }

    // MARK: Feed subscriptions (issue #53)
    //
    // No view-owned timers: each `subscribe…` parks on a shared, demand-
    // counted pump and applies its values until the surrounding task is
    // cancelled (the popover closing IS the unsubscribe). The snapshot and
    // sparkline pumps are the SAME instances the Status pane binds to — one
    // timer, one read, two observers — so the popover and Status stop
    // double-polling the moment both are on screen.

    /// Latest snapshot + freshness, off the 1 s `snapshot.live` pump.
    func subscribeSnapshot() async {
        for await v in feeds.liveSnapshot(live).subscribeValues() {
            snap = v.snap
            if let when = v.sampledAt {
                freshness = String(format: NSLocalizedString("%ds ago", comment: ""), Int(Date().timeIntervalSince(when)))
            } else {
                freshness = NSLocalizedString("no samples yet", comment: "")
            }
        }
    }

    /// Sparklines + top drain, off the 15 s `metrics.sparklines.30m` pump.
    func subscribeSparklines() async {
        for await v in feeds.metricSparklines(db: db).subscribeValues() {
            cpuHist = v.cpu; memHist = v.mem; netHist = v.net; gpuHist = v.gpu; fanHist = v.fan
            topDrain = v.topDrain
        }
    }

    /// Clean Watch lifetime totals, off the daily `history.cleanwatch`
    /// pump. `mo history` is a lifetime figure; the day cadence keeps the
    /// old once-a-day spawn behaviour, now demand-driven (it only runs
    /// while the popover is open) instead of a process-wide static cache.
    func subscribeCleanWatch() async {
        let feed = feeds.feed("history.cleanwatch", cadence: 86_400) {
            await Task.detached(priority: .utility) {
                CleanWatch.totals(from: MoleHistory.load())
            }.value
        }
        for await totals in feed.subscribeValues() {
            cleanWatch = totals
        }
    }

    // MARK: External volumes

    var hasExternalVolumes: Bool {
        snap?.disks.contains(where: \.external) ?? false
    }

    /// Eject every mounted external volume. Failures (file in use) come
    /// back as one summary line in the Activity section.
    func ejectExternals() {
        let mounts = snap?.disks.filter(\.external).map(\.mount) ?? []
        guard !mounts.isEmpty else { return }
        let opId = UUID()
        OperationCenter.shared.begin(opId, label: NSLocalizedString("Ejecting external volumes", comment: ""))
        DispatchQueue.global(qos: .userInitiated).async {
            var ejected = 0, failed = 0
            for mount in mounts {
                if NSWorkspace.shared.unmountAndEjectDevice(atPath: mount) { ejected += 1 } else { failed += 1 }
            }
            Task { @MainActor in
                OperationCenter.shared.end(opId, success: failed == 0,
                                           detail: String(format: NSLocalizedString("%d ejected · %d busy", comment: ""), ejected, failed))
            }
        }
    }

}
