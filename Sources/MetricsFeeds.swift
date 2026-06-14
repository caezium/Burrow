//
//  MetricsFeeds.swift
//  Burrow
//
//  The shared metric queries for the two live dashboards (issue #53):
//  the menu-bar HUD (PopupView) and the Status pane both want the latest
//  snapshot and a 30-min sparkline set — so they ask the hub for the SAME
//  keys and get ONE pump each (one timer, one read, two observers). Before
//  this, the HUD ran a 1 s + 20 s timer pair and Status ran a 2 s + 15 s
//  pair, double-polling the same `LiveFeed` snapshot and the same DB
//  history window. Now the popover and the Status pane stop double-polling
//  the moment they bind to these keys.
//
//  The fetch closures live here, once, so the two screens can never drift
//  to slightly-different keys (which would silently un-share the pump).
//  Pure aggregation helpers (`Sparklines.from`) are split out so the
//  manual-clock tests can assert them without a DB.
//

import Foundation

// MARK: - Value types

/// The latest decoded snapshot plus when it was sampled — the 1 s "live"
/// payload both dashboards read straight off `LiveFeed` (no `mo` spawn:
/// the SnapshotProducer already published it).
struct LiveSnapshot {
    let snap: MoleStatus?
    let sampledAt: Date?
}

/// The ~30-min sparkline set + the hour's heaviest process. Computed from
/// one DB history read so the HUD's six tiles, the battery card's top
/// drain, and the Status sparklines all come from a single pass.
struct MetricSparklines: Hashable {
    var cpu: [Double] = []
    var mem: [Double] = []
    var net: [Double] = []
    var gpu: [Double] = []
    /// RPM series — only the snapshots that reported fans (fanCount > 0)
    /// contribute, matching the tiles' "no placebo zeros" rule.
    var fan: [Double] = []
    /// Heaviest process by average CPU over the window (battery card).
    /// Stored as the named-tuple parts so the struct stays Equatable —
    /// the change token can fold identical windows into zero republishes.
    var drainName: String?
    var drainCPU: Double = 0

    var topDrain: (name: String, avgCPU: Double)? {
        drainName.map { ($0, drainCPU) }
    }
}

/// One `ps` pass (the full live process set) paired with each row's
/// cumulative billed energy (nJ) — published together so a row and its
/// PWR value always belong to the same pass. Status-only: the HUD shows
/// the engine top five, not the full table.
struct ProcessSample {
    let processes: [ProcessInfo]
    let energies: [Int: UInt64]
}

// MARK: - Pure aggregation

/// Projects a window of stored snapshots into the sparkline set. Pure (no
/// DB, no clock) so it's unit-testable; the feed wraps it around a read.
enum Sparklines {
    /// `tailPoints` keeps the sparkline length the tiles expect (~30)
    /// while the drain ranking still sees the whole window.
    static func from(_ statuses: [MoleStatus], tailPoints: Int = 30) -> MetricSparklines {
        var cpu: [Double] = [], mem: [Double] = [], net: [Double] = [], gpu: [Double] = []
        var fan: [Double] = []
        var processLists: [[ProcessInfo]] = []
        for s in statuses {
            cpu.append(s.cpu.usage)
            mem.append(s.memory.usedPercent)
            net.append(s.network.reduce(0.0) { $0 + $1.rxRateMbs + $1.txRateMbs })
            gpu.append(max(0, s.gpu?.first?.usage ?? 0))
            if let thermal = s.thermal, (thermal.fanCount ?? 0) > 0 {
                fan.append(Double(thermal.fanSpeed))
            }
            if let procs = s.topProcesses { processLists.append(procs) }
        }
        // Sparklines stay ~30 points; the drain ranking uses the full hour.
        let drain = TopDrain.heaviest(processLists)
        return MetricSparklines(
            cpu: Array(cpu.suffix(tailPoints)),
            mem: Array(mem.suffix(tailPoints)),
            net: Array(net.suffix(tailPoints)),
            gpu: Array(gpu.suffix(tailPoints)),
            fan: Array(fan.suffix(tailPoints)),
            drainName: drain?.name,
            drainCPU: drain?.avgCPU ?? 0)
    }
}

// MARK: - Shared metric queries (the dedup point)

extension FeedHub {
    /// The live snapshot pump — `snapshot.live`, 1 s. Reads the already
    /// published `LiveFeed` value on the main actor (no engine spawn); the
    /// HUD and Status share this one instance. The change token folds runs
    /// of identical samples so a 1 Hz poll over an unchanged row causes no
    /// republish churn in either screen.
    func liveSnapshot(_ live: LiveFeed) -> Feed<LiveSnapshot> {
        feed("snapshot.live", cadence: 1,
             changeToken: { $0.sampledAt.map(AnyHashable.init) }) {
            await MainActor.run {
                LiveSnapshot(snap: live.lastSnapshot, sampledAt: live.sampledAt)
            }
        }
    }

    /// The 30-min sparkline pump — `metrics.sparklines.30m`, 15 s (the
    /// lower of the HUD's old 20 s and Status's old 15 s, so neither loses
    /// resolution). Reads a single 1-hour DB window off-main and projects
    /// it; the HUD renders the tiles + top drain, Status renders the
    /// sparklines, both off the ONE read. The token is the projected value
    /// itself, so a tick that re-reads an unchanged window (no new sample
    /// landed since the last) skips the republish in both screens.
    func metricSparklines(db: DB) -> Feed<MetricSparklines> {
        feed("metrics.sparklines.30m", cadence: 15,
             changeToken: { AnyHashable($0) }) {
            await Task.detached(priority: .userInitiated) {
                let now = Int(Date().timeIntervalSince1970)
                // One hour so the drain ranking has the full window; the
                // sparklines are the trailing ~30 points of it.
                let stored = MetricsStore(db: db)
                    .snapshots(.init(since: now - 60 * 60, until: now), maxPoints: 60)
                    .snapshots
                return Sparklines.from(stored.map(\.status))
            }.value
        }
    }
}
