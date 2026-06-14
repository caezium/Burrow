//
//  StatusView.swift
//  Burrow
//
//  The Status dashboard — Burrow's live-metrics ("Sun") screen, built
//  on the data the SnapshotProducer already writes (`mo status --json`
//  → SQLite). Two rows of glass metric cards (Health / CPU / Memory /
//  GPU, then Disk / Network / Battery) over a sortable, pinnable
//  process table.
//
//  Live values come from `LiveFeed.lastSnapshot` (in-memory, refreshed
//  each tick); the sparklines pull ~30 min of history from the DB.
//

import SwiftUI
import AppKit

/// The Overview section of Home: live metric cards + the process table.
struct StatusView: View {
    @StateObject private var model: StatusModel
    @ObservedObject private var io: LiveFeed

    init(db: DB, live: LiveFeed, feeds: FeedHub) {
        _model = StateObject(wrappedValue: StatusModel(db: db, live: live, feeds: feeds))
        self.io = live
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
                        fanTile(s).frame(minHeight: row2H)
                    }
                    // Battery card carries the ring gauges (Mac + connected
                    // Bluetooth devices) — the old standalone BT strip folded in.
                    BatteryCard(s: s, minHeight: row2H)
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
        // Three task-scoped subscriptions replace the old 2 s + 15 s timer
        // pair (issue #53). The snapshot and sparkline pumps are shared with
        // the popover HUD; the process pump is Status-only. Leaving Home or
        // closing the window unmounts this view, which cancels the tasks and
        // detaches the pumps — no polling off-screen.
        .task { await model.subscribeSnapshot() }
        .task { await model.subscribeSparklines() }
        .task { await model.subscribeProcesses() }
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

    private func cpuTile(_ s: MoleStatus) -> ValueTile {
        let chip: (String, Color)
        if let temp = s.thermal?.bestTemp {
            chip = (String(format: "%.0f°C", temp), Brand.orange)
        } else {
            chip = (String(format: NSLocalizedString("%d cores", comment: ""), s.cpu.coreCount), Brand.textSecondary)
        }
        return ValueTile(
            eyebrow: "CPU", glyph: "cpu", accent: Brand.green,
            value: String(format: "%.1f", s.cpu.usage), unit: "%",
            chip: chip, values: model.cpuHist, chartStyle: .bars,
            footnote: String(format: NSLocalizedString("load %.2f · %.2f · %.2f", comment: ""), s.cpu.load1, s.cpu.load5, s.cpu.load15))
    }

    private func memTile(_ s: MoleStatus) -> ValueTile {
        let m = s.memory
        let label = m.pressure.isEmpty ? "normal" : m.pressure.lowercased()
        let color: Color = label == "normal" ? Brand.textSecondary : (label == "warning" ? Brand.orange : Brand.red)
        let used = Fmt.gib(m.used)
        let total = Fmt.gib(m.total)
        return ValueTile(
            eyebrow: "Memory", glyph: "memorychip", accent: Brand.amber,
            value: String(format: "%.0f", m.usedPercent), unit: "%",
            chip: (label, color), values: model.memHist, chartStyle: .area,
            footnote: String(format: NSLocalizedString("%.1f / %.1f GB · swap %.1f GB", comment: ""),
                             used, total, Fmt.gib(m.swapUsed)))
    }

    private func gpuTile(_ s: MoleStatus) -> ValueTile {
        let g = s.gpu?.first
        let hasUsage = (g?.usage ?? -1) >= 0
        let name = (g?.name ?? s.hardware.cpuModel).replacingOccurrences(of: "Apple ", with: "")
        let cores = (g?.coreCount ?? 0)
        // Corner chip: GPU die temp when the SMC reports one (Intel /
        // some configs) — never invented on Apple Silicon.
        var chip: (String, Color)? = nil
        if let t = s.thermal?.gpuTemp, t > 0 { chip = (String(format: "%.0f°C", t), Brand.orange) }
        return ValueTile(
            eyebrow: "GPU", glyph: "cpu.fill", accent: Brand.orange,
            value: hasUsage ? String(format: "%.0f", g!.usage) : "—",
            unit: hasUsage ? "%" : "",
            chip: chip, values: model.gpuHist, chartStyle: .bars,
            footnote: cores > 0 ? "\(name) · \(cores) cores" : name)
    }

    /// FAN tile — v1 read-only (design 3.2): RPM + "macOS manages
    /// speed". Mode controls wait for the privileged helper; no disabled
    /// placebo buttons. fanCount 0 means mole couldn't read any fan
    /// (normal on Apple Silicon) → say "no fan data", not "idle" — and
    /// draw no graph. With fans present the RPM sparkline renders like
    /// the other tiles; an all-zero series (parked fans) is real data
    /// and shows as a flat baseline, never hidden.
    private func fanTile(_ s: MoleStatus) -> some View {
        let fanCount = s.thermal?.fanCount ?? 0
        let rpm = s.thermal?.fanSpeed ?? 0
        return GlassCard(minHeight: row2H) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    // Neutral on purpose — see PowerAccent (Format.swift).
                    Eyebrow(text: "Fan", glyph: "fan", color: PowerAccent.fan)
                    Spacer()
                    if fanCount > 0 {
                        Chip(text: String(format: NSLocalizedString("%d fans", comment: ""), fanCount),
                             color: Brand.textSecondary)
                    }
                }
                if fanCount > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(verbatim: "\(rpm)").font(Brand.mono(26, .semibold)).foregroundStyle(Brand.textPrimary)
                        Text("RPM").font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                        if rpm == 0 {
                            Text("Idle").font(Brand.sans(11)).foregroundStyle(Brand.textTertiary).padding(.leading, 4)
                        }
                    }
                    MiniChart(values: model.fanHist, color: PowerAccent.fan, style: .area)
                        .frame(height: 30)
                } else {
                    Text("—").font(Brand.mono(26, .semibold)).foregroundStyle(Brand.textTertiary)
                }
                Spacer(minLength: 2)
                Text(fanCount > 0 ? NSLocalizedString("macOS manages speed", comment: "")
                                  : NSLocalizedString("No fan data on this Mac", comment: ""))
                    .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary).lineLimit(1)
            }
        }
    }

    private func netTile(_ s: MoleStatus) -> ValueTile {
        let snapNet = s.network.first(where: { !$0.ip.isEmpty }) ?? s.network.first
        // Prefer the native 1 s monitor (catches bursts the mo poll misses); the
        // mo snapshot is the fallback before the monitor has any samples.
        let useLive = !io.samples.isEmpty
        let rx = useLive ? io.rxMBs : (snapNet?.rxRateMbs ?? 0)
        let tx = useLive ? io.txMBs : (snapNet?.txRateMbs ?? 0)
        let total = rx + tx
        let (value, unit) = Fmt.rateParts(total, mbDecimals: 2)
        var chip: (String, Color)? = nil
        if let p = s.proxy, p.enabled, !p.type.isEmpty { chip = (p.type, Brand.blue) }
        return ValueTile(
            eyebrow: "Network", glyph: "network", accent: Brand.green,
            value: value, unit: unit, chip: chip,
            // Tile sparkline = the recent 2 min of the 1 s ring; longer
            // windows live in the History tab (they flattened the tile).
            values: useLive ? io.netHistory(lastSeconds: 120) : model.netHist, chartStyle: .area,
            footnote: "↓ \(Fmt.rate(rx))  ↑ \(Fmt.rate(tx)) · \(snapNet?.name ?? "—") · \(snapNet?.ip ?? "—")")
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
        let osText = Fmt.macOSVersion(s.hardware.osVersion)
        let os = osText.isEmpty ? "" : " · \(osText)"
        return "\(cpu) · \(s.hardware.totalRam)\(os)"
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
    /// Live 1 s disk throughput from the LiveFeed; falls back to the mo snapshot.
    var liveRead: Double? = nil
    var liveWrite: Double? = nil
    var minHeight: CGFloat? = nil

    var body: some View {
        let disk = s.disks.first
        let totalB = Double(disk?.total ?? 0)
        let usedB = Double(disk?.used ?? 0)
        let freeGB = Fmt.gib(totalB - usedB)
        let pct = disk?.usedPercent ?? 0
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
                LowSpaceBar(fraction: pct / 100)
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
                        // Accent semantics live in PowerAccent (Format.swift):
                        // red = low, green = charging/full, amber = discharging.
                        Eyebrow(text: "Battery", glyph: "battery.100",
                                color: PowerAccent.battery(percent: b.percent, status: b.status))
                        Spacer()
                        Chip(text: String(format: NSLocalizedString("%d%% Health", comment: ""), b.capacity),
                             color: b.health == "Good" ? Brand.green : Brand.gold)
                    }
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(String(format: "%.0f", b.percent)).font(Brand.mono(26, .semibold)).foregroundStyle(Brand.textPrimary)
                                Text("%").font(Brand.mono(12)).foregroundStyle(Brand.textSecondary)
                                Text(NSLocalizedString(b.status, comment: "")).font(Brand.sans(11)).foregroundStyle(Brand.textTertiary).padding(.leading, 4)
                            }
                            Text(batteryFootnote(b))
                                .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        // Ring gauges: the Mac, then each connected
                        // Bluetooth device that reports a battery.
                        HStack(spacing: 10) {
                            RingGauge(percent: b.percent,
                                      color: PowerAccent.battery(percent: b.percent, status: b.status),
                                      glyph: "laptopcomputer", label: NSLocalizedString("Mac", comment: ""))
                            ForEach(Array(bluetoothWithBattery.prefix(4).enumerated()), id: \.offset) { _, device in
                                RingGauge(percent: Double(device.batteryPercent ?? 0),
                                          color: PowerAccent.level(device.batteryPercent ?? 0),
                                          glyph: BluetoothStrip.glyph(device.name),
                                          label: device.name)
                            }
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow(text: "Power", glyph: "powerplug", color: Brand.green)
                    Spacer()
                    HStack(spacing: 16) {
                        Text("AC Power").font(Brand.mono(20, .semibold)).foregroundStyle(Brand.textPrimary)
                        Spacer()
                        HStack(spacing: 10) {
                            ForEach(Array(bluetoothWithBattery.prefix(5).enumerated()), id: \.offset) { _, device in
                                RingGauge(percent: Double(device.batteryPercent ?? 0),
                                          color: PowerAccent.level(device.batteryPercent ?? 0),
                                          glyph: BluetoothStrip.glyph(device.name),
                                          label: device.name)
                            }
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    private var bluetoothWithBattery: [BluetoothDevice] {
        (s.bluetooth ?? []).filter { $0.connected && $0.batteryPercent != nil }
    }

    private func batteryFootnote(_ b: BatteryStatus) -> String {
        var parts: [String] = []
        if !b.timeLeft.isEmpty { parts.append(String(format: NSLocalizedString("%@ left", comment: ""), b.timeLeft)) }
        parts.append(String(format: NSLocalizedString("%d cyc", comment: ""), b.cycleCount))
        if let t = s.thermal?.batteryTemp, t > 0 { parts.append(String(format: "%.0f°C", t)) }
        return parts.joined(separator: " · ")
    }

    // (Accent rules live in PowerAccent — Format.swift — shared with the HUD.)
}

/// Small ring gauge — Mac battery + Bluetooth devices on the battery
/// card (3.2) and the popover (3.5).
struct RingGauge: View {
    let percent: Double
    let color: Color
    let glyph: String
    let label: String
    var size: CGFloat = 40

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.10), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: CGFloat(max(0, min(percent, 100))) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: glyph).font(.system(size: size * 0.3)).foregroundStyle(Brand.textSecondary)
            }
            .frame(width: size, height: size)
            Text(verbatim: "\(Int(percent))%").font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(String(format: NSLocalizedString("%d percent", comment: ""), Int(percent)))
    }
}

/// Disk usage bar whose fill shifts from calm blue through amber to red
/// as free space runs out (design 3.2).
struct LowSpaceBar: View {
    let fraction: Double   // used fraction 0…1

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Brand.trackFill)
                Capsule()
                    .fill(LinearGradient(colors: gradientColors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: g.size.width * CGFloat(max(0, min(fraction, 1))))
            }
        }
        .frame(height: 6)
    }

    private var gradientColors: [Color] {
        if fraction >= 0.9 { return [Brand.amber, Brand.red] }
        if fraction >= 0.75 { return [Brand.blue, Brand.amber] }
        return [Brand.blue, Brand.blue]
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
                    .foregroundStyle(PowerAccent.level(p))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.05)))
        .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 1))
    }

    static func glyph(_ name: String) -> String {
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

enum ProcSort { case name, cpu, mem, pid, pwr }

/// The process table: the FULL live process set (ProcessSampler/`ps`,
/// hundreds of rows — the engine snapshot only carries a top five),
/// sortable and pinnable, scrolling inside a bounded-height card.
struct ProcessCard: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        let rows = model.sortedProcesses()
        return GlassCard(padding: 0) {
            VStack(spacing: 0) {
                header(count: rows.count)
                Rectangle().fill(Brand.hairline).frame(height: 1)
                // The table scrolls on its own, under a sticky header,
                // independent of the page scroll (design 3.2). Kept compact
                // on purpose — ~6½ rows (each row is 30 pt: 18 pt content +
                // 2×6 pt padding) with the half row hinting there's more to
                // scroll, instead of one long box that dominates the page.
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows, id: \.pid) { p in
                            ProcRow(p: p,
                                    pinned: model.pinned.contains(p.pid),
                                    energy: model.energies[p.pid]) {
                                model.togglePin(p.pid)
                            }
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(height: 195)
            }
        }
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 10) {
            sortButton(String(format: NSLocalizedString("NAME (%d)", comment: ""), count), .name)
            Spacer(minLength: 8)
            sortButton("PID", .pid).frame(width: 54, alignment: .trailing)
            sortButton("CPU", .cpu).frame(width: 92, alignment: .trailing)
            sortButton("PWR", .pwr).frame(width: 44, alignment: .trailing)
            sortButton("MEM", .mem).frame(width: 64, alignment: .trailing)
            Color.clear.frame(width: 20)   // the … column
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
        .accessibilityLabel(String(format: NSLocalizedString("Sort by %@", comment: ""), title))
    }
}

struct ProcRow: View {
    let p: ProcessInfo
    let pinned: Bool
    /// Cumulative billed energy (nJ) — nil renders "—", never estimated.
    var energy: UInt64? = nil
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
            Text(ProcessActions.energyText(nanojoules: energy))
                .font(Brand.mono(11)).foregroundStyle(Brand.textTertiary)
                .frame(width: 44, alignment: .trailing)
                .help(NSLocalizedString("Energy billed since launch (mWh)", comment: ""))
            Text(memText).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                .frame(width: 64, alignment: .trailing)
            rowMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(hover ? Brand.cardFillHover : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { onPin() }
        .accessibilityElement(children: .combine)
    }

    /// Absolute MB when mole reports resident bytes; percent fallback.
    private var memText: String {
        if let bytes = p.memoryBytes, bytes > 0 {
            return Fmt.bytes(Int64(bytes))
        }
        return String(format: "%.1f%%", p.memory)
    }

    /// Per-row "…" menu: pin, reveal, copy; Quit / Force Kill for
    /// own-user processes only — root rows stay read-only.
    private var rowMenu: some View {
        Menu {
            Button(pinned ? NSLocalizedString("Unpin", comment: "") : NSLocalizedString("Pin", comment: "")) { onPin() }
            Button(NSLocalizedString("Reveal in Finder", comment: "")) {
                if let path = ProcessActions.executablePath(pid: p.pid) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
            Button(NSLocalizedString("Copy name", comment: "")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(p.name, forType: .string)
            }
            Button(NSLocalizedString("Copy PID", comment: "")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(p.pid)", forType: .string)
            }
            if ProcessActions.isOwnProcess(pid: p.pid) {
                Divider()
                Button(NSLocalizedString("Quit…", comment: ""), role: .destructive) { confirmQuit(force: false) }
                Button(NSLocalizedString("Force Kill…", comment: ""), role: .destructive) { confirmQuit(force: true) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11)).foregroundStyle(Brand.textTertiary)
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 20)
        .accessibilityLabel(String(format: NSLocalizedString("Actions for %@", comment: ""), p.name))
    }

    private func confirmQuit(force: Bool) {
        let alert = NSAlert()
        alert.messageText = force
            ? String(format: NSLocalizedString("Force kill %@?", comment: ""), p.name)
            : String(format: NSLocalizedString("Quit %@?", comment: ""), p.name)
        alert.informativeText = force
            ? NSLocalizedString("SIGKILL ends it immediately — unsaved work in this process is lost.", comment: "")
            : NSLocalizedString("Sends a polite quit (SIGTERM). The process may save and exit, or ignore it.", comment: "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: force ? NSLocalizedString("Force Kill", comment: "") : NSLocalizedString("Quit Process", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if force { ProcessActions.forceKill(pid: p.pid) } else { ProcessActions.quit(pid: p.pid) }
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
    /// Names that resolved to nothing. Daemons (most of the process table)
    /// never match a running GUI app — without remembering that, every
    /// 2 s refresh re-walks all running applications per daemon row.
    private static var misses: Set<String> = []

    static func image(for proc: ProcessInfo) -> NSImage? {
        if let c = cache[proc.name] { return c }
        if misses.contains(proc.name) { return nil }
        for app in NSWorkspace.shared.runningApplications {
            let exe = app.executableURL?.lastPathComponent
            if app.localizedName == proc.name || exe == proc.name || exe == proc.command {
                if let icon = app.icon {
                    cache[proc.name] = icon
                    return icon
                }
            }
        }
        // Bounded: a newly-launched app with a previously-missed name just
        // shows the glyph until the occasional reset re-resolves it.
        if misses.count > 512 { misses.removeAll() }
        misses.insert(proc.name)
        return nil
    }
}

// MARK: - Model

@MainActor
final class StatusModel: ObservableObject {
    @Published var snap: MoleStatus?
    @Published var cpuHist: [Double] = []
    @Published var memHist: [Double] = []
    @Published var gpuHist: [Double] = []
    @Published var netHist: [Double] = []
    /// Fan RPM series. Samples are kept only when that snapshot actually
    /// reported fans (fanCount > 0) — 0 RPM with fans present is real
    /// data (parked), no fans detected contributes nothing.
    @Published var fanHist: [Double] = []
    @Published var sortKey: ProcSort = .cpu
    @Published var sortAsc = false
    @Published var pinned: Set<Int> = []
    /// pid → cumulative billed energy (nJ), refreshed with the process list.
    @Published var energies: [Int: UInt64] = [:]
    /// The full live process list (ProcessSampler/`ps`), refreshed on the
    /// 2 s tick off-main. Empty until the first pass (or on spawn failure)
    /// — the table then falls back to the snapshot's engine top five.
    @Published var processes: [ProcessInfo] = []

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
    // counted pump until the surrounding task is cancelled (the view
    // unmounting — leaving Home or closing the window — IS the unsubscribe).
    // The snapshot and sparkline pumps are the SAME instances the popover
    // HUD binds to (one timer, one read, two observers), so Status and the
    // HUD stop double-polling the moment both are on screen. The full
    // process list is Status-only, so it gets its own pump.

    /// Latest snapshot, off the shared 1 s `snapshot.live` pump.
    func subscribeSnapshot() async {
        for await v in feeds.liveSnapshot(live).subscribeValues() {
            snap = v.snap
        }
    }

    /// Sparklines, off the shared 15 s `metrics.sparklines.30m` pump (the
    /// HUD reads the same pump for its tiles + top drain).
    func subscribeSparklines() async {
        for await v in feeds.metricSparklines(db: db).subscribeValues() {
            cpuHist = v.cpu; memHist = v.mem; gpuHist = v.gpu; netHist = v.net; fanHist = v.fan
        }
    }

    /// The full live process list + per-pid energy, off the 2 s
    /// `processes.full` pump. One `ps` pass + the PWR lookups, off the main
    /// thread (the spawn blocks ~10–30 ms), published together so a row and
    /// its energy always belong to the same pass. In-flight coalescing in
    /// the feed drops overlapping passes — the role the old
    /// `samplingProcesses` flag played.
    func subscribeProcesses() async {
        let live = self.live
        let feed = feeds.feed("processes.full", cadence: 2) {
            // The energy lookups need a row set even when `ps` returns
            // nothing (spawn failure): fall back to the snapshot's engine
            // top five so the PWR column still fills for those rows, exactly
            // as the old refreshProcesses did. (`lastSnapshot` is a
            // main-thread-confined published value — read it on the main
            // actor.)
            let fallback = await MainActor.run { live.lastSnapshot?.topProcesses ?? [] }
            return await Task.detached(priority: .userInitiated) {
                let sampled = ProcessSampler.sample()
                let rows = sampled.isEmpty ? fallback : sampled
                var energies: [Int: UInt64] = [:]
                for p in rows { energies[p.pid] = ProcessActions.energyNanojoules(pid: p.pid) }
                return ProcessSample(processes: sampled, energies: energies)
            }.value
        }
        for await v in feed.subscribeValues() {
            // Empty pass (spawn failure) keeps the table on the snapshot's
            // engine top five — sortedProcesses() falls back when empty.
            processes = v.processes
            energies = v.energies
        }
    }

    func setSort(_ key: ProcSort) {
        if sortKey == key { sortAsc.toggle() }
        else { sortKey = key; sortAsc = (key == .name) }
    }

    func togglePin(_ pid: Int) {
        if pinned.contains(pid) { pinned.remove(pid) } else { pinned.insert(pid) }
    }

    func sortedProcesses() -> [ProcessInfo] {
        let procs = processes.isEmpty ? (snap?.topProcesses ?? []) : processes
        let sorted = procs.sorted { a, b in
            switch sortKey {
            case .name: return sortAsc ? a.name < b.name : a.name > b.name
            case .cpu:  return sortAsc ? a.cpu < b.cpu : a.cpu > b.cpu
            case .mem:  return sortAsc ? a.memory < b.memory : a.memory > b.memory
            case .pid:  return sortAsc ? a.pid < b.pid : a.pid > b.pid
            case .pwr:
                let ea = energies[a.pid] ?? 0, eb = energies[b.pid] ?? 0
                return sortAsc ? ea < eb : ea > eb
            }
        }
        let pin = sorted.filter { pinned.contains($0.pid) }
        let rest = sorted.filter { !pinned.contains($0.pid) }
        return pin + rest
    }

}
