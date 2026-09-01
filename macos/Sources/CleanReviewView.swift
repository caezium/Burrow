//
//  CleanReviewView.swift
//  Burrow
//
//  The "Ready to clean" review (design 1.4): every path the dry-run
//  enumerated, grouped into category cards with tri-state checkboxes,
//  per-item Safe / App open badges, select-all/none, a live total, and
//  the honest confirm pill. Unticked paths become a whitelist session —
//  the engine's safety rules stay authoritative; Burrow never deletes
//  cache paths itself (Trash mode recycles, reviewed paths only).
//
//  Esc returns to the result hero without losing the scan.
//

import SwiftUI
import AppKit

struct CleanReviewView: View {
    let list: CleanList
    let locked: [String: CleanSelection.LockReason]
    var accent: Color = Tool.clean.accent
    var onConfirm: (CleanSelection) -> Void
    var onExit: () -> Void

    @State private var selection: CleanSelection
    @State private var expanded: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(list: CleanList,
         locked: [String: CleanSelection.LockReason],
         accent: Color = Tool.clean.accent,
         onConfirm: @escaping (CleanSelection) -> Void,
         onExit: @escaping () -> Void) {
        self.list = list
        self.locked = locked
        self.accent = accent
        self.onConfirm = onConfirm
        self.onExit = onExit
        _selection = State(initialValue: CleanSelection(list: list, locked: locked))
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 22).padding(.top, 6).padding(.bottom, 12)
            Rectangle().fill(Brand.hairline).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 10) {
                    // Safest / most-regenerable categories first (PRD §Clean).
                    ForEach(CleanImpactRanker.sorted(list.categories.map { (category: $0.name, value: $0) })) { category in
                        categoryCard(category)
                    }
                }
                .padding(.horizontal, 22).padding(.vertical, 14)
                .padding(.bottom, 64)   // room for the floating pill
            }
            .scrollIndicators(.hidden)
        }
        .overlay(alignment: .bottom) { footer }
        .onExitCommand { onExit() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Ready to clean")
                    .font(Brand.serif(22, .medium)).foregroundStyle(Brand.textPrimary)
                if let lockedSummary = selection.lockedSummary {
                    Text(String(format: NSLocalizedString("Close %@ to clean another %@ · %d items", comment: "locked apps header"),
                                lockedSummary.appNames.joined(separator: ", "),
                                Fmt.bytes(lockedSummary.bytes), lockedSummary.itemCount))
                        .font(Brand.sans(11)).foregroundStyle(Brand.amber)
                } else {
                    Text("Everything below came from the scan — untick anything you'd rather keep.")
                        .font(Brand.sans(11)).foregroundStyle(Brand.textSecondary)
                }
            }
            Spacer()
            Button { onExit() } label: {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Brand.textSecondary)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("Back to results", comment: ""))
            .accessibilityLabel(NSLocalizedString("Back to results", comment: ""))
            iconButton("checkmark.circle", help: NSLocalizedString("Select all", comment: "")) {
                selection.selectAll()
            }
            iconButton("xmark.circle", help: NSLocalizedString("Deselect all", comment: "")) {
                selection.deselectAll()
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15))
                .foregroundStyle(Brand.textSecondary)
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: - Category card

    private func categoryCard(_ category: CleanList.Category) -> some View {
        let state = selection.categoryState(category.name)
        let isOpen = expanded.contains(category.name)
        return VStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    if isOpen { expanded.remove(category.name) } else { expanded.insert(category.name) }
                }
            } label: {
                HStack(spacing: 11) {
                    triStateBox(state) { selection.toggleCategory(category.name) }
                    Image(systemName: Self.glyph(for: category.name))
                        .font(.system(size: 13)).foregroundStyle(accent)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(NSLocalizedString(category.name, comment: "clean category"))
                                .font(Brand.sans(13, .semibold)).foregroundStyle(Brand.textPrimary)
                            Text(verbatim: "\(selection.selectedCount(in: category))/\(category.items.count) selected")
                                .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                        }
                        Text(Self.consequence(for: category.name))
                            .font(Brand.sans(10)).foregroundStyle(Brand.textSecondary)
                    }
                    Spacer()
                    Text(verbatim: "\(Fmt.bytes(selection.selectedBytes(in: category))) / \(Fmt.bytes(category.totalBytes))")
                        .font(Brand.mono(11, .medium)).foregroundStyle(Brand.blue)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Brand.textTertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(format: NSLocalizedString("%@, %d of %d selected, %@ of %@", comment: "category accessibility"),
                                       category.name,
                                       selection.selectedCount(in: category), category.items.count,
                                       Fmt.bytes(selection.selectedBytes(in: category)), Fmt.bytes(category.totalBytes)))
            .accessibilityAddTraits(.isButton)

            if isOpen {
                Rectangle().fill(Brand.hairline).frame(height: 1).padding(.horizontal, 13)
                VStack(spacing: 0) {
                    ForEach(category.items) { item in
                        itemRow(item)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.hairline, lineWidth: 1))
    }

    private func triStateBox(_ state: CleanSelection.CategoryState, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(state == .none ? Brand.chipFill : accent.opacity(0.9))
                    .frame(width: 17, height: 17)
                switch state {
                case .all:
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.black)
                case .mixed:
                    Image(systemName: "minus").font(.system(size: 9, weight: .bold)).foregroundStyle(.black)
                case .none:
                    EmptyView()
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Brand.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("Toggle category", comment: ""))
    }

    // MARK: - Item row

    private func itemRow(_ item: CleanList.Item) -> some View {
        let lockReason = locked[item.path]
        let ticked = selection.isTicked(item.path)
        return HStack(spacing: 10) {
            Button { selection.toggle(item.path) } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(ticked ? accent.opacity(0.9) : Brand.chipFill)
                        .frame(width: 15, height: 15)
                    if ticked {
                        Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.black)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Brand.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(lockReason != nil)
            .accessibilityLabel(item.displayName)
            .accessibilityValue(ticked ? NSLocalizedString("selected", comment: "") : NSLocalizedString("not selected", comment: ""))

            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .font(Brand.sans(12)).foregroundStyle(lockReason == nil ? Brand.textPrimary : Brand.textSecondary)
                    .lineLimit(1)
                Text(item.abbreviatedPath)
                    .font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if SensitiveRemnantMatcher.isSensitive(item.path) {
                Text(NSLocalizedString("sensitive", comment: ""))
                    .font(Brand.mono(9, .medium)).foregroundStyle(Brand.amber)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Capsule().fill(Brand.amber.opacity(0.16)))
                    .help(NSLocalizedString("Looks like a credential/keychain path — review before removing.", comment: ""))
            }
            badge(for: lockReason)
            if let count = item.itemCount {
                Text(String(format: NSLocalizedString("%d items", comment: ""), count))
                    .font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
            }
            Text(item.sizeText).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                .frame(minWidth: 56, alignment: .trailing)
            Button { AnalyzeIcons.reveal(item.path) } label: {
                Image(systemName: "magnifyingglass.circle")
                    .font(.system(size: 12)).foregroundStyle(Brand.textTertiary)
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("Reveal in Finder", comment: ""))
            .accessibilityLabel(NSLocalizedString("Reveal in Finder", comment: ""))
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
        .opacity(lockReason == nil ? 1 : 0.65)
        .contextMenu {
            Button(NSLocalizedString("Reveal in Finder", comment: "")) { AnalyzeIcons.reveal(item.path) }
            Button(NSLocalizedString("Always skip this", comment: "")) {
                try? MoleWhitelist.live.add(item.path)
                if selection.isTicked(item.path) { selection.toggle(item.path) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func badge(for reason: CleanSelection.LockReason?) -> some View {
        switch reason {
        case .none:
            Chip(text: NSLocalizedString("Safe", comment: "clean badge"), color: Brand.blue)
                .help(NSLocalizedString("The scan already excluded unsafe paths — everything here is removable cache data.", comment: ""))
        case .appOpen:
            Chip(text: NSLocalizedString("App open", comment: "clean badge"), color: Brand.amber)
                .help(NSLocalizedString("This app is running; its cache is locked. Quit the app and rescan to clean it.", comment: ""))
        case .systemBusy:
            Chip(text: NSLocalizedString("System busy", comment: "clean badge"), color: Brand.textTertiary)
                .help(NSLocalizedString("A system service is using this path right now.", comment: ""))
        case .notCleanable(let reason):
            Chip(text: NSLocalizedString("Can't clean", comment: "clean badge"), color: Brand.amber)
                .help(reason)
                // The reason only lives in the tooltip, which VoiceOver never
                // reaches — without this the row announces "Can't clean" and
                // gives no way to find out why.
                .accessibilityLabel(Text("\(NSLocalizedString("Can't clean", comment: "clean badge")). \(reason)"))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text(verbatim: "\(selection.selectedCount)/\(selection.totalCount) selected")
                .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
            Spacer()
            Button { onConfirm(selection) } label: {
                Text(pillLabel)
                    .font(Brand.sans(13, .semibold)).foregroundStyle(Brand.onInverse)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(Capsule().fill(Brand.inverse))
            }
            .buttonStyle(.plain)
            .disabled(selection.selectedCount == 0)
            .opacity(selection.selectedCount == 0 ? 0.5 : 1)
            .accessibilityLabel(pillLabel)
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
        .background(
            LinearGradient(colors: [Brand.nearBlack.opacity(0), Brand.nearBlack.opacity(0.85)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }

    /// Honest verb, live total. Permanent stays "Permanently clean";
    /// Trash mode says what it actually does.
    private var pillLabel: String {
        let total = Fmt.bytes(selection.selectedBytes)
        return Store.cacheRemovalMode == .trash
            ? String(format: NSLocalizedString("Move to Trash · %@", comment: "confirm pill"), total)
            : String(format: NSLocalizedString("Permanently clean · %@", comment: "confirm pill"), total)
    }

    // MARK: - Category chrome

    static func glyph(for category: String) -> String {
        switch category {
        case "User essentials":       return "person.crop.circle"
        case "App caches":            return "shippingbox"
        case "Browsers":              return "globe"
        case "Cloud & Office":        return "icloud"
        case "Developer tools":       return "hammer"
        case "AI Tools", "AI tools":  return "sparkles"
        case "Communication":         return "bubble.left.and.bubble.right"
        case "Applications":          return "app.badge"
        case "Virtualization":        return "server.rack"
        case "Application Support":   return "folder.badge.gearshape"
        case "App leftovers":         return "trash.slash"
        default:                      return "tray.full"
        }
    }

    /// One-line honest consequence per category — what removal costs.
    static func consequence(for category: String) -> String {
        switch category {
        case "User essentials":
            return NSLocalizedString("System-managed caches and logs. Regenerated as macOS needs them.", comment: "")
        case "App caches", "Applications", "Application Support":
            return NSLocalizedString("App temporary files. Regenerated next launch.", comment: "")
        case "Browsers":
            return NSLocalizedString("Page caches — sites load a touch slower on first visit.", comment: "")
        case "Developer tools":
            return NSLocalizedString("Build and package caches. First build will be slower.", comment: "")
        case "AI Tools", "AI tools":
            return NSLocalizedString("Model and tool caches. Re-downloaded on next use.", comment: "")
        case "Communication":
            return NSLocalizedString("Message media caches. Re-fetched when you scroll back.", comment: "")
        case "Virtualization":
            return NSLocalizedString("VM and container caches. Images re-pull on next run.", comment: "")
        case "Cloud & Office":
            return NSLocalizedString("Sync caches. Files re-sync from the cloud.", comment: "")
        case "App leftovers":
            return NSLocalizedString("Files from apps that are no longer installed.", comment: "")
        default:
            return NSLocalizedString("Cache files. Regenerated as needed.", comment: "")
        }
    }
}

extension CleanList.Item {
    /// Last path component — the human name of the row.
    var displayName: String { (path as NSString).lastPathComponent }

    /// Home-relative mono path ("~/.cache/uv").
    var abbreviatedPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
