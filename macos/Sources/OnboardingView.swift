//
//  OnboardingView.swift
//  Burrow
//
//  First-run onboarding: two full-window slides shown once, after the
//  mo-missing gate (MoleInstallView is effectively slide 0).
//
//    1. Permissions — Full Disk Access as a PermissionRow; skippable,
//       because the safe scan works without it (the in-flow gates and
//       the access banner remain the fallback).
//    2. Free & open source — the $0 card and what's included. Telemetry
//       stays opt-out and lives in Settings ▸ Advanced only (no inline
//       toggle here — hand-test feedback 2026-06).
//
//  Window chrome is plain (traffic lights only); AppDelegate owns the
//  window and passes `onFinish`.
//

import SwiftUI

struct OnboardingView: View {
    var onFinish: () -> Void

    @State private var page = 0
    @State private var fdaGranted = Privacy.hasFullDiskAccess()
    @State private var showRelaunchHint = false
    /// Cleaning-engine status, probed off-main (nil = still checking).
    @State private var engine: EngineStatus?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `descriptor` is the engine's own "<product> <version>" string, NOT a bare number —
    /// the two engines that can sit behind this row number themselves on unrelated scales
    /// (a 0.x Rust `burrow-engine`, a 1.4x mo), so a lone "v0.1.0" chip would say nothing
    /// the user could act on. nil = the engine answered but gave no usable version.
    private struct EngineStatus { let installed: Bool; let descriptor: String? }

    var body: some View {
        ZStack {
            VisualEffectBackground().ignoresSafeArea()
            Brand.windowVeil.ignoresSafeArea()
            Brand.ambientGlow.ignoresSafeArea()

            VStack(spacing: 0) {
                progressDashes.padding(.top, 26)
                if page == 0 { permissionsSlide } else { freeSlide }
            }
        }
        .frame(minWidth: 640, minHeight: 520)
    }

    // MARK: - Progress dashes

    private var progressDashes: some View {
        HStack(spacing: 7) {
            ForEach(0..<2, id: \.self) { i in
                Capsule()
                    .fill(Brand.ink.opacity(i == page ? 0.95 : 0.30))
                    .frame(width: i == page ? 28 : 14, height: 4)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: page)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: NSLocalizedString("Step %d of %d", comment: "onboarding progress"), page + 1, 2))
    }

    // MARK: - Slide 1 · permissions

    private var permissionsSlide: some View {
        VStack(spacing: 0) {
            Spacer()
            heroMark
            Text("Grant access to get started.")
                .font(Brand.serif(28, .medium)).foregroundStyle(Brand.textPrimary)
                .padding(.top, 22)
            Text("Optional — the safe scan works without it.")
                .font(Brand.sans(12)).foregroundStyle(Brand.textTertiary)
                .padding(.top, 6)

            VStack(spacing: 10) {
                engineRow
                PermissionRow(
                    title: NSLocalizedString("Full Disk Access", comment: ""),
                    benefit: NSLocalizedString("Unlocks the caches and leftovers Burrow needs to reach.", comment: ""),
                    granted: fdaGranted,
                    onOpenSettings: { Privacy.openFullDiskAccessSettings() },
                    onCheck: {
                        fdaGranted = Privacy.hasFullDiskAccess()
                        if !fdaGranted { showRelaunchHint = true }
                    })
                if showRelaunchHint, !fdaGranted {
                    HStack(spacing: 6) {
                        Text("Granted in Settings but still gray? macOS applies it at the next launch.")
                            .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                        Button(NSLocalizedString("Relaunch to apply", comment: "")) { Privacy.relaunch() }
                            .buttonStyle(.plain)
                            .font(Brand.sans(11, .semibold)).foregroundStyle(Brand.green)
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: 520)
            .padding(.top, 26)
            Spacer(); Spacer()
        }
        .padding(.horizontal, 40)
        .overlay(alignment: .bottomTrailing) {
            PillButton(title: "Continue") {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { page = 1 }
            }
            .padding(24)
        }
        .task { await probeEngine() }
    }

    /// Engine status: confirms `mo` is installed and shows its version, so
    /// the user can see the one dependency Burrow drives is in place. (A
    /// truly missing engine is gated before onboarding by MoleInstallView;
    /// this row is the reassuring confirmation, with an install link as a
    /// belt-and-braces fallback.)
    private var engineRow: some View {
        HStack(spacing: 12) {
            Circle()
                .fill((engine?.installed ?? false) ? Brand.green
                      : (engine == nil ? Brand.ink.opacity(0.22) : Brand.amber))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 3) {
                Text(NSLocalizedString("Cleaning engine", comment: ""))
                    .font(Brand.sans(13, .semibold)).foregroundStyle(Brand.textPrimary)
                Text(engineSubtitle)
                    .font(Brand.sans(11)).foregroundStyle(Brand.textSecondary)
            }
            Spacer(minLength: 12)
            if let engine, engine.installed {
                Chip(text: engine.descriptor ?? NSLocalizedString("Installed", comment: ""),
                     color: Brand.green)
            } else if engine != nil {
                Button(NSLocalizedString("Install", comment: "")) {
                    NSWorkspace.shared.open(MoleCLI.repoURL)
                }
                .buttonStyle(.plain)
                .font(Brand.sans(11, .semibold)).foregroundStyle(Brand.amber)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.hairline, lineWidth: 1))
    }

    private var engineSubtitle: String {
        guard let engine else { return NSLocalizedString("Checking…", comment: "") }
        return engine.installed
            ? NSLocalizedString("Ready — Burrow drives it for every clean and scan.", comment: "")
            : NSLocalizedString("Not found. Install it to enable cleaning.", comment: "")
    }

    /// Probe off the main actor — `versionReport()` spawns `--version`.
    ///
    /// `installed` stays keyed to `findExecutable()` alone: a binary that is present but
    /// answers `--version` with an error is still installed, and this row's job is to
    /// reassure the user that the one dependency is there. It just shows the "Installed"
    /// chip with no number rather than claiming a version it could not read.
    private func probeEngine() async {
        let status: EngineStatus = await Task.detached(priority: .userInitiated) {
            guard MoleCLI.findExecutable() != nil else { return EngineStatus(installed: false, descriptor: nil) }
            return EngineStatus(installed: true, descriptor: MoleCLI.versionReport()?.display)
        }.value
        engine = status
    }

    // MARK: - Slide 2 · free & open source

    private var freeSlide: some View {
        VStack(spacing: 0) {
            Spacer()
            Text("Burrow is free.")
                .font(Brand.serif(28, .medium)).foregroundStyle(Brand.textPrimary)
            Text("Open source, local-first. No license, no trial, no upsell.")
                .font(Brand.sans(12)).foregroundStyle(Brand.textSecondary)
                .padding(.top, 6)

            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 22) {
                    VStack(spacing: 2) {
                        Text(verbatim: "$0")
                            .font(Brand.mono(44, .bold)).foregroundStyle(Brand.textPrimary)
                        Text("forever")
                            .font(Brand.serif(14)).italic().foregroundStyle(Brand.textSecondary)
                    }
                    .frame(minWidth: 130)
                    VStack(alignment: .leading, spacing: 9) {
                        featureLine(NSLocalizedString("Every tool unlocked — Clean, Purge, Installers, Software, Optimize, Analyze", comment: ""))
                        featureLine(NSLocalizedString("Watches your Mac over weeks, not seconds — 30–90 day history", comment: ""))
                        featureLine(NSLocalizedString("Agent-ready — MCP tools for Claude, Cursor, Codex (off until you opt in)", comment: ""))
                        HStack(spacing: 5) {
                            featureLine(NSLocalizedString("Open source — read every line", comment: ""))
                            Link(destination: URL(string: "https://github.com/caezium/Burrow")!) {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: Brand.scaled(10))).foregroundStyle(Brand.textTertiary)
                            }
                            .accessibilityLabel(NSLocalizedString("Open the Burrow repository on GitHub", comment: ""))
                        }
                    }
                }
                .padding(20)
            }
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Brand.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Brand.hairline, lineWidth: 1))
            .frame(maxWidth: 560)
            .padding(.top, 26)
            Spacer(); Spacer()
        }
        .padding(.horizontal, 40)
        .overlay(alignment: .bottomLeading) {
            Button(NSLocalizedString("Back", comment: "")) {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { page = 0 }
            }
            .buttonStyle(.plain)
            .font(Brand.sans(12, .semibold)).foregroundStyle(Brand.textSecondary)
            .padding(28)
        }
        .overlay(alignment: .bottomTrailing) {
            PillButton(title: "Start using Burrow") {
                onFinish()
            }
            .padding(24)
        }
    }

    // MARK: - Shared bits

    /// Burrow mark in a circular chip on a ring motif — the radial-gradient
    /// circle glyph style Analyze's sidebar uses, with the menu-bar mark inside.
    private var heroMark: some View {
        ZStack {
            Circle()
                .strokeBorder(Brand.hairline, lineWidth: 1)
                .frame(width: 124, height: 124)
            Circle()
                .fill(RadialGradient(colors: [Brand.cream.opacity(0.9), Brand.cream.opacity(0.12)],
                                     center: .init(x: 0.4, y: 0.35), startRadius: 2, endRadius: 64))
                .frame(width: 86, height: 86)
                .shadow(color: Brand.cream.opacity(0.35), radius: 26)
            Image(nsImage: BurrowIcons.menuBar)
                .renderingMode(.template)
                .resizable().frame(width: 34, height: 34)
                .foregroundStyle(Brand.espresso)
        }
        .accessibilityHidden(true)
    }

    private func featureLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: Brand.scaled(9), weight: .bold)).foregroundStyle(Brand.green)
                .padding(3)
                .background(Circle().fill(Brand.green.opacity(0.15)))
                .accessibilityHidden(true)
            Text(text)
                .font(Brand.sans(12)).foregroundStyle(Brand.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
