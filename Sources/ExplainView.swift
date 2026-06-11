//
//  ExplainView.swift
//  Burrow
//
//  The Explain lens's UI: a small panel that runs the ExplainEngine over
//  the latest snapshot and shows a plain-English read of the machine,
//  plus — when warranted — one button that deep-links into Clean / Purge /
//  Installers (behind their existing confirm sheets). It never acts on
//  its own; the button just navigates.
//

import SwiftUI

struct ExplainView: View {
    let db: DB
    var onNavigate: (Pane) -> Void
    var onClose: () -> Void

    @State private var loading = true
    @State private var result: ExplainResult?
    @State private var error: String?
    @State private var explainTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Explain", systemImage: "sparkles")
                    .font(Brand.serif(18, .medium)).foregroundStyle(Brand.textPrimary)
                Spacer()
                Button { onClose() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16))
                        .foregroundStyle(Brand.textTertiary)
                }.buttonStyle(.plain)
            }

            Group {
                if loading {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Reading your Mac…").font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                    }
                } else if let error {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(error).font(Brand.sans(12)).foregroundStyle(Brand.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Retry") { run() }
                            .buttonStyle(.plain).font(Brand.mono(11)).foregroundStyle(Brand.green)
                    }
                } else if let result {
                    Text(result.explanation)
                        .font(Brand.sans(13)).foregroundStyle(Brand.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let s = result.suggestion {
                        PillButton(title: s.ctaLabel) { onNavigate(s.pane); onClose() }
                    }
                }
            }
            Spacer(minLength: 0)
            Text("AI read of one snapshot — it can be wrong, and never acts on its own.")
                .font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
        }
        .padding(18)
        .frame(width: 440, height: 300)
        .background(Color(hex: 0x14130E))
        .environment(\.colorScheme, .dark)
        .onAppear { run() }
        // Dismissing the sheet must cancel the in-flight request — it can
        // be a paid hosted endpoint on a 30–60 s timeout, and reopening
        // would otherwise stack a second call behind the orphan.
        .onDisappear { explainTask?.cancel() }
    }

    private func run() {
        loading = true; error = nil; result = nil
        explainTask = Task {
            do {
                let r = try await ExplainEngine.fromSettings().explain(db: db)
                guard !Task.isCancelled else { return }
                await MainActor.run { self.result = r; self.loading = false }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { self.error = error.localizedDescription; self.loading = false }
            }
        }
    }
}
