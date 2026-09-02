//
//  ShortcutRecorder.swift
//  Burrow / Components
//
//  The keyboard-shortcut recorder chip (Settings ▸ Menu Bar): click to
//  record, press a combo (≥ one of ⌃⌥⌘ — plain letters would shadow
//  typing), Esc cancels, × clears. No third-party deps — a local key
//  monitor while recording, Carbon registration via HotKeyCenter.
//

import SwiftUI
import AppKit

struct ShortcutRecorder: View {
    let action: HotKeyAction
    @State private var hotKey: HotKey?
    @State private var recording = false
    @State private var monitor: Any?

    init(action: HotKeyAction) {
        self.action = action
        _hotKey = State(initialValue: Store.shortcut(for: action))
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stopRecording() : startRecording()
            } label: {
                Text(chipLabel)
                    .font(Brand.mono(11, .medium))
                    .foregroundStyle(recording ? Brand.amber : Brand.textPrimary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .frame(minWidth: 86)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Brand.ink.opacity(recording ? 0.14 : 0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(recording ? Brand.amber.opacity(0.5) : Brand.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("Record shortcut", comment: ""))
            .accessibilityValue(hotKey?.display ?? NSLocalizedString("None", comment: ""))

            if hotKey != nil, !recording {
                Button {
                    set(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Brand.scaled(11))).foregroundStyle(Brand.textTertiary)
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("Clear shortcut", comment: ""))
                .accessibilityLabel(NSLocalizedString("Clear shortcut", comment: ""))
            }
        }
        .onDisappear { stopRecording() }
    }

    private var chipLabel: String {
        if recording { return NSLocalizedString("Press keys…", comment: "") }
        return hotKey?.display ?? NSLocalizedString("Record", comment: "")
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {   // Esc cancels
                stopRecording()
                return nil
            }
            let mods = HotKey.modifiers(from: event.modifierFlags)
            // Require a real chord: at least one of ⌃⌥⌘ so a recorded key
            // can't shadow ordinary typing system-wide.
            guard !mods.intersection([.control, .option, .command]).isEmpty else { return nil }
            set(HotKey(keyCode: UInt32(event.keyCode), modifiers: mods))
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        recording = false
    }

    private func set(_ hk: HotKey?) {
        hotKey = hk
        Store.setShortcut(hk, for: action)
        HotKeyCenter.shared.apply(hk, for: action)
    }
}
