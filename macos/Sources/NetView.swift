//
//  NetView.swift
//  Burrow
//
//  The Network tab — a conductor-tool surface copying the Duplicates pane's
//  idiom, minus the folder machinery (there is no folder: the sample is
//  machine-wide). A Refresh-driven table over `burrow net --json`: per-process
//  bytes in / out / total from nettop's counters, ranked by total, decoded by
//  the pure NetModel parser off the main thread.
//
//  The sample is cheap (~a second), so the pane auto-samples the first time
//  it becomes active (PortsView's isActive idiom) and refreshes manually
//  after — no polling, no timers.
//
//  READ-ONLY v1: it names the talkers, it doesn't quiet them. Degrade:
//  dev/CI builds without the vendor/burrow-cli submodule have no bundled
//  conductor — the pane explains instead of dead-ending.
//

import SwiftUI
import AppKit

struct NetView: View {
    var isActive: Bool = true
    @StateObject private var model = NetModel()

    var body: some View {
        VStack(spacing: 0) {
            toolbar.padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 12)
            Rectangle().fill(Brand.hairline).frame(height: 1)
            ZStack {
                if !BurrowEngine.isAvailable {
                    conductorMissing
                } else if model.scanning {
                    scanningProgress
                } else if let err = model.error {
                    errorState(err)
                } else if let report = model.report {
                    if report.rows.isEmpty { quietState } else { results(report) }
                } else {
                    idleState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The first activation samples automatically (it's cheap); after
        // that the refresh button owns the cadence.
        .onAppear { if isActive { model.scanIfNeeded() } }
        .onChange(of: isActive) { _, now in if now { model.scanIfNeeded() } }
    }

    // MARK: Toolbar (Analyze's idiom, folderless: label + summary + refresh)

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(NSLocalizedString("Per-app network, one sample", comment: ""))
                .font(Brand.mono(12)).foregroundStyle(Brand.textTertiary)
            Spacer()
            if let report = model.report {
                Text(summaryLine(report))
                    .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
            }
            Button { model.scan() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: Brand.scaled(11), weight: .semibold))
                    .foregroundStyle(Brand.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(!BurrowEngine.isAvailable || model.scanning)
            .help(NSLocalizedString("Sample again", comment: ""))
        }
    }

    /// "N processes · X total" — the sample's one-line truth.
    private func summaryLine(_ report: NetReport) -> String {
        String(format: NSLocalizedString("%d processes · %@ total", comment: ""),
               report.rows.count, Fmt.bytes(report.rows.reduce(Int64(0)) { $0 + $1.total }))
    }

    // MARK: States

    private var conductorMissing: some View {
        ConductorScanStates.conductorMissing(NSLocalizedString("Network sampling runs through the bundled `burrow` CLI. This build shipped without it — a dev build without the vendor/burrow-cli submodule. Release builds include it.", comment: ""))
    }

    private var idleState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.up.arrow.down").font(.system(size: Brand.scaled(26))).foregroundStyle(Tool.net.accent)
            Text(NSLocalizedString("Watch what travels the tunnels", comment: ""))
                .font(Brand.serif(17, .medium)).foregroundStyle(Brand.textPrimary)
            Text(NSLocalizedString("One nettop sample of every process's bytes in and out, biggest talkers first. Read-only — it names the talkers, it doesn't quiet them.", comment: ""))
                .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
            Button { model.scan() } label: {
                Text(NSLocalizedString("Sample now", comment: ""))
                    .font(Brand.sans(12, .semibold)).foregroundStyle(Brand.onInverse)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(Brand.inverse))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
    }

    private var scanningProgress: some View {
        VStack(spacing: 12) {
            Text(NSLocalizedString("Sampling the network", comment: ""))
                .font(Brand.serif(18, .medium)).foregroundStyle(Brand.textPrimary)
            HStack(spacing: 8) {
                PulsingDot(color: Tool.net.accent)
                Text(NSLocalizedString("Reading nettop's per-process byte counters…", comment: ""))
                    .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NSLocalizedString("Sampling network usage", comment: ""))
    }

    private func errorState(_ message: String) -> some View {
        ConductorScanStates.errorState(message)
    }

    private var quietState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle").font(.system(size: Brand.scaled(24))).foregroundStyle(Tool.net.accent)
            Text(NSLocalizedString("All quiet", comment: ""))
                .font(Brand.serif(17, .medium)).foregroundStyle(Brand.textPrimary)
            Text(NSLocalizedString("No process moved bytes during the sample window.", comment: ""))
                .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
        }
    }

    // MARK: Results (a plain ranked table — name · pid · in · out · total)

    private func results(_ report: NetReport) -> some View {
        VStack(spacing: 0) {
            columnHeader.padding(.horizontal, 31).padding(.vertical, 7)
            Rectangle().fill(Brand.hairline).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(report.rows) { row($0) }
                    if let note = report.note {
                        Text(note)
                            .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                            .multilineTextAlignment(.center)
                            .padding(.vertical, 10).padding(.horizontal, 18)
                    }
                    Color.clear.frame(height: 16)
                }
                .padding(.horizontal, 18)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 10) {
            Text(NSLocalizedString("process", comment: "net column"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(NSLocalizedString("pid", comment: "net column"))
                .frame(width: 52, alignment: .trailing)
            Text(NSLocalizedString("in", comment: "net column"))
                .frame(width: 72, alignment: .trailing)
            Text(NSLocalizedString("out", comment: "net column"))
                .frame(width: 72, alignment: .trailing)
            Text(NSLocalizedString("total", comment: "net column"))
                .frame(width: 76, alignment: .trailing)
        }
        .font(Brand.mono(9, .medium)).foregroundStyle(Brand.textTertiary)
    }

    private func row(_ r: NetRow) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Tool.net.accent.opacity(0.8)).frame(width: 5, height: 5)
                    .accessibilityHidden(true)
                Text(r.name)
                    .font(Brand.sans(12)).foregroundStyle(Brand.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: r.pid > 0 ? "\(r.pid)" : "—")
                .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                .frame(width: 52, alignment: .trailing)
            Text(Fmt.bytes(r.bytesIn))
                .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                .frame(width: 72, alignment: .trailing)
            Text(Fmt.bytes(r.bytesOut))
                .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                .frame(width: 72, alignment: .trailing)
            Text(Fmt.bytes(r.total))
                .font(Brand.mono(11, .medium)).foregroundStyle(Tool.net.accent)
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 13).padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: NSLocalizedString("%@, %@ in, %@ out", comment: ""),
                                   r.name, Fmt.bytes(r.bytesIn), Fmt.bytes(r.bytesOut)))
    }
}

// MARK: - Model

/// Folderless: one `net` sample of the machine. The envelope's `data` is the net report,
/// decoded by the pure NetReport.parse.
@MainActor
final class NetModel: ConductorScanModel<NetReport> {
    init() {
        super.init(command: Command(
            name: "net",
            arguments: { _ in [] },
            timeout: 60,
            parse: { NetReport.parse($0) },
            beginLabel: { _ in NSLocalizedString("Sampling per-app network", comment: "") },
            successDetail: { r in String(format: NSLocalizedString("%d processes", comment: ""), r.rows.count) },
            unreadable: NSLocalizedString("burrow net returned an unreadable report", comment: "")))
    }

    /// First-activation sample: only when nothing has been sampled yet, so
    /// switching back to the tab never stomps a result the user is reading.
    func scanIfNeeded() {
        guard BurrowEngine.isAvailable, report == nil, error == nil, !scanning else { return }
        scan()
    }

    /// Sample via the bundled engine, off the main thread.
    func scan() { run() }
}
