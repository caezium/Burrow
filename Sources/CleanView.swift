//
//  CleanView.swift
//  Burrow
//
//  The Clean tab — mole.fit's "Earth" flow, our brand. The hero offers
//  both a no-risk "Scan your Mac" preview (`mo clean --dry-run`) and a
//  direct "Clean Now" run. The real clean runs elevated through ONE auth
//  prompt and finishes on a proper done banner. The whole lifecycle
//  (FDA gate, streaming, cancel, OperationCenter) lives in OperationFlow;
//  this file is layout plus localized copy.
//

import SwiftUI
import AppKit

struct CleanView: View {
    @StateObject private var flow = OperationFlow<TaskRunReport>()
    @State private var mode: Mode = .dry

    enum Mode { case dry, real }

    var body: some View {
        OperationScreen(flow: flow, accent: Tool.clean.accent, status: statusText) {
            ToolHero(tool: .clean, title: "Clean", subtitle: Tool.clean.tagline) {
                PillButton(title: "Clean Now") { confirmReal() }
                PillButton(title: "Preview", filled: false) { startDry() }
            }
        } banner: {
            if case .finished(.done) = flow.state, mode == .real {
                DoneBanner(accent: Tool.clean.accent, title: "Cleaned",
                           detail: flow.report?.summary.map(cleanedDetail))
            } else if mode == .dry, let s = flow.report?.summary {
                summaryBanner(s)
            }
        }
    }

    /// Post-run detail line. Prefers the real freed-space numbers Mole
    /// prints after a live clean ("Free space change / now"), falling
    /// back to the tracked-cleanup size when those aren't present.
    private func cleanedDetail(_ s: TaskSummary) -> String {
        var parts: [String] = []
        if !s.freeChange.isEmpty { parts.append("Freed \(s.freeChange)") }
        else if !s.space.isEmpty { parts.append("Cleaned \(s.space)") }
        if !s.freeNow.isEmpty { parts.append("\(s.freeNow) free now") }
        if !s.items.isEmpty { parts.append("\(s.items) items") }
        return parts.isEmpty ? "Done" : parts.joined(separator: " · ")
    }

    private func summaryBanner(_ s: TaskSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(s.space.isEmpty ? "—" : s.space)
                .font(Brand.mono(24, .semibold)).foregroundStyle(Tool.clean.accent)
            Text("to free").font(Brand.sans(13)).foregroundStyle(Brand.textSecondary)
            if !s.items.isEmpty {
                Text(String(format: NSLocalizedString("· %@ items · %@ categories", comment: ""),
                            s.items, s.categories))
                    .font(Brand.mono(11)).foregroundStyle(Brand.textTertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var statusText: String {
        switch flow.state {
        case .running:
            return mode == .dry ? NSLocalizedString("Scanning your Mac…", comment: "")
                                : NSLocalizedString("Cleaning… don't quit.", comment: "")
        case .finished(.cancelled):
            return NSLocalizedString("Stopped.", comment: "")
        case .finished(.done):
            return mode == .dry ? NSLocalizedString("Preview — review, then clean for real.", comment: "")
                                : NSLocalizedString("Done — caches cleared.", comment: "")
        case .finished(.failed(let m)):
            return String(format: NSLocalizedString("Failed: %@", comment: ""), m)
        case .idle, .gated:
            return ""
        }
    }

    /// Dry-run scans are flood-prone without Full Disk Access — the gate in
    /// the descriptor diverts to FullDiskAccessRequired, where the user
    /// either grants FDA or picks "Scan with admin" (root bypasses TCC).
    private func startDry() {
        mode = .dry
        flow.start(.moleStream(["clean", "--dry-run"],
                               gate: .fullDiskAccess(adminBypass: true),
                               label: NSLocalizedString("Scanning caches", comment: "")))
    }

    /// The real clean already runs elevated (root), so it never triggers the
    /// flood — no gate needed here.
    private func confirmReal() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Clean caches for real?", comment: "")
        alert.informativeText = NSLocalizedString("Burrow will run `mo clean` with administrator rights. Cache files are removed permanently; Mole's whitelist and safety rules still apply.", comment: "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Clean", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        mode = .real
        flow.start(.moleStream(["clean"], elevated: true,
                               label: NSLocalizedString("Cleaning caches", comment: "")))
    }
}
