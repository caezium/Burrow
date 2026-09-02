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
    /// The 1 Hz live feed. Deliberately NOT `@ObservedObject` here: only the
    /// small Disk / Net cards observe it (`LiveDiskCard` / `LiveNetCard`), so a
    /// per-second rate/ring tick re-renders just those two tiles instead of the
    /// whole dashboard — every chart tile AND the 100-row process table — every
    /// second. That StatusView-wide 1 Hz invalidation was the App-Hang fan-out
    /// (BURROW-4x: layout/AttributeGraph churn, per-row Menus rebuilt at 1 Hz).
    private let live: LiveFeed

    init(db: DB, live: LiveFeed, feeds: FeedHub) {
        _model = StateObject(wrappedValue: StatusModel(db: db, live: live, feeds: feeds))
        self.live = live
    }

    private let row1H: CGFloat = 162
    private let row2H: CGFloat = 138

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let s = model.snap {
                    HealthHero(s: s)
                    Rectangle().fill(Brand.hairline).frame(height: 1).padding(.bottom, 2)
                    HStack(spacing: 16) {
                        cpuTile(s).frame(minHeight: row1H)
                        memTile(s).frame(minHeight: row1H)
                        gpuTile(s).frame(minHeight: row1H)
                    }
                    HStack(spacing: 16) {
                        LiveDiskCard(s: s, io: live, minHeight: row2H, db: model.db)
                        LiveNetCard(s: s, io: live, fallbackRx: model.netRxHist, fallbackTx: model.netTxHist)
                            .frame(minHeight: row2H)
                        fanTile(s).frame(minHeight: row2H)
                    }
                    memoryDetail(s)
                    // Battery card carries the ring gauges (Mac + connected
                    // Bluetooth devices) — the old standalone BT strip folded in.
                    BatteryCard(s: s, minHeight: row2H)
                    ProcessCard(model: model)
                } else {
                    waiting
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .fadeEdges()
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

    // MARK: - Memory detail (the full breakdown the small tile can't show)

    private func memoryDetail(_ s: MoleStatus) -> some View {
        let m = s.memory
        let lvl = MemoryPressure.percent()
        let free = m.available ?? (m.total > m.used ? m.total - m.used : 0)
        return HStack(alignment: .center, spacing: 22) {
            HStack(spacing: 6) {
                Image(systemName: "memorychip").font(.system(size: Brand.scaled(12))).foregroundStyle(MemoryPressure.tint(percent: lvl))
                Text(NSLocalizedString("Memory", comment: "")).font(Brand.mono(10, .semibold)).foregroundStyle(Brand.textSecondary)
            }
            memStat(NSLocalizedString("Used", comment: ""), String(format: "%.1f GB", Fmt.gib(m.used)), MemoryPressure.tint(percent: lvl))
            memStat(NSLocalizedString("Free", comment: ""), String(format: "%.1f GB", Fmt.gib(free)), Brand.textPrimary)
            if let c = m.cached, c > 0 {
                memStat(NSLocalizedString("Cached", comment: ""), String(format: "%.1f GB", Fmt.gib(c)), Brand.textPrimary)
            }
            memStat(NSLocalizedString("Swap", comment: ""),
                    String(format: "%.1f / %.0f GB", Fmt.gib(m.swapUsed), Fmt.gib(m.swapTotal)),
                    m.swapUsed > 0 ? MemoryPressure.tint(percent: lvl) : Brand.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.cardFill))
    }

    private func memStat(_ label: String, _ value: String, _ valueColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
            Text(value).font(Brand.mono(13, .semibold)).foregroundStyle(valueColor)
        }
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
        let lvl = MemoryPressure.percent()
        let used = Fmt.gib(m.used)
        let total = Fmt.gib(m.total)
        return ValueTile(
            eyebrow: "Memory", glyph: "memorychip", accent: MemoryPressure.tint(percent: lvl),
            value: String(format: "%.0f", m.usedPercent), unit: "%",
            chip: (String(format: NSLocalizedString("%d%%", comment: ""), lvl), MemoryPressure.tint(percent: lvl)),
            values: model.memHist, chartStyle: .area,
            footnote: String(format: NSLocalizedString("%.1f / %.1f GB · swap %.1f GB", comment: ""), used, total, Fmt.gib(m.swapUsed)))
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
                        Text(verbatim: "\(rpm)").font(Brand.mono(30, .semibold)).foregroundStyle(Brand.textPrimary)
                        Text("RPM").font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                        if rpm == 0 {
                            Text("Idle").font(Brand.sans(11)).foregroundStyle(Brand.textTertiary).padding(.leading, 4)
                        }
                    }
                    MiniChart(values: model.fanHist, color: PowerAccent.fan, style: .area)
                        .frame(height: 30)
                } else {
                    Text("—").font(Brand.mono(30, .semibold)).foregroundStyle(Brand.textTertiary)
                }
                Spacer(minLength: 2)
                Text(fanCount > 0 ? NSLocalizedString("macOS manages speed", comment: "")
                                  : NSLocalizedString("No fan data on this Mac", comment: ""))
                    .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary).lineLimit(1)
            }
        }
    }

}

/// Disk tile that observes the 1 Hz `LiveFeed` HERE (not in StatusView), so a
/// per-second throughput tick re-renders only this tile.
struct LiveDiskCard: View {
    let s: MoleStatus
    @ObservedObject var io: LiveFeed
    var minHeight: CGFloat? = nil
    var db: DB? = nil
    var body: some View {
        DiskCard(s: s, liveRead: io.readMBs, liveWrite: io.writeMBs, minHeight: minHeight, db: db)
    }
}

/// Network tile that observes the 1 Hz `LiveFeed` HERE, for the same reason —
/// the per-second rate/ring updates stay scoped to this tile rather than
/// invalidating the whole dashboard.
struct LiveNetCard: View {
    let s: MoleStatus
    @ObservedObject var io: LiveFeed
    /// Sparkline fallback for the first tick, before the 1 s ring has samples.
    var fallbackRx: [Double] = []
    var fallbackTx: [Double] = []

    var body: some View {
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
        // Two lines, one scale: download (green, ↓) and upload (blue, ↑) —
        // matching the ↓/↑ figures in the footnote. Tile window = the recent
        // 2 min of the 1 s ring; longer windows live in the History tab.
        let rxHist = useLive ? io.netRxHistory(lastSeconds: 120) : fallbackRx
        let txHist = useLive ? io.netTxHistory(lastSeconds: 120) : fallbackTx
        return ValueTile(
            eyebrow: "Network", glyph: "network", accent: Brand.green,
            value: value, unit: unit, chip: chip,
            values: [],
            dual: (down: rxHist, up: txHist, downColor: Brand.green, upColor: Brand.blue),
            footnote: "↓ \(Fmt.rate(rx))  ↑ \(Fmt.rate(tx)) · \(snapNet?.name ?? "—") · \(snapNet?.ip ?? "—")")
    }
}

// MARK: - Health

/// The Overview hero — Health, pulled out of the card grid into an open,
/// borderless band so the page reads as "focal summary + supporting metrics"
/// rather than a uniform grid of boxes. Big Cal Sans score, the ring, and the
/// machine spec / uptime on the right.
struct HealthHero: View {
    let s: MoleStatus

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            HealthRing(score: s.healthScore, color: ratingColor)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(s.healthScore)").font(Brand.display(44)).foregroundStyle(Brand.textPrimary)
                    Text(rating).font(Brand.sans(14, .medium)).foregroundStyle(ratingColor)
                }
                Text(message).font(Brand.sans(12)).foregroundStyle(Brand.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                Text(specLine).font(Brand.mono(10)).foregroundStyle(Brand.textTertiary).lineLimit(1)
                Text(uptimeLine).font(Brand.mono(10)).foregroundStyle(Brand.textTertiary).lineLimit(1)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .frame(maxWidth: .infinity)
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
            Circle().stroke(Brand.trackFill, lineWidth: 6)
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
    /// When set, annotate the tile with a disk-full forecast (A.3).
    var db: DB? = nil
    @State private var forecastText: String? = nil

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
                    Text(Fmt.gb(freeGB)).font(Brand.mono(30, .semibold)).foregroundStyle(Brand.textPrimary)
                    Text("GB free").font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                }
                LowSpaceBar(fraction: pct / 100)
                Spacer(minLength: 2)
                Text(String(format: NSLocalizedString("%.0f%% used · R %.0f · W %.0f MB/s", comment: ""),
                            pct, liveRead ?? s.diskIO.readRate, liveWrite ?? s.diskIO.writeRate))
                    .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary).lineLimit(1)
                if let f = forecastText {
                    Text(f).font(Brand.mono(10)).foregroundStyle(Brand.textSecondary).lineLimit(1)
                }
            }
        }
        .task { computeForecast() }
    }

    /// Annotate with a disk-full forecast over the last 30 days of free-space
    /// history (A.3). Silent unless the forecaster is willing to name a date.
    private func computeForecast() {
        guard let db else { return }
        let now = Int(Date().timeIntervalSince1970)
        let series = MetricsStore(db: db).diskFreeSeries(mount: nil, .init(since: now - 30 * 86_400, until: now))
        guard series.count >= 2, let days = DiskForecast.forecast(series, now: now).daysUntilFull else {
            forecastText = nil
            return
        }
        forecastText = String(format: NSLocalizedString("Full in ~%@", comment: ""), phrase(days))
    }

    private func phrase(_ days: Double) -> String {
        if days < 14 { return String(format: NSLocalizedString("%d days", comment: ""), Int(days.rounded())) }
        if days < 60 { return String(format: NSLocalizedString("%d weeks", comment: ""), Int((days / 7).rounded())) }
        return String(format: NSLocalizedString("%d months", comment: ""), Int((days / 30).rounded()))
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
                                Text(String(format: "%.0f", b.percent)).font(Brand.mono(30, .semibold)).foregroundStyle(Brand.textPrimary)
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
                Circle().stroke(Brand.trackFill, lineWidth: 4)
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
            Image(systemName: Self.glyph(d.name)).font(.system(size: Brand.scaled(12))).foregroundStyle(Brand.textSecondary)
            Text(d.name).font(Brand.sans(12)).foregroundStyle(Brand.textPrimary).lineLimit(1)
            if let p = d.batteryPercent {
                Text("\(p)%").font(Brand.mono(11, .semibold))
                    .foregroundStyle(PowerAccent.level(p))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Brand.chipFill))
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
    /// Cap the rows handed to `ForEach` by default. The table only shows
    /// ~6½ rows at a time, but `ForEach` still builds + diffs an identity for
    /// every element on each 2 s feed tick — over the full process set
    /// (hundreds) that drove a SwiftUI layout/diff hang on the main thread
    /// (Sentry BURROW-1). Showing the top `rowCap` by the current sort keeps
    /// that bounded; "Show all" opts back into the full list.
    private static let rowCap = 100
    @State private var showAll = false
    @State private var inspecting: ProcessInspectTarget?
    @State private var showTree = false

    var body: some View {
        let all = model.sortedRows
        let rows = showAll ? all : Array(all.prefix(Self.rowCap))
        let hidden = all.count - rows.count
        return GlassCard(padding: 0) {
            VStack(spacing: 0) {
                filterBar
                Rectangle().fill(Brand.hairline).frame(height: 1)
                header(count: all.count)
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
                                    energy: model.energies[p.pid],
                                    onInspect: { inspecting = ProcessInspectTarget(proc: p) },
                                    onTermination: { model.invalidateProcess($0) }) {
                                model.togglePin(p.pid)
                            }
                        }
                        if hidden > 0 { showAllRow(hidden: hidden) }
                    }
                    .overlayScrollers()
                }
                .scrollIndicators(.automatic)
                .frame(height: 195)
            }
        }
        .sheet(item: $inspecting) { target in
            ProcessInspectorView(proc: target.proc, processes: model.processes)
        }
        .sheet(isPresented: $showTree) {
            ProcessTreeView(processes: model.processes)
        }
    }

    /// Footer row that reveals the remaining processes (hidden by default to
    /// keep the `ForEach` identity set small — see `rowCap`).
    private func showAllRow(hidden: Int) -> some View {
        Button { showAll = true } label: {
            Text(String(format: NSLocalizedString("Show all (%d more)", comment: ""), hidden))
                .font(Brand.mono(10, .bold)).tracking(0.6)
                .foregroundStyle(Brand.textTertiary)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("Show all processes", comment: ""))
    }

    /// Typed filter bar (PRD §α): "cpu > 20", "name ~ chrome", or a bare term
    /// for name-contains. Recomputes the sorted rows as you type.
    private var filterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: Brand.scaled(11))).foregroundStyle(Brand.textTertiary)
            TextField(NSLocalizedString("Filter — e.g. cpu > 20, name ~ chrome", comment: ""),
                      text: Binding(get: { model.filterText }, set: { model.setFilter($0) }))
                .textFieldStyle(.plain)
                .font(Brand.mono(11)).foregroundStyle(Brand.textPrimary)
            if !model.filterText.isEmpty {
                Button { model.setFilter("") } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Brand.scaled(11))).foregroundStyle(Brand.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("Clear filter", comment: ""))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 10) {
            sortButton(String(format: NSLocalizedString("NAME (%d)", comment: ""), count), .name)
            Spacer(minLength: 8)
            sortButton("PID", .pid).frame(width: 54, alignment: .trailing)
            sortButton("CPU", .cpu).frame(width: 92, alignment: .trailing)
            sortButton("PWR", .pwr).frame(width: 44, alignment: .trailing)
            sortButton("MEM", .mem).frame(width: 64, alignment: .trailing)
            exportMenu   // aligns with the per-row … column
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// Table-level actions (PRD §α Process Inspector): a process-tree view and
    /// export of the current (sorted) set to the clipboard. Threads aren't in
    /// the `ps` sample → 0.
    private var exportMenu: some View {
        Menu {
            Button(NSLocalizedString("Process Tree…", comment: "")) { showTree = true }
            Divider()
            Button(NSLocalizedString("Copy as CSV", comment: "")) { copyExport(asCSV: true) }
            Button(NSLocalizedString("Copy as JSON", comment: "")) { copyExport(asCSV: false) }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: Brand.scaled(11))).foregroundStyle(Brand.textTertiary)
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20)
        .help(NSLocalizedString("Process tree and export", comment: ""))
        .accessibilityLabel(NSLocalizedString("Process tree and export", comment: ""))
    }

    private func copyExport(asCSV: Bool) {
        let rows = model.sortedRows.map {
            ProcessExport.Row(pid: $0.pid, name: $0.name, cpu: $0.cpu,
                              memBytes: Int64($0.memoryBytes ?? 0), threads: 0)
        }
        let text = asCSV ? ProcessExport.csv(rows) : ProcessExport.json(rows)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func sortButton(_ title: String, _ key: ProcSort) -> some View {
        Button { model.setSort(key) } label: {
            HStack(spacing: 3) {
                Text(NSLocalizedString(title, comment: "")).font(Brand.mono(10, .bold)).tracking(0.6)
                if model.sortKey == key {
                    Image(systemName: model.sortAsc ? "chevron.up" : "chevron.down")
                        .font(.system(size: Brand.scaled(7), weight: .bold))
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
    var onInspect: () -> Void = {}
    var onTermination: (Int) -> Void = { _ in }
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
        // Fixed row height: lets LazyVStack skip per-child measurement and
        // keeps the ScrollView size cache stable across feed ticks, instead of
        // re-running sizeThatFits over the whole stack (Sentry BURROW-1). The
        // 18 pt content centers in 30 pt — same visual as the old 2×6 padding.
        .frame(height: 30)
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

    /// Constant menu labels, hoisted out of the per-row `Menu` builder. As
    /// inline `NSLocalizedString`s they were re-materialized as tagged-pointer
    /// CFStrings on every 2 s feed tick × every realized row (issue #74 /
    /// Sentry BURROW-E: `_CFStringCreateTaggedPointerString` in `Menu.init`).
    /// Created once here.
    private enum L {
        static let pin = NSLocalizedString("Pin", comment: "")
        static let unpin = NSLocalizedString("Unpin", comment: "")
        static let inspect = NSLocalizedString("Inspect…", comment: "")
        static let reveal = NSLocalizedString("Reveal in Finder", comment: "")
        static let copyName = NSLocalizedString("Copy name", comment: "")
        static let copyPID = NSLocalizedString("Copy PID", comment: "")
        static let quit = NSLocalizedString("Quit…", comment: "")
        static let forceKill = NSLocalizedString("Force Kill…", comment: "")
        static let suspend = NSLocalizedString("Suspend", comment: "")
        static let resume = NSLocalizedString("Resume", comment: "")
    }

    /// Per-row "…" menu: pin, reveal, copy; Quit / Force Kill for
    /// own-user processes only — root rows stay read-only.
    private var rowMenu: some View {
        Menu {
            Button(pinned ? L.unpin : L.pin) { onPin() }
            Button(L.inspect) { onInspect() }
            Divider()
            Button(L.reveal) {
                if let path = ProcessActions.executablePath(pid: p.pid) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
            Button(L.copyName) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(p.name, forType: .string)
            }
            Button(L.copyPID) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(p.pid)", forType: .string)
            }
            if ProcessActions.isOwnProcess(pid: p.pid) {
                Divider()
                // Suspend/Resume are reversible (SIGSTOP/SIGCONT) — no confirm.
                Button(L.suspend) { ProcessActions.suspend(pid: p.pid) }
                Button(L.resume) { ProcessActions.resume(pid: p.pid) }
                Button(L.quit, role: .destructive) { confirmQuit(force: false) }
                Button(L.forceKill, role: .destructive) { confirmQuit(force: true) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: Brand.scaled(11))).foregroundStyle(Brand.textTertiary)
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 20)
        .accessibilityLabel(String(format: NSLocalizedString("Actions for %@", comment: ""), p.name))
    }

    private func confirmQuit(force: Bool) {
        ProcessActions.confirmTermination(
            pid: p.pid,
            displayName: p.name,
            force: force,
            onRefresh: { onTermination(p.pid) }
        )
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
        if let img = AppIcon.cachedImage(for: proc) {
            Image(nsImage: img).resizable().interpolation(.high)
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Brand.chipFill)
                .overlay(Image(systemName: "terminal").font(.system(size: Brand.scaled(9))).foregroundStyle(Brand.textTertiary))
        }
    }
}

/// Best-effort process → app icon. Only GUI apps (NSWorkspace running
/// apps) resolve; daemons fall back to a glyph. Cached by name.
///
/// All running-app lookups happen OFF the main thread. The previous
/// `image(for:)` walked `NSWorkspace.runningApplications` on the *main thread*
/// on every cache miss, once per *row* — hundreds of O(running-apps) walks per
/// 2 s refresh, a genuine source of main-thread hangs (Sentry BURROW-R /
/// BURROW-T, and a contributor to the render-path stalls). Now the Status
/// table pre-warms the cache from its existing off-main process pass via
/// `resolve(for:)`, and the menu-bar popup reads the cache + fills misses
/// asynchronously. The main thread never walks the app list.
enum AppIcon {
    private static let lock = NSLock()
    private static var cache: [String: NSImage] = [:]
    /// Names that resolved to nothing. Daemons (most of the process table)
    /// never match a running GUI app — remembering that avoids re-walking the
    /// app list for them on every pass.
    private static var misses: Set<String> = []
    /// Names with an in-flight async resolve, so repeated misses for the same
    /// name don't pile up duplicate background walks.
    private static var inFlight: Set<String> = []
    private static let resolveQueue = DispatchQueue(label: "dev.caezium.burrow.appicon", qos: .utility)

    /// Pure cache read — MAIN-SAFE, never walks the app list. Returns nil for
    /// an unresolved name (caller shows the glyph). Used by the Status table,
    /// whose off-main process pass pre-warms the cache via `resolve(for:)`.
    static func cachedImage(for proc: ProcessInfo) -> NSImage? {
        lock.lock(); defer { lock.unlock() }
        return cache[proc.name]
    }

    /// Cache read with an off-main fill on miss — MAIN-SAFE. Returns the cached
    /// icon immediately, or nil while an async resolve runs (the view picks the
    /// icon up on a later redraw). For call sites without an off-main batch
    /// pass — the menu-bar popup's handful of rows.
    static func image(for proc: ProcessInfo) -> NSImage? {
        lock.lock()
        if let c = cache[proc.name] { lock.unlock(); return c }
        let pending = misses.contains(proc.name) || inFlight.contains(proc.name)
        if !pending { inFlight.insert(proc.name) }
        lock.unlock()
        if !pending {
            resolveQueue.async {
                resolve(for: [proc])
                lock.lock(); inFlight.remove(proc.name); lock.unlock()
            }
        }
        return nil
    }

    /// Resolve icons for a batch of processes OFF the main thread, filling the
    /// shared cache. Walks `NSWorkspace.runningApplications` at most ONCE per
    /// call (only when there are unresolved names) and indexes it, so the cost
    /// is O(apps + procs) per pass rather than O(apps × procs) per row on main.
    /// MUST be called off the main thread.
    static func resolve(for processes: [ProcessInfo]) {
        lock.lock()
        var todo: [ProcessInfo] = [] // greenlight:ignore placeholder-content
        for p in processes where cache[p.name] == nil && !misses.contains(p.name) {
            todo.append(p) // greenlight:ignore placeholder-content
        }
        lock.unlock()
        guard !todo.isEmpty else { return } // greenlight:ignore placeholder-content

        // One running-app snapshot, indexed by localized name + executable.
        var index: [String: NSImage] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let icon = app.icon else { continue }
            if let n = app.localizedName { index[n] = icon }
            if let exe = app.executableURL?.lastPathComponent { index[exe] = icon }
        }

        lock.lock()
        for p in todo { // greenlight:ignore placeholder-content
            if let icon = index[p.name] ?? index[p.command] {
                cache[p.name] = icon
            } else {
                // Bounded: a newly-launched app with a previously-missed name
                // shows the glyph until the occasional reset re-resolves it.
                if misses.count > 512 { misses.removeAll() }
                misses.insert(p.name)
            }
        }
        lock.unlock()
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
    @Published var netRxHist: [Double] = []
    @Published var netTxHist: [Double] = []
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
    /// Pre-sorted, pinned-first rows for the table. Recomputed off the
    /// SwiftUI body — only when an input actually changes (process list,
    /// energies, sort key/direction, pins) — so the 1 s snapshot tick that
    /// re-evaluates `ProcessCard.body` no longer re-sorts hundreds of rows
    /// on the main thread (Sentry BURROW-1 / BURROW-N App Hang).
    @Published var sortedRows: [ProcessInfo] = []
    /// Typed predicate filter over the table (PRD §α), e.g. "cpu > 20" or
    /// "name ~ chrome". Empty = no filter. Parsed once per change, not per row.
    @Published var filterText: String = ""
    private var invalidatedProcessIDs: Set<Int> = []

    let db: DB
    private let live: LiveFeed
    private let feeds: FeedHub
    /// Opt-in per-process CPU watchdog (PRD §α). Inert until enabled in Settings.
    private let watchdog = ProcessWatchdog()

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
            // Only the degraded path (no live `ps` rows) depends on the
            // snapshot's engine top five, and that's ~5 rows — cheap to
            // re-sort each tick. The normal path keeps its cached rows so
            // the 1 s tick doesn't re-sort the full process set.
            if processes.isEmpty { recomputeSortedRows() }
        }
    }

    /// Sparklines, off the shared 15 s `metrics.sparklines.30m` pump (the
    /// HUD reads the same pump for its tiles + top drain).
    func subscribeSparklines() async {
        for await v in feeds.metricSparklines(db: db).subscribeValues() {
            cpuHist = v.cpu; memHist = v.mem; gpuHist = v.gpu; netHist = v.net; fanHist = v.fan
            netRxHist = v.netRx; netTxHist = v.netTx
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
                // Pre-warm the app-icon cache off-main so the rows render from
                // a pure cache read — never walking the running-app list on the
                // main thread (Sentry BURROW-R / BURROW-T).
                AppIcon.resolve(for: rows)
                return ProcessSample(processes: sampled, energies: energies)
            }.value
        }
        for await v in feed.subscribeValues() {
            invalidatedProcessIDs.removeAll()
            // Empty pass (spawn failure) keeps the table on the snapshot's
            // engine top five — recomputeSortedRows() falls back when empty.
            processes = v.processes
            energies = v.energies
            recomputeSortedRows()
            // Opt-in watchdog: evaluate this tick, dispatch any new firings.
            for f in watchdog.step(processes: v.processes, cadenceSeconds: 2) {
                watchdog.dispatch(pid: f.pid, name: f.name) { [weak self] in
                    self?.invalidateProcess(f.pid)
                }
            }
        }
    }

    func setSort(_ key: ProcSort) {
        if sortKey == key { sortAsc.toggle() }
        else { sortKey = key; sortAsc = (key == .name) }
        recomputeSortedRows()
    }

    func togglePin(_ pid: Int) {
        if pinned.contains(pid) { pinned.remove(pid) } else { pinned.insert(pid) }
        recomputeSortedRows()
    }

    func setFilter(_ text: String) {
        guard text != filterText else { return }
        filterText = text
        recomputeSortedRows()
    }

    func invalidateProcess(_ pid: Int) {
        invalidatedProcessIDs.insert(pid)
        recomputeSortedRows()
    }

    /// Re-sort the table from the current inputs and publish the result into
    /// `sortedRows`. O(n log n) over a few hundred rows, but run once per
    /// real change instead of once per `ProcessCard.body` evaluation — the
    /// body now just reads the cached array. Must run on the main actor (it
    /// mutates a `@Published`); every caller already does.
    func recomputeSortedRows() {
        var procs = processes.isEmpty ? (snap?.topProcesses ?? []) : processes
        procs.removeAll { invalidatedProcessIDs.contains($0.pid) }
        if let pred = ProcessFilter.parse(filterText) {
            procs = procs.filter {
                ProcessFilter.matches(ProcessFilter.Record(
                    pid: $0.pid, name: $0.name, cpu: $0.cpu,
                    memBytes: Int64($0.memoryBytes ?? 0), threads: 0), pred)
            }
        }
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
        sortedRows = pin + rest
    }

}
