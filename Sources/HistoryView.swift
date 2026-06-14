//
//  HistoryView.swift
//  Burrow
//
//  History window (Burrow's own long-range value-add): charts over the
//  SQLite history, plus a peak-per-process table. Opened from the HUD's
//  clock button.
//
//  Data path is unchanged from the original: range chip → DB.findRange
//  Sampled (stride-sampled, ≤720 rows) → decode each row to MoleStatus →
//  project to per-chart ChartPoint arrays → SwiftUI Charts. Only the view
//  layer is reskinned into the Brand glass system.
//

import SwiftUI
import Charts

// MARK: - Range chips

struct HistoryRange: Hashable, Identifiable {
    let label: String
    let minutes: Int
    var id: Int { minutes }

    static let all: [HistoryRange] = [
        .init(label: "5m",  minutes: 5),
        .init(label: "1h",  minutes: 60),
        .init(label: "6h",  minutes: 360),
        .init(label: "24h", minutes: 1440),
        .init(label: "7d",  minutes: 10080),
        .init(label: "30d", minutes: 43200),
        .init(label: "90d", minutes: 129600),
    ]
}

// MARK: - Chart series + snapshot bag

struct ChartPoint: Identifiable {
    let id = UUID()
    let time: Date
    let value: Double
}

struct ProcessRow: Identifiable {
    let id = UUID()
    let name: String
    let peakCPU: Double
    let peakMem: Double
    let peakMemBytes: UInt64
}

/// Which resource the Top Processes table ranks by. Mole's `top_processes`
/// only carries CPU + memory per process (no per-process network/disk), so
/// those are the two axes we can honestly rank.
enum ProcMetric: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case ram = "RAM"
    var id: String { rawValue }
}

/// Splits a series into segments wherever consecutive samples are farther
/// apart than `gap` — so a line is only drawn across genuinely contiguous
/// data. Two far-apart points become two single-point segments, which
/// render no line at all (the chart reads empty instead of drawing a
/// straight line across a gap where Burrow simply wasn't sampling).
private struct HistorySegment: Identifiable {
    let id = UUID()
    let time: Date
    let value: Double
    let key: String

    static func split(_ pts: [ChartPoint], name: String, gap: TimeInterval) -> [HistorySegment] {
        var out: [HistorySegment] = []
        var seg = 0
        for (i, p) in pts.enumerated() {
            if i > 0, p.time.timeIntervalSince(pts[i - 1].time) > gap { seg += 1 }
            out.append(HistorySegment(time: p.time, value: p.value, key: "\(name)#\(seg)"))
        }
        return out
    }
}

private struct HistorySnapshot {
    var cpuUsage: [ChartPoint] = []
    var cpuLoad1: [ChartPoint] = []
    var memoryUsed: [ChartPoint] = []
    var memoryPressure: String = "—"
    var diskRead: [ChartPoint] = []
    var diskWrite: [ChartPoint] = []
    var netRx: [ChartPoint] = []
    var netTx: [ChartPoint] = []
    var thermalCPU: [ChartPoint] = []
    var thermalGPU: [ChartPoint] = []
    var thermalBattery: [ChartPoint] = []
    var fanSpeed: [ChartPoint] = []
    var fanCount: Int = 0
    var batteryPercent: [ChartPoint] = []
    var gpuUsage: [ChartPoint] = []
    var healthScore: [ChartPoint] = []

    var topProcesses: [ProcessRow] = []

    var generatedAt: Date = Date()
    var rowCount: Int = 0
    var staleSeconds: Int? = nil

    var windowSince: Date = Date().addingTimeInterval(-3600)
    var windowUntil: Date = Date()
}

// MARK: - Loader (off-main)

private enum HistoryLoader {
    static func load(db: DB, rangeMinutes: Int, ioSamples: [LiveFeed.Sample] = []) -> HistorySnapshot {
        let now = Int(Date().timeIntervalSince1970)
        let since = now - rangeMinutes * 60
        var snap = HistorySnapshot()
        snap.windowSince = Date(timeIntervalSince1970: TimeInterval(since))
        snap.windowUntil = Date(timeIntervalSince1970: TimeInterval(now))

        let store = MetricsStore(db: db)
        let window = MetricsStore.Window(since: since, until: now)
        let snaps = store.snapshots(window).snapshots
        snap.rowCount = snaps.count

        // Projection rules (gpu −1, thermal 0s, fan-count gating) live in
        // the Metric table — this loop only decides which chart gets which
        // metric. A nil projection appends nothing: a gap, never a fake 0.
        for stored in snaps {
            let s = stored.status
            let t = Date(timeIntervalSince1970: TimeInterval(stored.ts))
            func add(_ m: Metric, _ points: inout [ChartPoint]) {
                if let v = m.value(in: s) { points.append(.init(time: t, value: v)) }
            }
            add(.cpuUsage, &snap.cpuUsage)
            add(.cpuLoad1, &snap.cpuLoad1)
            add(.memoryUsedPercent, &snap.memoryUsed)
            add(.diskRead, &snap.diskRead)
            add(.diskWrite, &snap.diskWrite)
            add(.networkRx, &snap.netRx)
            add(.networkTx, &snap.netTx)
            add(.thermalCPU, &snap.thermalCPU)
            add(.thermalGPU, &snap.thermalGPU)
            add(.thermalBattery, &snap.thermalBattery)
            add(.fanSpeed, &snap.fanSpeed)
            add(.batteryPercent, &snap.batteryPercent)
            add(.gpuUsage, &snap.gpuUsage)
            add(.healthScore, &snap.healthScore)
            snap.fanCount = max(snap.fanCount, s.thermal?.fanCount ?? 0)
            snap.memoryPressure = s.memory.pressure
        }

        // Overlay the dense 1 s net/disk ring on the recent portion so these two
        // charts update at the same cadence as the Home tiles. The coarse
        // snapshot points are kept only for the window BEFORE the ring begins.
        if let ringStart = ioSamples.first?.time {
            func splice(_ pts: [ChartPoint], _ ring: [ChartPoint]) -> [ChartPoint] {
                pts.filter { $0.time < ringStart } + ring
            }
            snap.netRx     = splice(snap.netRx,     ioSamples.map { .init(time: $0.time, value: $0.rxMBs) })
            snap.netTx     = splice(snap.netTx,     ioSamples.map { .init(time: $0.time, value: $0.txMBs) })
            snap.diskRead  = splice(snap.diskRead,  ioSamples.map { .init(time: $0.time, value: $0.readMBs) })
            snap.diskWrite = splice(snap.diskWrite, ioSamples.map { .init(time: $0.time, value: $0.writeMBs) })
        }

        // Union of the CPU and memory leaders — same aggregation the MCP
        // tools use, computed once in MetricsStore instead of a third copy.
        let pw = store.processWindow(window)
        let leaders = pw.ranked(by: .peakCPU, limit: 20) + pw.ranked(by: .peakMem, limit: 20)
        var seen = Set<String>()
        var rows2: [ProcessRow] = []
        for p in leaders where seen.insert(p.name).inserted {
            rows2.append(ProcessRow(name: p.name,
                                    peakCPU: p.peakCPU,
                                    peakMem: p.peakMem,
                                    peakMemBytes: p.peakMemBytes))
        }
        snap.topProcesses = rows2.sorted { $0.peakCPU > $1.peakCPU }

        snap.generatedAt = Date()
        if let latest = snaps.last { snap.staleSeconds = max(0, now - latest.ts) }
        return snap
    }
}

// MARK: - Axis style helper

@available(macOS 14.0, *)
private struct AxisStyle {
    let format: Date.FormatStyle
    let desiredCount: Int

    static func forRangeMinutes(_ rangeMinutes: Int) -> AxisStyle {
        switch rangeMinutes {
        case ..<60:            return AxisStyle(format: .dateTime.hour().minute(), desiredCount: 5)
        case ..<(6 * 60):      return AxisStyle(format: .dateTime.hour().minute(), desiredCount: 5)
        case ..<(24 * 60):     return AxisStyle(format: .dateTime.hour(), desiredCount: 6)
        case ..<(8 * 24 * 60): return AxisStyle(format: .dateTime.weekday(.abbreviated).day(), desiredCount: 5)
        case ..<(45 * 24 * 60):return AxisStyle(format: .dateTime.month(.abbreviated).day(), desiredCount: 6)
        default:               return AxisStyle(format: .dateTime.month(.abbreviated), desiredCount: 4)
        }
    }
}

// MARK: - View

struct HistoryView: View {
    let db: DB
    let live: LiveFeed
    let feeds: FeedHub

    @State private var range: HistoryRange = {
        let m = Store.lastHistoryRangeMinutes
        return HistoryRange.all.first(where: { $0.minutes == m }) ?? HistoryRange.all[1]
    }()
    @State private var snapshot: HistorySnapshot = HistorySnapshot()
    @State private var loading: Bool = false
    @State private var procMetric: ProcMetric = .cpu
    /// The currently-subscribed board feed — held so the toolbar's manual
    /// refresh can poke it; lifecycle belongs to `.task(id: range)` below.
    @State private var board: Feed<HistorySnapshot>?

    var body: some View {
        VStack(spacing: 0) {
            toolbar.padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 12)
                Rectangle().fill(Brand.hairline).frame(height: 1)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 13), GridItem(.flexible(), spacing: 13)], spacing: 13) {
                        chartCard("CPU usage", "%", [("usage", snapshot.cpuUsage, Brand.green)], marks: .bars)
                        chartCard("CPU load", "1m avg", [("load1", snapshot.cpuLoad1, Brand.orange)])
                        chartCard("Memory", snapshot.memoryPressure.isEmpty ? "% used" : snapshot.memoryPressure,
                                  [("used", snapshot.memoryUsed, Brand.amber)])
                        chartCard("GPU usage", "%", [("gpu", snapshot.gpuUsage, Brand.orange)], marks: .bars)
                        chartCard("Disk I/O", "MB/s", [("read", snapshot.diskRead, Brand.blue),
                                                       ("write", snapshot.diskWrite, Color(hex: 0x6E8BEA))])
                        chartCard("Network", "MB/s", [("rx", snapshot.netRx, Brand.green),
                                                      ("tx", snapshot.netTx, Color(hex: 0x57C2A5))])
                        chartCard("Thermal", "°C", [("cpu", snapshot.thermalCPU, Brand.red),
                                                    ("gpu", snapshot.thermalGPU, Brand.orange),
                                                    ("battery", snapshot.thermalBattery, Brand.gold)])
                        chartCard("Fans", snapshot.fanCount > 0 ? "RPM" : "not reported",
                                  [("fan", snapshot.fanSpeed, Color(hex: 0x6EC1E4))])
                        chartCard("Battery", "%", [("charge", snapshot.batteryPercent, Brand.green)])
                        chartCard("Health score", "0–100", [("health", snapshot.healthScore, Brand.gold)], marks: .bars)
                        topProcessesCard
                    }
                    .padding(16)
                }
                .scrollIndicators(.hidden)
            }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The whole load/refresh lifecycle is one task-scoped feed
        // subscription (issue #53): the 2 s pump only ticks while this view
        // is on screen — disappearing cancels the task, which detaches the
        // pump. No view-owned timer, so the old leaked `autoRefreshTimer`
        // class is unrepresentable. Switching ranges restarts the task
        // (`id: range`) onto that range's shared feed; the previous
        // snapshot stays rendered until the new window's first value lands.
        .task(id: range) {
            Store.lastHistoryRangeMinutes = range.minutes
            let feed = boardFeed(for: range)
            board = feed
            loading = snapshot.rowCount == 0
            for await snap in feed.subscribeValues() {
                snapshot = snap
                loading = false
            }
        }
    }

    /// The shared, demand-counted query for one range's history board.
    private func boardFeed(for range: HistoryRange) -> Feed<HistorySnapshot> {
        let db = self.db, live = self.live, minutes = range.minutes
        return feeds.feed("history.board.\(minutes)", cadence: 2) {
            // Grab the dense net/disk ring on the main actor (the loader
            // runs off it), trimmed to the window and downsampled so a 1 h
            // range isn't 3600 points.
            let ring = await MainActor.run { () -> [LiveFeed.Sample] in
                let since = Date().addingTimeInterval(-Double(minutes * 60))
                return Self.downsample(live.samples.filter { $0.time >= since }, max: 900)
            }
            return await Task.detached(priority: .userInitiated) {
                HistoryLoader.load(db: db, rangeMinutes: minutes, ioSamples: ring)
            }.value
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("History").font(Brand.serif(22, .medium)).foregroundStyle(Brand.textPrimary)
            rangePills
            if loading { ProgressView().controlSize(.small) }
            Spacer()
            Text(String(format: NSLocalizedString("%d samples", comment: ""), snapshot.rowCount)).font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
            if let s = snapshot.staleSeconds {
                Text(String(format: NSLocalizedString("· latest %ds ago", comment: ""), s)).font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
            }
            Button { loading = true; board?.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.textSecondary)
            }.buttonStyle(.plain).keyboardShortcut("r", modifiers: .command)
        }
    }

    private var rangePills: some View {
        HStack(spacing: 2) {
            ForEach(HistoryRange.all) { r in
                let on = r == range
                Button { range = r } label: {
                    Text(r.label).font(Brand.mono(11, on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.black : Brand.textSecondary)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background { if on { Capsule().fill(.white) } }
                        .contentShape(Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.black.opacity(0.22)))
        .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 1))
    }

    /// How a chart card draws its series: continuous metrics stay lines,
    /// discrete usage-style metrics (CPU / GPU / health) read as bars.
    private enum ChartMarks { case line, bars }

    /// Evenly spaced sample indices to label on a by-index bar axis — maps
    /// back to real timestamps for the labels without distorting the bars.
    /// Doubles so they match the bars' Double x-scale (an Int x on a Double
    /// domain renders nothing).
    private func barAxisTicks(_ count: Int, desired: Int) -> [Double] {
        guard count > 1 else { return count == 1 ? [0] : [] }
        let n = max(2, min(desired, count))
        return (0..<n).map { (Double($0) * Double(count - 1) / Double(n - 1)).rounded() }
    }

    /// Cap a bar series to a count a chart card can actually render — a
    /// ~380 pt card maxes out around `cap` bars; beyond that they're
    /// sub-pixel and only cost layout (the #57 hang). Strides evenly,
    /// keeping the first and last sample.
    static func capBars(_ pts: [ChartPoint], max cap: Int = 140) -> [ChartPoint] {
        guard pts.count > cap, cap > 1 else { return pts }
        let step = Double(pts.count - 1) / Double(cap - 1)
        return (0..<cap).map { pts[Int((Double($0) * step).rounded())] }
    }

    private func chartCard(_ title: String, _ subtitle: String,
                           _ series: [(name: String, points: [ChartPoint], color: Color)],
                           marks: ChartMarks = .line) -> some View {
        let allEmpty = series.allSatisfy { $0.points.isEmpty }
        let style = AxisStyle.forRangeMinutes(range.minutes)
        let window = Double(range.minutes * 60)
        let strideSec = max(1.0, window / 720.0)
        let gapThreshold = max(Double(Store.sampleIntervalSeconds), strideSec) * 3.5
        return GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(NSLocalizedString(title, comment: "").uppercased()).font(Brand.mono(10, .bold)).tracking(0.7).foregroundStyle(series.first?.color ?? Brand.textSecondary)
                    Text(NSLocalizedString(subtitle, comment: "")).font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                }
                if allEmpty {
                    Text("No samples in this window")
                        .font(Brand.mono(11)).foregroundStyle(Brand.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 170)
                } else if marks == .bars {
                    // Bars are plotted BY INDEX (like the Status sparklines):
                    // each sample gets an equal slot, so width and gaps are
                    // uniform at every range. Axis labels map a few indices
                    // back to their real timestamps.
                    //
                    // #57: a 90-day range stride-samples to 720 points, and a
                    // BarMark per point is a layout node — 720 × several bar
                    // cards drove SwiftUI's alignment layout into a recursive
                    // explosion (a ≥2 s main-thread hang; `explicitAlignment` +
                    // chkstk in the trace). Two fixes:
                    //   1. CAP the bar count — a ~380 pt card can't render more
                    //      than ~140 bars meaningfully, so down-sample there.
                    //   2. NO GeometryReader — its size → barW → mark-layout →
                    //      size feedback was the cycle that recursed. The width
                    //      is a fixed pixel value derived from the (capped)
                    //      count instead. (.ratio renders nothing on this
                    //      index scale — keep .fixed.)
                    let capped = series.map {
                        (name: $0.name, points: Self.capBars($0.points), color: $0.color)
                    }
                    let n = max(capped.map(\.points.count).max() ?? 0, 1)
                    let labelPts = capped.first?.points ?? []
                    let barW = max(1.5, min(12.0, 360.0 / CGFloat(n) * 0.6))
                    Chart {
                        ForEach(capped, id: \.name) { s in
                            ForEach(Array(s.points.enumerated()), id: \.offset) { idx, p in
                                BarMark(x: .value("Sample", Double(idx)), y: .value("Value", p.value),
                                        width: .fixed(barW))
                                    .foregroundStyle(s.color.opacity(0.85))
                            }
                        }
                    }
                    .chartXScale(domain: -0.5 ... (Double(n) - 0.5))
                    .chartXAxis {
                        AxisMarks(values: barAxisTicks(labelPts.count, desired: style.desiredCount)) { v in
                            AxisGridLine().foregroundStyle(Brand.hairline)
                            if let d = v.as(Double.self) {
                                let i = Int(d.rounded())
                                if i >= 0, i < labelPts.count {
                                    AxisValueLabel { Text(labelPts[i].time, format: style.format) }
                                        .foregroundStyle(Brand.textTertiary).font(Brand.mono(8))
                                }
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks { _ in
                            AxisGridLine().foregroundStyle(Brand.hairline)
                            AxisValueLabel().foregroundStyle(Brand.textTertiary).font(Brand.mono(8))
                        }
                    }
                    .frame(height: 170)
                } else {
                    Chart {
                        ForEach(series, id: \.name) { s in
                            ForEach(HistorySegment.split(s.points, name: s.name, gap: gapThreshold)) { p in
                                LineMark(x: .value("Time", p.time), y: .value("Value", p.value),
                                         series: .value("Series", p.key))
                                    .foregroundStyle(s.color)
                                    .interpolationMethod(.monotone)
                            }
                        }
                    }
                    .chartXScale(domain: snapshot.windowSince...snapshot.windowUntil)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: style.desiredCount)) { _ in
                            AxisGridLine().foregroundStyle(Brand.hairline)
                            AxisValueLabel(format: style.format).foregroundStyle(Brand.textTertiary)
                                .font(Brand.mono(8))
                        }
                    }
                    .chartYAxis {
                        AxisMarks { _ in
                            AxisGridLine().foregroundStyle(Brand.hairline)
                            AxisValueLabel().foregroundStyle(Brand.textTertiary).font(Brand.mono(8))
                        }
                    }
                    .frame(height: 170)
                }
            }
        }
    }

    /// Processes ranked by the selected metric (CPU or RAM), peak across the
    /// window. The same rows carry both peaks, so switching the toggle just
    /// re-sorts in place — no reload.
    private var rankedProcesses: [ProcessRow] {
        switch procMetric {
        case .cpu: return snapshot.topProcesses.sorted { $0.peakCPU > $1.peakCPU }
        case .ram: return snapshot.topProcesses.sorted {
            ($0.peakMemBytes, $0.peakMem) > ($1.peakMemBytes, $1.peakMem)
        }
        }
    }

    private var topProcessesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(NSLocalizedString("Top processes", comment: "").uppercased()).font(Brand.mono(10, .bold)).tracking(0.7).foregroundStyle(Brand.textSecondary)
                    Text("peak across window").font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                    Spacer()
                    procMetricToggle
                }
                if snapshot.topProcesses.isEmpty {
                    Text("No processes recorded")
                        .font(Brand.mono(11)).foregroundStyle(Brand.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 170)
                } else {
                    // Column header makes it clear which number is which once the
                    // ranking can change what's on top.
                    HStack {
                        Text("").frame(maxWidth: .infinity, alignment: .leading)
                        Text("CPU").font(Brand.mono(8, .bold)).tracking(0.5)
                            .foregroundStyle(procMetric == .cpu ? Brand.green : Brand.textTertiary)
                            .frame(width: 52, alignment: .trailing)
                        Text("RAM").font(Brand.mono(8, .bold)).tracking(0.5)
                            .foregroundStyle(procMetric == .ram ? Brand.amber : Brand.textTertiary)
                            .frame(width: 70, alignment: .trailing)
                    }
                    ScrollView {
                        VStack(spacing: 3) {
                            ForEach(rankedProcesses.prefix(20)) { row in
                                HStack {
                                    Text(row.name).font(Brand.sans(11)).foregroundStyle(Brand.textPrimary).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(String(format: "%.1f%%", row.peakCPU)).font(Brand.mono(10))
                                        .foregroundStyle(procMetric == .cpu ? Brand.green : Brand.textTertiary)
                                        .frame(width: 52, alignment: .trailing)
                                    Text(ramLabel(row)).font(Brand.mono(10))
                                        .foregroundStyle(procMetric == .ram ? Brand.amber : Brand.textTertiary)
                                        .frame(width: 70, alignment: .trailing)
                                }
                            }
                        }
                    }
                    .frame(height: 148)
                }
            }
        }
    }

    /// RAM column shows an absolute size when Mole reported bytes, else the
    /// percent it always carries.
    private func ramLabel(_ row: ProcessRow) -> String {
        row.peakMemBytes > 0 ? Fmt.bytes(Int64(row.peakMemBytes)) : String(format: "%.1f%%", row.peakMem)
    }

    private var procMetricToggle: some View {
        HStack(spacing: 2) {
            ForEach(ProcMetric.allCases) { m in
                let on = m == procMetric
                Button { procMetric = m } label: {
                    Text(m.rawValue).font(Brand.mono(9, on ? .bold : .regular))
                        .foregroundStyle(on ? Color.black : Brand.textSecondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background { if on { Capsule().fill(.white) } }
                        .contentShape(Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.black.opacity(0.22)))
        .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 1))
    }

    // MARK: - Load lifecycle

    private static func downsample(_ s: [LiveFeed.Sample], max: Int) -> [LiveFeed.Sample] {
        guard s.count > max else { return s }
        let step = Double(s.count) / Double(max)
        return (0..<max).map { s[Int(Double($0) * step)] }
    }
}
