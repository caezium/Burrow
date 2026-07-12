//
//  Tool.swift
//  Burrow
//
//  The five tools, each with its own colour identity and a window tint
//  that re-themes the whole window as you switch — Burrow's own palette
//  and taglines. `navOrder` is the left-to-right order in the top pill
//  nav; `.status` is where Burrow opens because the live dashboard is
//  the thing that's actually built.
//

import SwiftUI

enum Tool: String, CaseIterable, Identifiable {
    case clean, purge, installer, apps, optimize, analyze, dupes, orphans, photos, status, ports, net, connectivity, tuneup

    var id: String { rawValue }

    /// Display order in the top nav. Purge and Installer fold into Clean as
    /// category cards (CleanHub), so the cleanup family is one pill: clean →
    /// optimize, then apps / analyze. The .purge/.installer cases live on for
    /// the hub cards, MCP actions, and Explain deep-links. The live dashboard
    /// isn't a tool anymore — it's Home, reached by the Burrow mark.
    static let navOrder: [Tool] = [.clean, .optimize, .apps, .analyze, .dupes, .orphans, .photos, .ports, .net, .connectivity]

    /// Lowercase tab label (matches the instrument-panel voice).
    var label: String { NSLocalizedString(rawValue, comment: "") }

    /// Title-case name for heroes / headings.
    var title: String {
        switch self {
        case .clean:     return NSLocalizedString("Clean", comment: "")
        case .purge:     return NSLocalizedString("Purge", comment: "")
        case .installer: return NSLocalizedString("Installers", comment: "")
        case .apps:      return NSLocalizedString("Apps", comment: "")
        case .optimize:  return NSLocalizedString("Optimize", comment: "")
        case .analyze:   return NSLocalizedString("Analyze", comment: "")
        case .dupes:     return NSLocalizedString("Duplicates", comment: "")
        case .orphans:   return NSLocalizedString("Leftovers", comment: "")
        case .photos:    return NSLocalizedString("Similar Photos", comment: "")
        case .status:    return NSLocalizedString("Status", comment: "")
        case .ports:     return NSLocalizedString("Ports", comment: "")
        case .net:       return NSLocalizedString("Network", comment: "")
        case .connectivity: return NSLocalizedString("Get Online", comment: "")
        case .tuneup:    return NSLocalizedString("Tune-Up", comment: "")
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
        case .dupes:     return "doc.on.doc"
        case .orphans:   return "externaldrive.badge.questionmark"
        case .photos:    return "photo.on.rectangle.angled"
        case .status:    return "waveform.path.ecg"
        case .ports:     return "network"
        case .net:       return "arrow.up.arrow.down"
        case .connectivity: return "wifi"
        case .tuneup:    return "slider.horizontal.3"
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
        case .dupes:     return Color(hex: 0xDB7E9C) // rose
        case .orphans:   return Color(hex: 0xB7BE5A) // olive
        case .photos:    return Color(hex: 0xD57BC4) // orchid
        case .status:    return Color(hex: 0xE6A93C) // gold
        case .ports:     return Color(hex: 0xB58BD6) // lilac
        case .net:       return Color(hex: 0x6E8FE0) // indigo
        case .connectivity: return Color(hex: 0x4FC3D9) // cyan
        case .tuneup:    return Color(hex: 0x5AA98B) // sage
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
        case .dupes:     return Color(hex: 0x2A141C)
        case .orphans:   return Color(hex: 0x232612)
        case .photos:    return Color(hex: 0x281425)
        case .status:    return Color(hex: 0x241D11)
        case .ports:     return Color(hex: 0x1B1426)
        case .net:       return Color(hex: 0x131A2C)
        case .connectivity: return Color(hex: 0x0E2630)
        case .tuneup:    return Color(hex: 0x12231D)
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
        case .dupes:     return NSLocalizedString("Find what you've stashed twice.", comment: "")
        case .orphans:   return NSLocalizedString("Traces of tenants long gone.", comment: "")
        case .photos:    return NSLocalizedString("Spot the shots that echo.", comment: "")
        case .status:    return NSLocalizedString("Every pulse of the den.", comment: "")
        case .ports:     return NSLocalizedString("See who's listening.", comment: "")
        case .net:       return NSLocalizedString("Watch what travels the tunnels.", comment: "")
        case .connectivity: return NSLocalizedString("Find your way back to the surface.", comment: "")
        case .tuneup:    return NSLocalizedString("One pass, a tidier den.", comment: "")
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
