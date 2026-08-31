//
//  CleanHub.swift
//  Burrow
//
//  The merged Clean pane: one hub over three cleanup categories that each
//  keep their own engine and view verbatim — system & app caches (Clean),
//  project build artifacts (Purge), and leftover installers (Installer).
//  Purge and Installer used to be separate top-nav pills; folding them
//  under Clean as category cards keeps one cleanup surface. Every body
//  stays mounted so an in-flight run survives switching categories.
//

import SwiftUI

struct CleanHub: View {
    enum Category: CaseIterable, Identifiable {
        case caches, purge, installer
        var id: Self { self }

        /// The underlying tool — reused for glyph / accent / tagline so the
        /// cards carry each category's existing identity (the .purge and
        /// .installer Tool cases live on purely for this + MCP/Explain).
        var tool: Tool {
            switch self {
            case .caches:    return .clean
            case .purge:     return .purge
            case .installer: return .installer
            }
        }

        var cardTitle: String {
            switch self {
            case .caches:    return NSLocalizedString("System & app caches", comment: "")
            case .purge:     return NSLocalizedString("Project build artifacts", comment: "")
            case .installer: return NSLocalizedString("Leftover installers", comment: "")
            }
        }
    }

    /// nil = the category chooser is showing. Skip-intro power users land
    /// straight on caches (today's Clean experience); everyone else sees the
    /// three cards first.
    @State private var category: Category?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init() { _category = State(initialValue: Store.skipIntro ? .caches : nil) }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if category != nil { backBar }
                ZStack {
                    CleanView().hubVisible(category == .caches)
                    MoInteractiveView(.purge, isActive: category == .purge).hubVisible(category == .purge)
                    MoInteractiveView(.installer, isActive: category == .installer).hubVisible(category == .installer)
                }
            }
            if category == nil { chooser }
        }
    }

    private var backBar: some View {
        HStack(spacing: 8) {
            Button { withAnim { category = nil } } label: {
                Label(NSLocalizedString("Cleanup", comment: ""), systemImage: "chevron.left")
                    .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("Back to cleanup categories", comment: ""))
            if let c = category {
                Text(verbatim: "·").font(Brand.mono(11)).foregroundStyle(Brand.textTertiary)
                Text(c.cardTitle).font(Brand.mono(11)).foregroundStyle(Brand.textTertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 6)
    }

    private var chooser: some View {
        VStack(spacing: 18) {
            Spacer()
            HeroOrb(accent: Tool.clean.accent, size: 96)
            VStack(spacing: 8) {
                Text(NSLocalizedString("Clean", comment: "")).font(Brand.serif(28, .medium)).foregroundStyle(Brand.textPrimary)
                Text(NSLocalizedString("Pick what to clear.", comment: "")).font(Brand.serif(15)).italic().foregroundStyle(Brand.textSecondary)
            }
            HStack(spacing: 16) {
                ForEach(Category.allCases) { c in
                    CleanCategoryCard(category: c) { withAnim { category = c } }
                }
            }
            .padding(.top, 6)
            Spacer(); Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func withAnim(_ change: () -> Void) {
        if reduceMotion { change() }
        else { withAnimation(.easeInOut(duration: 0.2), change) }
    }
}

/// One category card on the Clean chooser.
private struct CleanCategoryCard: View {
    let category: CleanHub.Category
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: category.tool.glyph)
                    .font(.system(size: Brand.scaled(24))).foregroundStyle(category.tool.accent)
                Spacer(minLength: 6)
                Text(category.cardTitle)
                    .font(Brand.sans(15, .semibold)).foregroundStyle(Brand.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(category.tool.tagline)
                    .font(Brand.sans(11)).foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 200, height: 168, alignment: .leading)
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 18).fill(hover ? Brand.cardFillHover : Brand.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 18)
                .strokeBorder(category.tool.accent.opacity(hover ? 0.5 : 0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(category.cardTitle)
        .accessibilityHint(category.tool.tagline)
    }
}

private extension View {
    /// Keep a body mounted (so its @StateObject + in-flight run survive)
    /// while hiding it when its category isn't active.
    @ViewBuilder func hubVisible(_ visible: Bool) -> some View {
        self.opacity(visible ? 1 : 0).allowsHitTesting(visible)
    }
}
