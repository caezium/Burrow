//
//  BurrowLayoutRenderer.swift
//  Burrow Cards — the fixed, signed renderer: BurrowLayout JSON → native SwiftUI.
//
//  Every case here is compiled into the app. Incoming JSON only *selects* from
//  this vocabulary; it can never introduce new views or run code.
//

import SwiftUI

/// Top-level card: header (title/subtitle) + node tree + action buttons.
public struct BurrowLayoutView: View {
    public let layout: BurrowLayout
    public var onAction: ((BurrowAction) -> Void)?

    public init(layout: BurrowLayout, onAction: ((BurrowAction) -> Void)? = nil) {
        self.layout = layout
        self.onAction = onAction
    }

    private var accent: Color { Color(hex: layout.accentColorHex) ?? .accentColor }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(layout.title).font(.headline)
                if let subtitle = layout.subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }

            BurrowNodeView(node: layout.root, accent: accent)

            if let actions = layout.actions, !actions.isEmpty {
                VStack(spacing: 8) {
                    ForEach(actions, id: \.id) { action in
                        Button {
                            onAction?(action)
                        } label: {
                            Label(action.label, systemImage: action.systemImage ?? "arrow.up.forward")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(accent)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One node in the tree. Recurses for containers.
struct BurrowNodeView: View {
    let node: BurrowNode
    let accent: Color

    var body: some View {
        switch node {
        case let .vstack(spacing, children):
            VStack(alignment: .leading, spacing: cg(spacing) ?? 8) {
                childViews(children)
            }
        case let .hstack(spacing, children):
            HStack(spacing: cg(spacing) ?? 8) {
                childViews(children)
            }
        case let .section(title, children):
            VStack(alignment: .leading, spacing: 6) {
                if let title {
                    Text(title.uppercased())
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) { childViews(children) }
                    .padding(12)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        case let .text(text, role):
            Text(text).font(font(for: role))
        case let .statusBadge(label, colorHex):
            let c = Color(hex: colorHex) ?? accent
            Text(label)
                .font(.caption).fontWeight(.bold)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(c.opacity(0.18))
                .foregroundStyle(c)
                .clipShape(Capsule())
        case let .progressBar(value, colorHex):
            ProgressView(value: clamp(value))
                .tint(Color(hex: colorHex) ?? accent)
        case let .gauge(label, value, colorHex):
            Gauge(value: clamp(value)) { Text(label) }
                .tint(Color(hex: colorHex) ?? accent)
        case let .keyValueRow(key, value):
            HStack {
                Text(key).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(value).fontWeight(.medium).multilineTextAlignment(.trailing)
            }
        }
    }

    @ViewBuilder
    private func childViews(_ children: [BurrowNode]) -> some View {
        ForEach(Array(children.enumerated()), id: \.offset) { _, child in
            BurrowNodeView(node: child, accent: accent)
        }
    }

    private func font(for role: String?) -> Font {
        switch role {
        case "title": return .title3.bold()
        case "caption": return .caption
        default: return .body
        }
    }

    private func cg(_ d: Double?) -> CGFloat? { d.map { CGFloat($0) } }
    private func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
}

extension Color {
    /// Parse `#RRGGBB` (or `RRGGBB`). Returns nil for anything else.
    init?(hex: String?) {
        guard var h = hex else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt64(h, radix: 16) else { return nil }
        self = Color(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}

#Preview {
    ScrollView { BurrowLayoutView(layout: BurrowSamples.disk) }
}
