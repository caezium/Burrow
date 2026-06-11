//
//  OptimizeView.swift
//  Burrow
//
//  The Optimize tab — mole.fit's "Mercury" one-tap maintenance, our
//  brand. "Optimize" runs the safe maintenance tasks (elevated through a
//  single auth prompt); "Preview" is a no-auth `--dry-run`. The lifecycle
//  lives in OperationFlow; this file is layout plus localized copy.
//

import SwiftUI

struct OptimizeView: View {
    @StateObject private var flow = OperationFlow<TaskRunReport>()
    @State private var preview = false

    var body: some View {
        OperationScreen(flow: flow, accent: Tool.optimize.accent, status: statusText) {
            ToolHero(tool: .optimize, title: "Optimize", subtitle: Tool.optimize.tagline) {
                PillButton(title: "Optimize") { runOptimize() }
                PillButton(title: "Preview", filled: false) { runPreview() }
            }
        } banner: {
            if case .finished(.done) = flow.state, !preview {
                DoneBanner(accent: Tool.optimize.accent, title: "Maintenance complete",
                           detail: String(format: NSLocalizedString("%d areas refreshed", comment: ""),
                                          flow.report?.groups.count ?? 0))
            }
        }
    }

    private var statusText: String {
        switch flow.state {
        case .running:
            return preview ? NSLocalizedString("Previewing maintenance…", comment: "")
                           : NSLocalizedString("Running maintenance…", comment: "")
        case .finished(.cancelled):
            return NSLocalizedString("Stopped.", comment: "")
        case .finished(.done):
            return preview ? NSLocalizedString("Preview complete.", comment: "")
                           : NSLocalizedString("Maintenance complete.", comment: "")
        case .finished(.failed(let m)):
            return String(format: NSLocalizedString("Failed: %@", comment: ""), m)
        case .idle, .gated:
            return ""
        }
    }

    /// Optimize already runs elevated (root) → no flood, no gate.
    private func runOptimize() {
        preview = false
        flow.start(.moleStream(["optimize"], elevated: true,
                               label: NSLocalizedString("Optimizing", comment: "")))
    }

    private func runPreview() {
        preview = true
        flow.start(.moleStream(["optimize", "--dry-run"],
                               gate: .fullDiskAccess(adminBypass: true),
                               label: NSLocalizedString("Optimize preview", comment: "")))
    }
}
