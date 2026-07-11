//
//  TaskReport.swift
//  Burrow
//
//  Shared engine for the two "run a mo job and show the result" tabs —
//  Clean and Optimize. Both emit the same shape of human output:
//
//      ➤ Category
//        → did a thing, 191.3MB
//        ✓ nothing to do
//        • review-only item
//      Potential space: 383.8MB | Items: 372 | Categories: 20
//
//  OperationFlow streams a `mo` subcommand line-by-line; parseTaskReport
//  turns those lines into themed cards; ToolHero / HeroOrb / PillButton
//  are the shared idle-state chrome.
//

import SwiftUI
import AppKit

// MARK: - Parsed model

enum TaskMarker {
    case action, ok, review, error, info
    init(_ c: Character) {
        switch c {
        case "→", "➜":      self = .action
        case "✓", "✔":      self = .ok
        case "•", "◎", "●": self = .review
        case "✗", "✘", "✕": self = .error
        case "ℹ", "☞":      self = .info
        default:            self = .info
        }
    }
}

struct TaskItem: Identifiable {
    let id = UUID()
    let marker: TaskMarker
    let text: String
}

struct TaskGroup: Identifiable {
    let id = UUID()
    let title: String
    var items: [TaskItem]
}

struct TaskSummary {
    let space: String          // "383.8MB" — potential (dry-run) or tracked (real) cleanup size
    let items: String          // "372"
    let categories: String     // "20"
    var freeChange: String = "" // "+1.39GB" — real run only (disk freed)
    var freeNow: String = ""    // "2.50GB"  — real run only (free space after)

    /// One-line result the Clean done-banner AND a completion
    /// notification show: the real freed-space numbers when the engine
    /// printed them, the tracked-cleanup size otherwise.
    var completionLine: String {
        var parts: [String] = []
        if !freeChange.isEmpty { parts.append(String(format: NSLocalizedString("Freed %@", comment: ""), freeChange)) }
        else if !space.isEmpty { parts.append(String(format: NSLocalizedString("Cleaned %@", comment: ""), space)) }
        if !freeNow.isEmpty { parts.append(String(format: NSLocalizedString("%@ free now", comment: ""), freeNow)) }
        if !items.isEmpty { parts.append(String(format: NSLocalizedString("%@ items", comment: ""), items)) }
        return parts.isEmpty ? NSLocalizedString("Done", comment: "") : parts.joined(separator: " · ")
    }
}

enum TaskReportText {
    static func title(_ raw: String, bundle: Bundle = .main) -> String {
        localized(raw, bundle: bundle)
    }

    static func item(_ raw: String, bundle: Bundle = .main) -> String {
        dynamicItem(raw, bundle: bundle) ?? localized(raw, bundle: bundle)
    }

    static func line(_ raw: String, bundle: Bundle = .main) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard let first = t.first else { return raw }
        if first == "➤" {
            return title(String(t.dropFirst()).trimmingCharacters(in: .whitespaces), bundle: bundle)
        }
        let markerChars: Set<Character> = ["→", "➜", "✓", "✔", "•", "◎", "●", "✗", "✘", "✕", "ℹ", "☞"]
        if markerChars.contains(first) {
            return item(String(t.dropFirst()).trimmingCharacters(in: .whitespaces), bundle: bundle)
        }
        return localized(t, bundle: bundle)
    }

    private static func localized(_ key: String, bundle: Bundle) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    private static func dynamicItem(_ raw: String, bundle: Bundle) -> String? {
        if let checked = between(raw, prefix: "Login items all healthy (", suffix: " checked)") {
            return String(format: localized("Login items all healthy (%@ checked)", bundle: bundle), checked)
        }
        if let size = between(raw, prefix: "Knowledge database is healthy (", suffix: ")") {
            return String(format: localized("Knowledge database is healthy (%@)", bundle: bundle), size)
        }
        if let bottleneck = raw.stripPrefix("Likely bottleneck: ") {
            return String(format: localized("Likely bottleneck: %@", bundle: bundle), bottleneck)
        }
        if let dry = dryRunItem(raw, bundle: bundle) {
            return dry
        }
        return nil
    }

    private static func between(_ raw: String, prefix: String, suffix: String) -> String? {
        guard raw.hasPrefix(prefix), raw.hasSuffix(suffix) else { return nil }
        return String(raw.dropFirst(prefix.count).dropLast(suffix.count))
    }

    private static func dryRunItem(_ raw: String, bundle: Bundle) -> String? {
        if raw.hasSuffix(" dry"),
           let comma = raw.range(of: ", ", options: .backwards),
           let oldItems = raw.range(of: " old items", options: .backwards, range: raw.startIndex..<comma.lowerBound) {
            let nameAndCount = String(raw[..<oldItems.lowerBound])
            let size = String(raw[comma.upperBound...].dropLast(" dry".count))
            if let space = nameAndCount.range(of: " ", options: .backwards) {
                let name = String(nameAndCount[..<space.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: ", "))
                let count = String(nameAndCount[space.upperBound...])
                return String(format: localized("%@ %@ old items, %@ dry", bundle: bundle),
                              localized(name, bundle: bundle), count, size)
            }
        }
        if raw.hasSuffix(" dry"),
           let comma = raw.range(of: ", ", options: .backwards),
           let items = raw.range(of: " items", options: .backwards, range: raw.startIndex..<comma.lowerBound) {
            let nameAndCount = String(raw[..<items.lowerBound])
            let size = String(raw[comma.upperBound...].dropLast(" dry".count))
            if let space = nameAndCount.range(of: " ", options: .backwards) {
                let name = String(nameAndCount[..<space.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: ", "))
                let count = String(nameAndCount[space.upperBound...])
                return String(format: localized("%@ %@ items, %@ dry", bundle: bundle),
                              localized(name, bundle: bundle), count, size)
            }
        }
        if raw.hasSuffix(" dry"),
           let comma = raw.range(of: ", ", options: .backwards) {
            let name = String(raw[..<comma.lowerBound]).trimmingCharacters(in: .whitespaces)
            let size = String(raw[comma.upperBound...].dropLast(" dry".count))
            return String(format: localized("%@, %@ dry", bundle: bundle),
                          localized(name, bundle: bundle), size)
        }
        return nil
    }
}

private extension String {
    func stripPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

func parseTaskReport(_ lines: [String]) -> (groups: [TaskGroup], summary: TaskSummary?) {
    var groups: [TaskGroup] = []
    let markerChars: Set<Character> = ["→", "➜", "✓", "✔", "•", "◎", "●", "✗", "✘", "✕", "ℹ", "☞"]

    // Summary fields accumulate across lines: the dry-run preview packs
    // them onto one "Potential space:" line, but the real run spreads
    // "Tracked cleanup:", "Free space change:" and "Free space now:" over
    // three separate lines.
    var space = "", items = "", cats = "", freeChange = "", freeNow = ""
    var sawSummary = false

    for raw in lines {
        // The engine styles its report (sizes in red, headers bold); strip ANSI here — the
        // single parse chokepoint — so no consumer ever renders literal "[0;31m…" (#257).
        let t = Ansi.strip(raw).trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasPrefix("↳") { continue }

        if t.hasPrefix("➤") {
            let title = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
            groups.append(TaskGroup(title: title, items: []))
        } else if let first = t.first, markerChars.contains(first) {
            let text = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
            if groups.isEmpty { groups.append(TaskGroup(title: "Summary", items: [])) }
            groups[groups.count - 1].items.append(TaskItem(marker: TaskMarker(first), text: text))
        } else if mergeSummaryFields(line: t, space: &space, items: &items, categories: &cats,
                                     freeChange: &freeChange, freeNow: &freeNow) {
            sawSummary = true
        } else if t == t.uppercased(), t.count > 4, t.count < 40, !t.contains(":"), !t.contains("|") {
            groups.append(TaskGroup(title: t.capitalized, items: []))
        }
    }
    let summary = sawSummary
        ? TaskSummary(space: space, items: items, categories: cats,
                      freeChange: freeChange, freeNow: freeNow)
        : nil
    return (groups.filter { !$0.items.isEmpty }, summary)
}

/// Recognise a summary line from either the dry-run preview ("Potential
/// space: … | Items: … | Categories: …") or the real run's footer
/// ("Tracked cleanup: …", "Free space change: …", "Free space now: …")
/// and merge its fields into the accumulators. Returns whether the line
/// was a summary line, so the caller stops matching other shapes for it.
private func mergeSummaryFields(line: String,
                                space: inout String, items: inout String,
                                categories: inout String,
                                freeChange: inout String, freeNow: inout String) -> Bool {
    let lower = line.lowercased()
    guard lower.contains("potential space") || lower.contains("tracked cleanup")
       || lower.contains("free space change") || lower.contains("free space now") else {
        return false
    }
    for part in line.components(separatedBy: "|") {
        let kv = part.components(separatedBy: ":")
        guard kv.count >= 2 else { continue }
        let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
        let val = kv[1...].joined(separator: ":").trimmingCharacters(in: .whitespaces)
        if key.contains("potential space") || key.contains("tracked cleanup") { space = val }
        else if key.contains("free space change") { freeChange = val }
        else if key.contains("free space now") { freeNow = val }
        else if key.contains("item") { items = val }
        else if key.contains("categor") { categories = val }
    }
    return true
}

// MARK: - Report view

struct TaskReportView: View {
    let groups: [TaskGroup]
    let accent: Color

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        GlassCard {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(TaskReportText.title(group.title).uppercased())
                                    .font(Brand.mono(10, .bold)).tracking(0.7)
                                    .foregroundStyle(accent)
                                ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        marker(item.marker)
                                        Text(TaskReportText.item(item.text))
                                            .font(Brand.sans(12))
                                            .foregroundStyle(textColor(item.marker))
                                            .fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 0)
                                    }
                                }
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("BOTTOM")
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            // Tail-follow the report as new lines stream in.
            .onChange(of: itemCount) { _, _ in
                withAnimation(.linear(duration: 0.15)) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
            }
        }
    }

    private var itemCount: Int { groups.reduce(0) { $0 + $1.items.count } }

    @ViewBuilder
    private func marker(_ m: TaskMarker) -> some View {
        switch m {
        case .action: Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(accent)
        case .ok:     Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Brand.green)
        case .review: Image(systemName: "exclamationmark.circle.fill").font(.system(size: 9)).foregroundStyle(Brand.gold)
        case .error:  Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Brand.red)
        case .info:   Image(systemName: "minus").font(.system(size: 9, weight: .bold)).foregroundStyle(Brand.textTertiary)
        }
    }
    private func textColor(_ m: TaskMarker) -> Color {
        switch m {
        case .ok, .info: return Brand.textSecondary
        default:         return Brand.textPrimary
        }
    }
}

// MARK: - Shared idle chrome

struct HeroOrb: View {
    let accent: Color
    var size: CGFloat = 150
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(
                colors: [accent.opacity(0.85), accent.opacity(0.12)],
                center: .init(x: 0.4, y: 0.35), startRadius: 4, endRadius: size * 0.85))
            Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        }
        .frame(width: size, height: size)
        .shadow(color: accent.opacity(0.35), radius: 40)
    }
}

struct PillButton: View {
    let title: String
    var filled: Bool = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(NSLocalizedString(title, comment: ""))
                .font(Brand.sans(13, .semibold))
                .foregroundStyle(filled ? Color.black : Brand.textPrimary)
                .padding(.horizontal, 22).padding(.vertical, 10)
                .background(Capsule().fill(filled ? Color.white : Color.white.opacity(0.08)))
                .overlay(filled ? nil : Capsule().strokeBorder(Brand.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct ToolHero<Buttons: View>: View {
    let tool: Tool
    let title: String
    let subtitle: String
    @ViewBuilder var buttons: () -> Buttons
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            HeroOrb(accent: tool.accent)
            VStack(spacing: 8) {
                Text(NSLocalizedString(title, comment: "")).font(Brand.serif(28, .medium)).foregroundStyle(Brand.textPrimary)
                Text(NSLocalizedString(subtitle, comment: "")).font(Brand.serif(15)).italic().foregroundStyle(Brand.textSecondary)
            }
            HStack(spacing: 12) { buttons() }.padding(.top, 4)
            Spacer(); Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The raw streamed transcript, demoted below the structured result —
/// collapsed by default so the report (not a wall of terminal text) is the
/// headline, expandable when someone wants the full log. Shared by every
/// result screen (Clean / Optimize / Purge / Installer).
struct ViewLogDisclosure: View {
    let log: String
    var accent: Color = Brand.textSecondary
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !log.isEmpty {
            VStack(spacing: 0) {
                Rectangle().fill(Brand.hairline).frame(height: 1)
                Button {
                    if reduceMotion { expanded.toggle() }
                    else { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text("View Log").font(Brand.mono(11))
                        Spacer()
                    }
                    .foregroundStyle(Brand.textSecondary)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("View Log", comment: ""))
                .accessibilityValue(expanded ? NSLocalizedString("expanded", comment: "")
                                             : NSLocalizedString("collapsed", comment: ""))
                if expanded {
                    ScrollView {
                        Text(log)
                            .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18).padding(.bottom, 12)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 240)
                    .scrollIndicators(.hidden)
                }
            }
        }
    }
}

/// Success header shown above a finished Clean / Optimize report.
struct DoneBanner: View {
    let accent: Color
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(accent.opacity(0.18)).frame(width: 38, height: 38)
                Image(systemName: "checkmark").font(.system(size: 16, weight: .bold)).foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString(title, comment: "")).font(Brand.sans(15, .semibold)).foregroundStyle(Brand.textPrimary)
                if let d = detail { Text(d).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary) }
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(accent.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(accent.opacity(0.35), lineWidth: 1))
        .padding(.horizontal, 18).padding(.top, 8)
    }
}
