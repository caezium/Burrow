//
//  ConductorScanStates.swift
//  Burrow
//
//  The states the four bundled-engine discovery panes render identically: the "this build
//  shipped without the engine" explanation, the error card, and the folder picker. Each pane
//  used to carry a private copy; the wording that differs per pane is passed in.
//

import SwiftUI
import AppKit

enum ConductorScanStates {

    /// The pane's degrade state on a build without Resources/burrow. `explanation` is the
    /// pane-specific sentence ("Duplicate scanning runs through the bundled `burrow` CLI. …").
    static func conductorMissing(_ explanation: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "shippingbox").font(.system(size: 26)).foregroundStyle(Brand.textTertiary)
            Text(NSLocalizedString("The bundled burrow conductor is missing", comment: ""))
                .font(Brand.serif(17, .medium)).foregroundStyle(Brand.textPrimary)
            Text(explanation)
                .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
        }
    }

    static func errorState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 22)).foregroundStyle(Brand.orange)
            Text(message).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 340)
        }
    }

    /// The folder picker, opened on `current` when there is one; `scan` receives the chosen
    /// absolute path. Synchronous (a modal panel), hang-tracking suppressed like every other
    /// panel the app opens.
    @MainActor
    static func pickFolder(current: String?, scan: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("Scan", comment: "")
        if let current {
            panel.directoryURL = URL(fileURLWithPath: current)
        }
        guard CrashReporter.withoutAppHangTracking({ panel.runModal() }) == .OK,
              let url = panel.url else { return }
        scan(url.path)
    }
}
