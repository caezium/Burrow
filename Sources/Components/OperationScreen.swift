//
//  OperationScreen.swift
//  Burrow
//
//  The shared scaffold for a TaskReport-shaped operation view: idle → the
//  tool's hero, gated → the Full Disk Access gate wired straight to the
//  flow, running/finished → status bar + banner slot + the report. Clean
//  and Optimize supply only their hero, banner, and localized status copy.
//

import SwiftUI

struct OperationScreen<Hero: View, Banner: View>: View {
    @ObservedObject var flow: OperationFlow<TaskRunReport>
    let accent: Color
    let status: String
    @ViewBuilder var hero: () -> Hero
    @ViewBuilder var banner: () -> Banner

    var body: some View {
        switch flow.state {
        case .idle:
            hero()
        case .gated(let pending):
            FullDiskAccessRequired(
                accent: accent,
                onRecheck: {
                    // "I've granted it" is just start again — the flow
                    // re-probes; still gated means access isn't visible yet.
                    flow.start(pending)
                    if case .gated = flow.state { return false }
                    return true
                },
                onRunAnyway: { flow.start(pending.elevated()) },   // root dodges TCC
                onCancel: { flow.reset() })
        case .running, .finished:
            VStack(spacing: 0) {
                statusBar.padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 12)
                Rectangle().fill(Brand.hairline).frame(height: 1)
                banner()
                TaskReportView(groups: flow.report?.groups ?? [], accent: accent)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if case .running = flow.state {
                ProgressView().controlSize(.small).tint(accent)
            }
            Text(status).font(Brand.mono(12)).foregroundStyle(Brand.textSecondary)
            Spacer()
            // Only when Stop can actually stop: an elevated run's root `mo`
            // would survive the SIGTERM and keep going.
            if flow.canCancel {
                Button { flow.cancel() } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(Brand.mono(11)).foregroundStyle(Brand.red)
                }.buttonStyle(.plain)
            }
            if case .finished = flow.state {
                Button { flow.reset() } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                }.buttonStyle(.plain)
            }
        }
    }
}
