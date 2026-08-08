//
//  MoleInstallView.swift
//  Burrow
//
//  Recovery UI when no engine can be found. Official builds bundle the engine,
//  so reinstalling Burrow restores the signed bundle. Source builds may still
//  provide an external `mo`; Recheck accepts either without installing for the
//  user.
//

import SwiftUI
import AppKit

struct MoleInstallView: View {
    /// Called when a Recheck finds the bundled or an external engine.
    var onReady: () -> Void

    @State private var checking = false
    @State private var stillMissing = false
    @State private var copied = false
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Burrow engine missing", systemImage: "shippingbox")
                    .font(Brand.serif(20, .medium)).foregroundStyle(Brand.textPrimary)
                Text("Official builds include the engine inside the signed app. Reinstall Burrow to restore it; source builds can also provide an external `mo` on PATH.")
                    .font(Brand.sans(13)).foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("REINSTALL SIGNED APP").font(Brand.mono(9, .bold)).tracking(0.6).foregroundStyle(Brand.textTertiary)
                HStack {
                    Text(MoleCLI.installCommand).font(Brand.mono(12)).foregroundStyle(Brand.textPrimary)
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(MoleCLI.installCommand, forType: .string)
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(Brand.mono(10)).foregroundStyle(Brand.green)
                    }.buttonStyle(.plain)
                }
                .padding(11)
                .background(RoundedRectangle(cornerRadius: 10).fill(Brand.chipFill))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Brand.hairline, lineWidth: 1))

                Button { NSWorkspace.shared.open(MoleCLI.repoURL) } label: {
                    Text("View the bundled engine source →")
                        .font(Brand.mono(10)).foregroundStyle(Brand.textSecondary)
                }.buttonStyle(.plain)
            }

            if stillMissing {
                Text("The engine is still missing. Finish reinstalling Burrow, then recheck or relaunch the app.")
                    .font(Brand.mono(10)).foregroundStyle(Brand.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain).font(Brand.sans(12)).foregroundStyle(Brand.textSecondary)
                PillButton(title: checking ? "Checking…" : "Recheck") { recheck() }
            }
        }
        .padding(22)
        .frame(width: 460, height: 320)
        .background(Brand.base)
        // Auto-detect the restored bundle or an external source-build engine.
        // Polling stops as soon as the window closes.
        .onAppear { startAutoDetect() }
        .onDisappear { pollTimer?.invalidate(); pollTimer = nil }
    }

    private func recheck() {
        checking = true; stillMissing = false; copied = false
        DispatchQueue.global(qos: .userInitiated).async {
            let found = MoleCLI.findExecutable() != nil
            DispatchQueue.main.async {
                checking = false
                if found { onReady() } else { stillMissing = true }
            }
        }
    }

    /// Poll trusted locations without spawning a subprocess on every tick;
    /// manual Recheck still performs the full PATH lookup for source builds.
    private func startAutoDetect() {
        pollTimer?.invalidate()
        let t = Timer(timeInterval: 2.0, repeats: true) { timer in
            guard MoleCLI.trustedExecutable() != nil else { return }
            timer.invalidate()
            onReady()
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }
}
