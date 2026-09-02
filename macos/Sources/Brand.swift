//
//  Brand.swift
//  Burrow
//
//  Burrow's visual language — a warm coffee ground (not grey), crisp warm
//  ink, and a single electric-blue accent for primary emphasis. Each tool
//  still keeps its own vivid accent (teal / violet / coral / azure / gold)
//  for active states, so the app reads as one warm, calm surface with
//  bright, purposeful pops — not a window that re-tints itself per tool.
//
//  Every surface/text token is appearance-adaptive (warm-dark + warm-light)
//  so the whole shell follows the system theme. Type is the bundled brand
//  set:
//    * mono / rounded / sans  — Geist + Geist Mono (registered in Fonts.swift)
//    * display / serif        — Cal Sans, the one expressive voice
//

import AppKit
import SwiftUI

/// The live interface text scale (issue #407). One process-wide object so
/// the `Brand` font factories — plain static funcs with no environment —
/// can read the factor cheaply on every body evaluation, and so the window
/// roots (`RootView`) can observe it and re-render when Settings changes
/// it. Not the menu-bar status item: that renders through `MenuBarRenderer`
/// with its own per-widget `MenuBarTextSize`.
final class TypeScale: ObservableObject {
    static let shared = TypeScale()

    @Published private(set) var value: InterfaceScale
    /// Cached so `Brand.scaled` is a field read, not an enum switch plus a
    /// defaults lookup, on each of the hundreds of font calls per render.
    private(set) var factor: CGFloat

    private init() {
        let v = Store.interfaceScale
        value = v
        factor = v.factor
    }

    func set(_ newValue: InterfaceScale) {
        Store.interfaceScale = newValue
        factor = newValue.factor
        value = newValue
    }
}

extension Color {
    /// 0xRRGGBB literal → sRGB Color.
    init(hex: UInt, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    /// Appearance-adaptive sRGB colour: `dark` hex in dark mode, `light` hex
    /// in light mode, each with its own opacity. Backed by a dynamic NSColor
    /// so it re-resolves when the system (or window) appearance flips.
    static func adaptive(_ dark: UInt, _ light: UInt,
                         darkA: Double = 1, lightA: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let isDark = ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            let a = isDark ? darkA : lightA
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: a)
        })
    }
}

enum Brand {
    // MARK: Ground — warm coffee (dark) / warm paper (light)
    static let base      = Color.adaptive(0x17120A, 0xF4EFE6)
    static let baseSoft  = Color.adaptive(0x211A11, 0xFCF9F3)
    static let nearBlack = Color.adaptive(0x0F0B05, 0xE8E1D4)

    // MARK: Text — warm off-white (dark) / warm espresso (light)
    static let ink           = Color.adaptive(0xEDE6DA, 0x221B11)
    static let textPrimary   = Color.adaptive(0xEDE6DA, 0x221B11)
    static let textSecondary = Color.adaptive(0xEDE6DA, 0x221B11, darkA: 0.62, lightA: 0.62)
    static let textTertiary  = Color.adaptive(0xEDE6DA, 0x221B11, darkA: 0.40, lightA: 0.46)

    // MARK: Surfaces — warm-white lift (dark) / warm cards over paper (light)
    static let hairline      = Color.adaptive(0xF2ECE0, 0x2A2114, darkA: 0.10, lightA: 0.12)
    static let cardFill      = Color.adaptive(0xF2ECE0, 0xFFFFFF, darkA: 0.07, lightA: 0.66)
    static let cardFillHover = Color.adaptive(0xF2ECE0, 0xFFFFFF, darkA: 0.11, lightA: 0.90)
    static let chipFill      = Color.adaptive(0xF2ECE0, 0x2A2114, darkA: 0.08, lightA: 0.07)
    static let trackFill     = Color.adaptive(0xF2ECE0, 0x2A2114, darkA: 0.10, lightA: 0.10)
    /// Recessed panel/track — darker than the ground in both modes.
    static let insetFill     = Color.adaptive(0x000000, 0x2A2114, darkA: 0.22, lightA: 0.07)

    // MARK: Inverse — the high-contrast CTA pill (bright on dark, ink on paper)
    static let inverse   = Color.adaptive(0xFFFFFF, 0x221B11)
    static let onInverse = Color.adaptive(0x0F0B05, 0xF4EFE6)

    // MARK: Accent — one electric blue for primary emphasis (both modes)
    static let accent   = Color(hex: 0x5B8DEF)
    static let onAccent = Color(hex: 0x08101C)   // near-black text on any bright accent
    static let lilac    = Color(hex: 0xB7B2FF)
    static let apricot  = Color(hex: 0xFFD3B6)
    static let mint     = Color(hex: 0x8FE9D0)

    // MARK: Metric / per-tool accents (vivid pops, fixed across modes)
    static let green  = Color(hex: 0x3CB371)
    static let gold   = Color(hex: 0xE6A93C)
    static let amber  = Color(hex: 0xF0B24A)
    static let orange = Color(hex: 0xF0714E)
    static let blue   = Color(hex: 0x4FA3E3)
    static let red    = Color(hex: 0xF0604E)
    static let teal   = Color(hex: 0x16A37F)
    static let violet = Color(hex: 0x8E84F0)
    static let moss   = Color(hex: 0x6FB06A)
    static let ginger = Color(hex: 0xD98C5F)

    // MARK: Brand mark colours (the Burrow disc keeps a warm pop, both modes)
    static let cream    = Color(hex: 0xF3ECDD)
    static let espresso = Color(hex: 0x1A140E)

    // MARK: Shape — rounded, the house signature
    static let rSmall: CGFloat = 12
    static let rCard:  CGFloat = 18
    static let rLarge: CGFloat = 26

    /// A stable warm veil drawn over the window vibrancy — identical on every
    /// pane (no per-tool re-tint), adaptive to the system theme.
    static var windowVeil: LinearGradient {
        LinearGradient(
            colors: [Color.adaptive(0x211A11, 0xFCF9F3, darkA: 0.55, lightA: 0.50),
                     Color.adaptive(0x100B05, 0xEFE8DC, darkA: 0.82, lightA: 0.64)],
            startPoint: .top, endPoint: .bottom)
    }

    /// A faint warm glow for the canvas — the house "gradient", kept ambient
    /// (a single soft light in the top-trailing corner) rather than a per-tool
    /// wash. Sits over the veil in RootView.
    static var ambientGlow: RadialGradient {
        RadialGradient(
            colors: [Color(hex: 0xD9A066).opacity(0.07), .clear],
            center: .topTrailing, startRadius: 0, endRadius: 560)
    }

    // MARK: Type — the bundled brand set (registered in Fonts.swift)
    //
    // Geist resolves to a REAL face per weight rather than `.weight(...)` over
    // one family. Asking a variable font for a weight it has no registered face
    // for made CoreText synthesize the instance, and that occasionally produced
    // no glyphs at all — see the note in Fonts.swift.
    //
    // Sizes here and at `.system(size:)` call sites are written at the
    // historical 1.0-scale values; the user's interface text scale
    // (issue #407) multiplies through `scaled(_:)` at resolve time.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(Fonts.geistMono(weight), size: scaled(size))
    }
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(Fonts.geist(weight), size: scaled(size))
    }
    /// The display / hero voice — Cal Sans.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(Fonts.display, size: scaled(size)).weight(weight)
    }
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(Fonts.display, size: scaled(size)).weight(weight)
    }

    /// A point size at the user's interface text scale. The brand factories
    /// above apply it themselves; glyph sizes (`.system(size:)` on SF
    /// Symbols) and the popover width opt in at the call site so icons keep
    /// pace with the text they sit beside.
    static func scaled(_ size: CGFloat) -> CGFloat {
        size * TypeScale.shared.factor
    }
}
