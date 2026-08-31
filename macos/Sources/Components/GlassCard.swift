//
//  GlassCard.swift
//  Burrow / Components
//
//  The translucent card + the two small atoms that sit inside it
//  everywhere: the uppercase eyebrow (small glyph + label) and the
//  pill chip. Kept tiny and dependency-free so the dashboard reads as
//  a flat list of `GlassCard { ... }` blocks.
//

import SwiftUI

struct GlassCard<Content: View>: View {
    var padding: CGFloat = 16
    var corner: CGFloat = 20
    var minHeight: CGFloat? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            // Borderless: a soft filled surface + a whisper of elevation reads
            // cleaner than ruled boxes — fewer lines, the fill does the work.
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Brand.cardFill)
            )
            .shadow(color: .black.opacity(0.06), radius: 7, x: 0, y: 2)
    }
}

/// Tiny uppercase section label with a leading glyph — "☼ HEALTH".
struct Eyebrow: View {
    let text: String
    let glyph: String
    var color: Color = Brand.textSecondary

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: glyph)
                .font(.system(size: Brand.scaled(9), weight: .bold))
            Text(NSLocalizedString(text, comment: "").uppercased())
                .font(Brand.mono(10, .bold))
                .tracking(1.0)
        }
        .foregroundStyle(color)
    }
}

/// Small rounded pill used for inline status ("normal", "HTTP", "Good").
struct Chip: View {
    let text: String
    var color: Color = Brand.textSecondary

    var body: some View {
        Text(NSLocalizedString(text, comment: ""))
            .font(Brand.mono(10, .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(color.opacity(0.16)))
    }
}
