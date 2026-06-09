//
//  Tool.swift
//  Burrow
//
//  The five tools, each with its own colour identity and a window tint —
//  the same "each tool re-themes the whole window" idea mole.fit uses,
//  but with Burrow's own palette and our own taglines (no planets, no
//  borrowed copy). `navOrder` is the left-to-right order in the top
//  pill nav; `.status` is where Burrow opens because the live dashboard
//  is the thing that's actually built.
//

import SwiftUI

enum Tool: String, CaseIterable, Identifiable {
    case clean, purge, installer, apps, optimize, analyze, status

    var id: String { rawValue }

    /// Display order in the top nav. Cleanup family (clean → purge →
    /// installer → optimize) leads, then apps / analyze. The live dashboard
    /// isn't a tool anymore — it's Home, reached by the Burrow mark.
    static let navOrder: [Tool] = [.clean, .purge, .installer, .optimize, .apps, .analyze]

    /// Lowercase tab label (matches the instrument-panel voice).
    var label: String { NSLocalizedString(rawValue, comment: "") }

    /// Title-case name for heroes / headings.
    var title: String {
        switch self {
        case .clean:     return NSLocalizedString("Clean", comment: "")
        case .purge:     return NSLocalizedString("Purge", comment: "")
        case .installer: return NSLocalizedString("Installers", comment: "")
        case .apps:      return NSLocalizedString("Software", comment: "")
        case .optimize:  return NSLocalizedString("Optimize", comment: "")
        case .analyze:   return NSLocalizedString("Analyze", comment: "")
        case .status:    return NSLocalizedString("Status", comment: "")
        }
    }

    var glyph: String {
        switch self {
        case .clean:     return "sparkles"
        case .purge:     return "folder.badge.minus"
        case .installer: return "arrow.down.app"
        case .apps:      return "shippingbox"
        case .optimize:  return "wand.and.stars"
        case .analyze:   return "square.grid.2x2"
        case .status:    return "waveform.path.ecg"
        }
    }

    /// The tool's signature accent.
    var accent: Color {
        switch self {
        case .clean:     return Color(hex: 0x35C2A5) // teal
        case .purge:     return Color(hex: 0x6FB06A) // moss
        case .installer: return Color(hex: 0xD98C5F) // ginger
        case .apps:      return Color(hex: 0xF0714E) // coral
        case .optimize:  return Color(hex: 0x8E84F0) // violet
        case .analyze:   return Color(hex: 0x4FA3E3) // azure
        case .status:    return Color(hex: 0xE6A93C) // gold
        }
    }

    /// Dark, desaturated top colour for the window scrim — the wallpaper
    /// bleeds through the translucency, this just tints it.
    private var tintTop: Color {
        switch self {
        case .clean:     return Color(hex: 0x0E2A27)
        case .purge:     return Color(hex: 0x12241A)
        case .installer: return Color(hex: 0x2A1F12)
        case .apps:      return Color(hex: 0x2B1611)
        case .optimize:  return Color(hex: 0x1A1730)
        case .analyze:   return Color(hex: 0x0E1F2E)
        case .status:    return Color(hex: 0x241D11)
        }
    }

    /// Window background scrim laid over the behind-window vibrancy.
    var scrim: LinearGradient {
        LinearGradient(colors: [tintTop.opacity(0.88), Brand.nearBlack.opacity(0.96)],
                       startPoint: .top, endPoint: .bottom)
    }

    /// Our own one-liner per tool — earthy, in keeping with the name.
    var tagline: String {
        switch self {
        case .clean:     return NSLocalizedString("Fresh air through old tunnels.", comment: "")
        case .purge:     return NSLocalizedString("Clear the diggings dev work leaves behind.", comment: "")
        case .installer: return NSLocalizedString("Sweep out the crates you unpacked.", comment: "")
        case .apps:      return NSLocalizedString("Shed what you've outgrown.", comment: "")
        case .optimize:  return NSLocalizedString("Small turns, a smoother run.", comment: "")
        case .analyze:   return NSLocalizedString("Map every chamber below.", comment: "")
        case .status:    return NSLocalizedString("Every pulse of the den.", comment: "")
        }
    }
}

/// Everything the main window can show. The five tools plus Burrow's two
/// extras (Settings, History) — all navigated from the same top bar, in
/// the same window, so there's exactly one navigation model in the app.
enum Pane: Equatable, Hashable {
    case home          // the live dashboard: Overview · History · Activity
    case tool(Tool)
    case settings

    /// Window tint scrim. Home wears the dashboard's gold; tools carry their
    /// own colour; Settings uses a neutral dark so it reads as "chrome".
    var scrim: LinearGradient {
        switch self {
        case .home:
            return Tool.status.scrim
        case .tool(let t):
            return t.scrim
        case .settings:
            return LinearGradient(colors: [Color(hex: 0x16150F).opacity(0.90), Brand.nearBlack.opacity(0.97)],
                                  startPoint: .top, endPoint: .bottom)
        }
    }
}
