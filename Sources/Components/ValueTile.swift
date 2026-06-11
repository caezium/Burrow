//
//  ValueTile.swift
//  Burrow
//
//  The one metric tile. Two variants render the two places it appears —
//  the Status dashboard card and the menu-bar HUD — with their historical
//  metrics preserved exactly (fonts, spacing, chart height, container).
//  The variant table keeps the drift visible and intentional; a third
//  variant that needs different *structure* gets its own view instead.
//

import SwiftUI

struct ValueTile: View {
    enum Variant { case card, hud }
    var variant: Variant = .card
    let eyebrow: String
    let glyph: String
    let accent: Color
    let value: String
    var unit: String = ""
    /// Rendered in the .card header only — the HUD tile never had one.
    var chip: (String, Color)? = nil
    let values: [Double]
    var chartStyle: MiniChart.Style = .area
    var footnote: String? = nil
    /// .card only (feeds GlassCard).
    var minHeight: CGFloat? = nil

    var body: some View {
        switch variant {
        case .card: card
        case .hud:  hud
        }
    }

    private var card: some View {
        GlassCard(minHeight: minHeight) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Eyebrow(text: eyebrow, glyph: glyph, color: accent)
                    Spacer(minLength: 4)
                    if let c = chip { Chip(text: c.0, color: c.1) }
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value).font(Brand.mono(26, .semibold)).foregroundStyle(Brand.textPrimary)
                    if !unit.isEmpty {
                        Text(unit).font(Brand.mono(12)).foregroundStyle(Brand.textSecondary)
                    }
                }
                MiniChart(values: values, color: accent, style: chartStyle)
                    .frame(height: 30)
                Spacer(minLength: 2)
                if let f = footnote {
                    Text(f).font(Brand.mono(10)).foregroundStyle(Brand.textTertiary).lineLimit(1)
                }
            }
        }
    }

    private var hud: some View {
        VStack(alignment: .leading, spacing: 3) {
            Eyebrow(text: eyebrow, glyph: glyph, color: accent)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(Brand.mono(15, .semibold)).foregroundStyle(Brand.textPrimary)
                if !unit.isEmpty { Text(unit).font(Brand.mono(9)).foregroundStyle(Brand.textSecondary) }
            }
            MiniChart(values: values, color: accent, style: chartStyle).frame(height: 13)
            if let f = footnote {
                Text(f).font(Brand.mono(8.5)).foregroundStyle(Brand.textTertiary).lineLimit(1)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Brand.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Brand.hairline, lineWidth: 1))
    }
}
