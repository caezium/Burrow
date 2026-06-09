//
//  TopNav.swift
//  Burrow
//
//  The floating top-centre nav: Burrow mark + five lowercase tool tabs,
//  with Settings (gear) and History (clock) as utilities in the same
//  bar. One navigation model for the whole window — tools and the two
//  Burrow extras are all just `Pane`s.
//

import SwiftUI

struct TopNav: View {
    @Binding var selected: Pane

    var body: some View {
        HStack(spacing: 8) {
            homeIsland
            toolGroup
            utilityGroup
        }
    }

    /// Home (the Burrow mark) sits in its own capsule — it's the dashboard, not
    /// one of the cleanup tools, so it reads as a separate island like Settings.
    private var homeIsland: some View {
        HStack(spacing: 2) {
            homeButton
        }
        .padding(4)
        .background(Capsule(style: .continuous).fill(Color.black.opacity(0.24)))
        .overlay(Capsule(style: .continuous).strokeBorder(Brand.hairline, lineWidth: 1))
    }

    private var toolGroup: some View {
        HStack(spacing: 2) {
            ForEach(Tool.navOrder) { tool in
                tab(tool)
            }
        }
        .padding(4)
        .background(Capsule(style: .continuous).fill(Color.black.opacity(0.24)))
        .overlay(Capsule(style: .continuous).strokeBorder(Brand.hairline, lineWidth: 1))
    }

    /// The Burrow mark doubles as Home — the live dashboard (Overview /
    /// History / Activity). It gets a soft ring when Home is selected.
    private var homeButton: some View {
        let isOn = selected == .home
        return Button {
            withAnimation(.easeOut(duration: 0.16)) { selected = .home }
        } label: {
            BurrowMark()
                .frame(width: 22, height: 22)
                .padding(3)
                .background { if isOn { Circle().fill(Color.white.opacity(0.14)) } }
                .overlay { if isOn { Circle().strokeBorder(Brand.cream.opacity(0.5), lineWidth: 1.5) } }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("Home", comment: ""))
    }

    private var utilityGroup: some View {
        HStack(spacing: 2) {
            utility("gearshape", pane: .settings)
        }
        .padding(4)
        .background(Capsule(style: .continuous).fill(Color.black.opacity(0.24)))
        .overlay(Capsule(style: .continuous).strokeBorder(Brand.hairline, lineWidth: 1))
    }

    private func tab(_ tool: Tool) -> some View {
        let isOn = selected == .tool(tool)
        return Button {
            withAnimation(.easeOut(duration: 0.16)) { selected = .tool(tool) }
        } label: {
            Text(tool.label)
                .font(Brand.mono(12, isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Color.black : Brand.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background { if isOn { Capsule(style: .continuous).fill(Color.white) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func utility(_ symbol: String, pane: Pane) -> some View {
        let isOn = selected == pane
        return Button {
            withAnimation(.easeOut(duration: 0.16)) { selected = pane }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isOn ? Color.black : Brand.textSecondary)
                .frame(width: 32, height: 28)
                .background { if isOn { Capsule(style: .continuous).fill(Color.white) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Burrow's mark: a cream disc with a dark burrow mouth (a tunnel arch).
struct BurrowMark: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                Circle().fill(Brand.cream)
                Path { p in
                    let cx = s * 0.5
                    let baseY = s * 0.70
                    let r = s * 0.27
                    p.move(to: CGPoint(x: cx - r, y: baseY))
                    p.addArc(center: CGPoint(x: cx, y: baseY), radius: r,
                             startAngle: .degrees(180), endAngle: .degrees(360),
                             clockwise: false)
                    p.closeSubpath()
                }
                .fill(Brand.espresso)
            }
            .frame(width: s, height: s)
        }
    }
}
