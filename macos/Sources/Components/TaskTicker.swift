//
//  TaskTicker.swift
//  Burrow / Components
//
//  The live task ticker (design 2.5): during a streaming `mo` run, a
//  current-task line — "● <category> · 8" — over a fixed-height panel of
//  completed tasks. New completions append at the bottom and the list
//  slides up; the panel stays scrollable so earlier lines can be
//  reviewed (pin-to-bottom re-engages at the end). The ticker replaces
//  the *live* view only — the full TaskReport receipt still lands at
//  completion. Built as a component so Clean's real run can adopt it —
//  the marker grammar is the same.
//
//  No totals are invented: the engine doesn't announce a task count, so
//  the counter renders "· 8" with no denominator.
//

import SwiftUI

// MARK: - Stream → ticker state (pure, tested)

struct TaskTickerState: Equatable {
    struct Completion: Equatable {
        let marker: TaskMarker
        let text: String
    }
    var completed: [Completion] = []
    var currentCategory: String?
    var count: Int { completed.count }
}

enum TaskTicker {
    /// Same marker grammar as parseTaskReport: ➤ headers, →/✓/•/✗ items.
    static func reduce(_ lines: [String]) -> TaskTickerState {
        var state = TaskTickerState()
        let markerChars: Set<Character> = ["→", "➜", "✓", "✔", "•", "◎", "●", "✗", "✘", "✕", "ℹ", "☞"]
        for raw in lines {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("↳") { continue }
            if t.hasPrefix("➤") {
                state.currentCategory = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else if let first = t.first, markerChars.contains(first) {
                let text = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
                state.completed.append(.init(marker: TaskMarker(first), text: text))
            }
        }
        return state
    }
}

extension TaskMarker: Equatable {}

// MARK: - The view

struct TaskTickerView: View {
    let state: TaskTickerState
    let accent: Color
    var headline: String

    @State private var pulsing = false
    @State private var pinnedToBottom = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let visibleRows = 7

    var body: some View {
        VStack(spacing: 16) {
            Text(headline)
                .font(Brand.serif(20, .medium)).foregroundStyle(Brand.textPrimary)

            // ● <current task> · n
            HStack(spacing: 8) {
                Circle().fill(accent)
                    .frame(width: 7, height: 7)
                    .opacity(reduceMotion ? 1 : (pulsing ? 1 : 0.35))
                    .animation(reduceMotion ? nil
                               : .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                               value: pulsing)
                Text(TaskReportText.title(state.currentCategory ?? NSLocalizedString("Working…", comment: "")))
                    .font(Brand.sans(12, .semibold)).foregroundStyle(Brand.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Text(verbatim: "· \(state.count)")
                    .font(Brand.mono(11)).foregroundStyle(Brand.textTertiary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(format: NSLocalizedString("Working on %@, %d tasks done", comment: ""),
                                       state.currentCategory ?? "", state.count))

            // Fixed-height scrollable panel, pinned to bottom.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(state.completed.enumerated()), id: \.offset) { _, completion in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                markerGlyph(completion.marker)
                                Text(TaskReportText.item(completion.text))
                                    .font(Brand.mono(10)).foregroundStyle(Brand.textSecondary)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .transition(reduceMotion ? .opacity
                                        : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                      removal: .opacity))
                        }
                        Color.clear.frame(height: 1).id("TICKER_BOTTOM")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
                .scrollIndicators(.hidden)
                .frame(height: CGFloat(Self.visibleRows) * 19 + 20)
                .frame(maxWidth: 460)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Brand.insetFill))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Brand.hairline, lineWidth: 1))
                // Deferred past the current update transaction: a synchronous
                // scrollTo here mutates the scroll responder graph mid-way
                // through responder-preference combination, which can fault in
                // ScrollViewResponder.updateValue (Sentry BURROW-96,
                // EXC_BAD_ACCESS in AttributeGraph).
                .onChange(of: state.count) { _, _ in
                    guard pinnedToBottom else { return }
                    DispatchQueue.main.async {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            proxy.scrollTo("TICKER_BOTTOM", anchor: .bottom)
                        }
                    }
                }
            }
        }
        .onAppear { pulsing = true }
    }

    @ViewBuilder
    private func markerGlyph(_ marker: TaskMarker) -> some View {
        switch marker {
        case .error:
            Image(systemName: "xmark").font(.system(size: Brand.scaled(8), weight: .bold)).foregroundStyle(Brand.red)
        case .review:
            Image(systemName: "exclamationmark.circle").font(.system(size: Brand.scaled(8))).foregroundStyle(Brand.gold)
        default:
            Image(systemName: "checkmark").font(.system(size: Brand.scaled(8), weight: .bold)).foregroundStyle(Brand.green)
        }
    }
}
