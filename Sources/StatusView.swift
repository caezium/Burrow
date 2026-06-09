//
//  StatusView.swift
//  Burrow
//
//  The Status dashboard — Burrow's faithful take on mole.fit's Status
//  ("Sun") screen, built on the data the existing Sampler already
//  writes (`mo status --json` → SQLite). Two rows of glass metric cards
//  (Health / CPU / Memory / GPU, then Disk / Network / Battery) over a
//  sortable, pinnable process table.
//
//  Live values come from `Sampler.lastSnapshot` (in-memory, refreshed
//  each tick); the sparklines pull ~30 min of history from the DB.
//

import SwiftUI
import AppKit

/// The Overview section of Home: live metric cards + the process table.
struct StatusView: View {
    @StateObject private var model: StatusModel
    @ObservedObject private var io = IOMonitor.shared

    init(db: DB, sampler: Sampler) {
        _model = StateObject(wrappedValue: StatusModel(db: db, sampler: sampler))
    }

    private let row1H: CGFloat = 150
    private let row2H: CGFloat = 126

    var body: some View {
        ScrollView {
            VStack(spacing: 13) {
                if let s = model.snap {
                    HStack(spacing: 13) {
                        HealthCard(s: s, minHeight: row1H)
                        cpuTile(s).frame(minHeight: row1H)
                        memTile(s).frame(minHeight: row1H)
                        gpuTile(s).frame(minHeight: row1H)
                    }
                    HStack(spacing: 13) {
                        DiskCard(s: s, liveRead: io.readMBs, liveWrite: io.writeMBs, minHeight: row2H)
                        netTile(s).frame(minHeight: row2H)
                        BatteryCard(s: s, minHeight: row2H)
                    }
                    if let bt = s.bluetooth?.filter({ $0.connected }), !bt.isEmpty {
                        BluetoothStrip(devices: bt)
                    }
                    ProcessCard(model: model)
                } else {
                    waiting
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 22)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var waiting: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 120)
            ProgressView().controlSize(.large)
            Text("Waiting for the first sample…")
                .font(Brand.mono(12)).foregroundStyle(Brand.textSecondary)
            Text("Burrow runs `mo status --json` on a timer; the first row lands within a tick.")
                .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Tiles built from the snapshot

    private func cpuTile(_ s: MoleStatus) -> MetricTile {
        let chip: (String, Color)
        if let temp = s.thermal?.bestTemp {
            chip = (String(format: "%.0f°C", temp), Brand.orange)
        } else {
            chip = (String(format: NSLocalizedString("%d cores", comment: ""), s.cpu.coreCount), Brand.textSecondary)
        }
        return MetricTile(
            eyebrow: "CPU", glyph: "cpu", accent: Brand.green,
            value: String(format: "%.1f", s.cpu.usage), unit: "%",
            chip: chip, values: model.cpuHist, chartStyle: .bars,
            footnote: String(format: NSLocalizedString("load %.2f · %.2f · %.2f", comment: ""), s.cpu.load1, s.cpu.load5, s.cpu.load15))
    }

    private func memTile(_ s: MoleStatus) -> MetricTile {
        let m = s.memory
        let label = m.pressure.isEmpty ? "normal" : m.pressure.lowercased()
        let color: Color = label == "normal" ? Brand.textSecondary : (label == "warning" ? Brand.orange : Brand.red)
        let used = Double(m.used) / 1_073_741_824
        let total = Double(m.total) / 1_073_741_824
        return MetricTile(
            eyebrow: "Memory", glyph: "memorychip", accent: Brand.amber,
            value: String(format: "%.0f", m.usedPercent), unit: "%",
            chip: (label, color), values: model.memHist, chartStyle: .area,
            footnote: String(format: NSLocalizedString("%.1f / %.1f GB · swap %.1f GB", comment: ""),
                             used, total, Double(m.swapUsed) / 1_073_741_824))
    }

    private func gpuTile(_ s: MoleStatus) -> MetricTile {
        let g = s.gpu?.first
        let hasUsage = (g?.usage ?? -1) >= 0
        let name = (g?.name ?? s.hardware.cpuModel).replacingOccurrences(of: "Apple ", with: "")
        let cores = (g?.coreCount ?? 0)
        return MetricTile(
            eyebrow: "GPU", glyph: "cpu.fill", accent: Brand.orange,
            value: hasUsage ? String(format: "%.0f", g!.usage) : "—",
            unit: hasUsage ? "%" : "",
            chip: nil, values: model.gpuHist, chartStyle: .area,
            footnote: cores > 0 ? "\(name) · \(cores) cores" : name)
    }

    private func netTile(_ s: MoleStatus) -> MetricTile {
        let snapNet = s.network.first(where: { !$0.ip.isEmpty }) ?? s.network.first
        // Prefer the native 1 s monitor (catches bursts the mo poll misses); the
        // mo snapshot is the fallback before the monitor has any samples.
        let useLive = !io.samples.isEmpty
        let rx = useLive ? io.rxMBs : (snapNet?.rxRateMbs ?? 0)
        let tx = useLive ? io.txMBs : (snapNet?.txRateMbs ?? 0)
        let total = rx + tx
        let value: String
        let unit: String
        if total < 1 { value = String(format: "%.0f", total * 1024); unit = "KB/s" }
        else { value = String(format: "%.2f", total); unit = "MB/s" }
        var chip: (String, Color)? = nil
        if let p = s.proxy, p.enabled, !p.type.isEmpty { chip = (p.type, Brand.blue) }
        return MetricTile(
            eyebrow: "Network", glyph: "network", accent: Brand.green,
            value: value, unit: unit, chip: chip,
            values: useLive ? io.netHistory : model.netHist, chartStyle: .area,
            footnote: "↓ \(rate(rx))  ↑ \(rate(tx)) · \(snapNet?.name ?? "—") · \(snapNet?.ip ?? "—")")
    }

    private func rate(_ mbs: Double) -> String {
        mbs < 1 ? "\(Int(mbs * 1024)) KB/s" : String(format: "%.1f MB/s", mbs)
    }
}

// MARK: - Metric tile

struct MetricTile: View {
    let eyebrow: String
    let glyph: String
    let accent: Color
    let value: String
    var unit: String = ""
    var chip: (String, Color)? = nil
    let values: [Double]
    var chartStyle: MiniChart.Style = .area
    var footnote: String? = nil
    var minHeight: CGFloat? = nil

    var body: some View {
        GlassCard(minHeight: minHeight) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Eyebrow(text: eyebrow, glyph: glyph, color: accent)
                    Spacer(minLength: 4)
                    if let c = chip { Chip(text: c.0, color: c.1) }
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value).font(Brand.mono(26, .semibold)).foregroundStyle(Brand.textPrimary)
                    if !unit.isEmpty {
                        Text(unit).font(Brand.mono(12)).foregroundStyle(Brand.textSecondary)
                    }
                }
                MiniChart(values: values, color: accent, style: chartStyle)
                    .frame(height: 30)
                Spacer(minLength: 2)
                if let f = footnote {
                    Text(f).font(Brand.mono(10)).foregroundStyle(Brand.textTertiary).lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Health

struct HealthCard: View {
    let s: MoleStatus
    var minHeight: CGFloat? = nil

    var body: some View {
        GlassCard(minHeight: minHeight) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Eyebrow(text: "Health", glyph: "checkmark.seal.fill", color: Brand.gold)
                    Spacer(minLength: 4)
                    Text(specLine).font(Brand.mono(9)).foregroundStyle(Brand.textTertiary).lineLimit(1)
                }
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(s.healthScore)").font(Brand.mono(30, .semibold)).foregroundStyle(Brand.textPrimary)
                            Text(rating).font(Brand.sans(12, .medium)).foregroundStyle(ratingColor)
                        }
                        Text(message).font(Brand.sans(11)).foregroundStyle(Brand.textSecondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    HealthRing(score: s.healthScore, color: ratingColor)
                }
                Spacer(minLength: 2)
                Text(uptimeLine).font(Brand.mono(10)).foregroundStyle(Brand.textTertiary).lineLimit(1)
            }
        }
    }

    private var specLine: String {
        let cpu = s.hardware.cpuModel.replacingOccurrences(of: "Apple ", with: "")
        return "\(cpu) · \(s.hardware.totalRam)"
    }
    private var rating: String { HealthRating.label(s.healthScore) }
    private var ratingColor: Color { HealthRating.color(s.healthScore) }
    private var message: String {
        let m = s.healthScoreMsg
        if let r = m.range(of: ": ") { return String(m[r.upperBound...]) }
        return m.isEmpty ? NSLocalizedString("All checks passed", comment: "") : m
    }
    private var uptimeLine: String {
        let boot = Date().addingTimeInterval(-Double(s.uptimeSeconds))
        return String(format: NSLocalizedString("up %@ · since %@", comment: ""),
                      Fmt.uptime(s.uptimeSeconds), Fmt.day(boot))
    }
}

struct HealthRing: View {
    let score: Int
    let color: Color
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.10), lineWidth: 6)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(score, 100))) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(score)").font(Brand.mono(14, .semibold)).foregroundStyle(Brand.textPrimary)
        }
        .frame(width: 56, height: 56)
    }
}

// MARK: - Disk

struct DiskCard: View {
    let s: MoleStatus
    /// Live 1 s disk throughput from IOMonitor; falls back to the mo snapshot.
    var liveRead: Double? = nil
    var liveWrite: Double? = nil
    var minHeight: CGFloat? = nil

    var body: some View {
        let disk = s.disks.first
        let totalB = Double(disk?.total ?? 0)
        let usedB = Double(disk?.used ?? 0)
        let freeGB = (totalB - usedB) / 1_073_741_824
        let pct = disk?.usedPercent ?? 0
        let barColor: Color = pct >= 90 ? Brand.red : Brand.blue
        return GlassCard(minHeight: minHeight) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Eyebrow(text: "Disk", glyph: "internaldrive", color: Brand.blue)
                    Spacer()
                    Chip(text: s.hardware.diskSize, color: Brand.textSecondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Fmt.gb(freeGB)).font(Brand.mono(26, .semibold)).foregroundStyle(Brand.textPrimary)
                    Text("GB free").font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                }
                ProgressBar(fraction: pct / 100, color: barColor)
                Spacer(minLength: 2)
                Text(String(format: NSLocalizedString("%.0f%% used · R %.0f · W %.0f MB/s", comment: ""),
                            pct, liveRead ?? s.diskIO.readRate, liveWrite ?? s.diskIO.writeRate))
                    .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary).lineLimit(1)
            }
        }
    }
}

// MARK: - Battery

struct BatteryCard: View {
    let s: MoleStatus
    var minHeight: CGFloat? = nil

    var body: some View {
        GlassCard(minHeight: minHeight) {
            if let b = s.batteries?.first {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Eyebrow(text: "Battery", glyph: "battery.100", color: color(b))
                        Spacer()
                        Chip(text: b.health, color: b.health == "Good" ? Brand.green : Brand.gold)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(format: "%.0f", b.percent)).font(Brand.mono(26, .semibold)).foregroundStyle(Brand.textPrimary)
                        Text("%").font(Brand.mono(12)).foregroundStyle(Brand.textSecondary)
                    Text(NSLocalizedString(b.status, comment: "")).font(Brand.sans(11)).foregroundStyle(Brand.textTertiary).padding(.leading, 4)
                    }
                    ProgressBar(fraction: b.percent / 100, color: color(b))
                    Spacer(minLength: 2)
                    Text(String(format: NSLocalizedString("%@ left · %d cyc · %d%% cap", comment: ""),
                                b.timeLeft, b.cycleCount, b.capacity))
                        .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary).lineLimit(1)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow(text: "Power", glyph: "powerplug", color: Brand.green)
                    Spacer()
                    Text("AC Power").font(Brand.mono(20, .semibold)).foregroundStyle(Brand.textPrimary)
                    Spacer()
                }
            }
        }
    }

    private func color(_ b: BatteryStatus) -> Color {
        if b.percent <= 20 { return Brand.red }
        return b.status == "charging" ? Brand.green : Brand.gold
    }
}

struct ProgressBar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Brand.trackFill)
                Capsule().fill(color)
                    .frame(width: g.size.width * CGFloat(max(0, min(fraction, 1))))
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Bluetooth

/// Connected Bluetooth devices with their battery — surfaced from mo's
/// `bluetooth` array (AirPods, mouse, keyboard, controller, …).
struct BluetoothStrip: View {
    let devices: [BluetoothDevice]

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: "Bluetooth", glyph: "dot.radiowaves.right", color: Brand.blue)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(devices.enumerated()), id: \.offset) { _, d in chip(d) }
                    }
                }
            }
        }
    }

    private func chip(_ d: BluetoothDevice) -> some View {
        HStack(spacing: 6) {
            Image(systemName: Self.glyph(d.name)).font(.system(size: 12)).foregroundStyle(Brand.textSecondary)
            Text(d.name).font(Brand.sans(12)).foregroundStyle(Brand.textPrimary).lineLimit(1)
            if let p = d.batteryPercent {
                Text("\(p)%").font(Brand.mono(11, .semibold))
                    .foregroundStyle(p <= 20 ? Brand.red : (p <= 40 ? Brand.gold : Brand.green))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.05)))
        .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 1))
    }

    private static func glyph(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpod") || n.contains("headphone") || n.contains("buds") || n.contains("momentum") || n.contains("wh-") { return "headphones" }
        if n.contains("mouse") { return "magicmouse" }
        if n.contains("keyboard") || n.contains("keychron") { return "keyboard" }
        if n.contains("controller") || n.contains("dualsense") || n.contains("xbox") { return "gamecontroller" }
        if n.contains("trackpad") { return "trackpad" }
        return "dot.radiowaves.right"
    }
}

// MARK: - Process table

enum ProcSort { case name, cpu, mem, pid }

struct ProcessCard: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        let rows = model.sortedProcesses()
        return GlassCard(padding: 0) {
            VStack(spacing: 0) {
                header(count: rows.count)
                Rectangle().fill(Brand.hairline).frame(height: 1)
                ForEach(rows, id: \.pid) { p in
                    ProcRow(p: p, pinned: model.pinned.contains(p.pid)) {
                        model.togglePin(p.pid)
                    }
                }
            }
        }
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 10) {
            sortButton(String(format: NSLocalizedString("NAME (%d)", comment: ""), count), .name)
            Spacer(minLength: 8)
            sortButton("PID", .pid).frame(width: 54, alignment: .trailing)
            sortButton("CPU", .cpu).frame(width: 92, alignment: .trailing)
            sortButton("MEM", .mem).frame(width: 54, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func sortButton(_ title: String, _ key: ProcSort) -> some View {
        Button { model.setSort(key) } label: {
            HStack(spacing: 3) {
                Text(NSLocalizedString(title, comment: "")).font(Brand.mono(10, .bold)).tracking(0.6)
                if model.sortKey == key {
                    Image(systemName: model.sortAsc ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
            }
            .foregroundStyle(model.sortKey == key ? Brand.textSecondary : Brand.textTertiary)
        }
        .buttonStyle(.plain)
    }
}

struct ProcRow: View {
    let p: ProcessInfo
    let pinned: Bool
    let onPin: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1)
                .fill(pinned ? Brand.gold : Color.clear)
                .frame(width: 2, height: 18)
            AppIconView(proc: p).frame(width: 18, height: 18)
            Text(p.name).font(Brand.sans(12)).foregroundStyle(Brand.textPrimary).lineLimit(1)
            Spacer(minLength: 8)
            Text("\(p.pid)").font(Brand.mono(11)).foregroundStyle(Brand.textTertiary)
                .frame(width: 54, alignment: .trailing)
            HStack(spacing: 6) {
                cpuBar
                Text(String(format: "%.1f", p.cpu)).font(Brand.mono(11)).foregroundStyle(cpuColor)
                    .frame(width: 38, alignment: .trailing)
            }
            .frame(width: 92, alignment: .trailing)
            Text(String(format: "%.1f%%", p.memory)).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                .frame(width: 54, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(hover ? Brand.cardFillHover : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { onPin() }
    }

    private var cpuBar: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Brand.trackFill).frame(width: 44, height: 4)
            Capsule().fill(cpuColor).frame(width: 44 * CGFloat(min(p.cpu, 100) / 100), height: 4)
        }
    }
    private var cpuColor: Color {
        if p.cpu > 50 { return Brand.orange }
        if p.cpu > 20 { return Brand.gold }
        return Brand.green
    }
}

struct AppIconView: View {
    let proc: ProcessInfo
    var body: some View {
        if let img = AppIcon.image(for: proc) {
            Image(nsImage: img).resizable().interpolation(.high)
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(Image(systemName: "terminal").font(.system(size: 9)).foregroundStyle(Brand.textTertiary))
        }
    }
}

/// Best-effort process → app icon. Only GUI apps (NSWorkspace running
/// apps) resolve; daemons fall back to a glyph. Cached by name.
enum AppIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(for proc: ProcessInfo) -> NSImage? {
        if let c = cache[proc.name] { return c }
        for app in NSWorkspace.shared.runningApplications {
            let exe = app.executableURL?.lastPathComponent
            if app.localizedName == proc.name || exe == proc.name || exe == proc.command {
                if let icon = app.icon {
                    cache[proc.name] = icon
                    return icon
                }
            }
        }
        return nil
    }
}

// MARK: - Formatting

enum Fmt {
    static func gb(_ v: Double) -> String {
        v < 10 ? String(format: "%.2f", v) : String(format: "%.0f", v)
    }
    static func bytes(_ b: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(b); var i = 0
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        let s = (i == 0) ? "\(Int(v))" : String(format: v < 10 ? "%.2f" : "%.1f", v)
        return "\(s) \(units[i])"
    }
    static func uptime(_ secs: UInt64) -> String {
        let d = secs / 86_400, h = (secs % 86_400) / 3_600, m = (secs % 3_600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()
    static func day(_ date: Date) -> String { dayFmt.string(from: date) }
}

// MARK: - Model

@MainActor
final class StatusModel: ObservableObject {
    @Published var snap: MoleStatus?
    @Published var cpuHist: [Double] = []
    @Published var memHist: [Double] = []
    @Published var gpuHist: [Double] = []
    @Published var netHist: [Double] = []
    @Published var sortKey: ProcSort = .cpu
    @Published var sortAsc = false
    @Published var pinned: Set<Int> = []

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
        liveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCurrent() }
        }
        histTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshHistory() }
        }
    }

    func stop() {
        liveTimer?.invalidate(); liveTimer = nil
        histTimer?.invalidate(); histTimer = nil
    }

    func setSort(_ key: ProcSort) {
        if sortKey == key { sortAsc.toggle() }
        else { sortKey = key; sortAsc = (key == .name) }
    }

    func togglePin(_ pid: Int) {
        if pinned.contains(pid) { pinned.remove(pid) } else { pinned.insert(pid) }
    }

    func sortedProcesses() -> [ProcessInfo] {
        let procs = snap?.topProcesses ?? []
        let sorted = procs.sorted { a, b in
            switch sortKey {
            case .name: return sortAsc ? a.name < b.name : a.name > b.name
            case .cpu:  return sortAsc ? a.cpu < b.cpu : a.cpu > b.cpu
            case .mem:  return sortAsc ? a.memory < b.memory : a.memory > b.memory
            case .pid:  return sortAsc ? a.pid < b.pid : a.pid > b.pid
            }
        }
        let pin = sorted.filter { pinned.contains($0.pid) }
        let rest = sorted.filter { !pinned.contains($0.pid) }
        return pin + rest
    }

    private func refreshCurrent() {
        snap = sampler.lastSnapshot
    }

    private func refreshHistory() {
        let now = Int(Date().timeIntervalSince1970)
        let since = now - 30 * 60
        var cpu: [Double] = [], mem: [Double] = [], gpu: [Double] = [], net: [Double] = []
        for stored in SnapshotStore.range(db, since: since, until: now, maxPoints: 40) {
            let s = stored.status
            cpu.append(s.cpu.usage)
            mem.append(s.memory.usedPercent)
            gpu.append(max(0, s.gpu?.first?.usage ?? 0))
            let rx = s.network.reduce(0.0) { $0 + $1.rxRateMbs }
            let tx = s.network.reduce(0.0) { $0 + $1.txRateMbs }
            net.append(rx + tx)
        }
        cpuHist = cpu; memHist = mem; gpuHist = gpu; netHist = net
    }
}
