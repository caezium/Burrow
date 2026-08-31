//
//  RestoreView.swift
//  Burrow
//
//  "Restore last cleanup" pane (roadmap D.13). Reads Mole's deletion log,
//  builds a RestorePlan, and offers to put each Trash-based removal back.
//  Honest by construction: cache deletions (action "remove") are permanent and
//  shown locked; only trashed items with a free original path are restorable.
//
//  NOTE (hand-test): verify against a real cleanup — the ~/.Trash fallback move
//  and collision handling need a live Trash.
//

import SwiftUI

struct RestoreView: View {
    private struct Row: Identifiable { let id = UUID(); let entry: RestorePlan.Entry }

    @State private var rows: [Row] = []
    @State private var loading = true

    private var logPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/mole/deletions.log")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("Restore last cleanup", comment: ""))
                        .font(Brand.serif(22, .medium)).foregroundStyle(Brand.textPrimary)
                    Text(NSLocalizedString("Only Trash-based removals can be restored — cache deletions are permanent.", comment: ""))
                        .font(Brand.sans(12)).foregroundStyle(Brand.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if loading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(NSLocalizedString("Reading the cleanup log…", comment: ""))
                            .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                    }
                    .padding(.vertical, 8)
                } else if rows.isEmpty {
                    Text(NSLocalizedString("No restorable items found.", comment: ""))
                        .font(Brand.mono(11)).foregroundStyle(Brand.textTertiary)
                        .padding(.vertical, 8)
                } else {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                                if i > 0 {
                                    Rectangle().fill(Brand.hairline).frame(height: 1)
                                }
                                row(r.entry)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .fadeEdges()
        .task { await reload() }
    }

    private func row(_ entry: RestorePlan.Entry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.restorable ? "arrow.uturn.backward.circle.fill" : "lock.circle.fill")
                .font(.system(size: Brand.scaled(15)))
                .foregroundStyle(entry.restorable ? Brand.green : Brand.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text((entry.path as NSString).lastPathComponent)
                    .font(Brand.sans(13, .semibold)).foregroundStyle(Brand.textPrimary).lineLimit(1)
                Text(entry.reason).font(Brand.mono(10)).foregroundStyle(Brand.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if entry.restorable {
                Button { restore(entry) } label: {
                    Text(NSLocalizedString("Restore", comment: ""))
                        .font(Brand.sans(11, .semibold)).foregroundStyle(Tool.clean.accent)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Brand.chipFill))
                }
                .buttonStyle(.plain)
            } else {
                Text(NSLocalizedString("permanent", comment: ""))
                    .font(Brand.mono(9, .medium)).foregroundStyle(Brand.textTertiary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Brand.textTertiary.opacity(0.12)))
            }
        }
        .padding(.vertical, 10)
    }

    private func reload() async {
        let path = logPath
        let entries = await Task.detached(priority: .utility) { () -> [RestorePlan.Entry] in
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            let items = RestorePlan.parseLog(text)
            return RestorePlan.build(items, existsAtOriginal: { FileManager.default.fileExists(atPath: $0) })
        }.value
        rows = entries.map { Row(entry: $0) }
        loading = false
    }

    /// Fallback restore: find the item by name in ~/.Trash and move it back to
    /// its recorded origin, skipping on collision. (Finder "put back" needs
    /// Finder's own metadata; this works without it.)
    private func restore(_ entry: RestorePlan.Entry) {
        let name = (entry.path as NSString).lastPathComponent
        let trashed = (NSHomeDirectory() as NSString).appendingPathComponent(".Trash/\(name)")
        let fm = FileManager.default
        if fm.fileExists(atPath: trashed), !fm.fileExists(atPath: entry.path) {
            try? fm.moveItem(atPath: trashed, toPath: entry.path)
        }
        Task { await reload() }
    }
}
