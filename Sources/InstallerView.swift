//
//  InstallerView.swift
//  Burrow
//
//  The Installers tool — pick which leftover installer files to remove,
//  instead of the all-or-nothing `mo installer` run. Mole's `installer` is
//  an interactive TUI we can't drive over stdio, so Burrow scans the
//  standard download spots itself (InstallerFinder), shows a checklist like
//  the Uninstall tab, and moves only the chosen files to the Trash
//  (recoverable, no sudo).
//

import SwiftUI
import AppKit

struct InstallerView: View {
    @StateObject private var model = InstallerModel()
    var isActive: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            toolbar.padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 12)
            Rectangle().fill(Brand.hairline).frame(height: 1)
            content
            Rectangle().fill(Brand.hairline).frame(height: 1)
            bottomBar.padding(.horizontal, 18).padding(.vertical, 10)
        }
        .onAppear { if isActive { model.startIfNeeded() } }
        .onChange(of: isActive) { _, now in if now { model.startIfNeeded() } }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Installers").font(Brand.serif(18, .medium)).foregroundStyle(Brand.textPrimary)
            Text(model.summaryLine).font(Brand.mono(11)).foregroundStyle(Brand.textTertiary)
            Spacer()
            Button { model.refresh() } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
                    .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
            }.buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.loading {
            VStack { Spacer()
                ProgressView("Scanning for installers…").controlSize(.large)
                    .tint(Tool.installer.accent).font(Brand.mono(11))
                Spacer() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.items.isEmpty {
            VStack(spacing: 8) { Spacer()
                Image(systemName: "checkmark.seal").font(.system(size: 26)).foregroundStyle(Tool.installer.accent)
                Text("No leftover installers found.").font(Brand.sans(13)).foregroundStyle(Brand.textSecondary)
                Text("Checked Downloads, Desktop, and Documents for .dmg / .pkg / .iso / .xip.")
                    .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                Spacer() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.items) { item in
                        FindingRow(item: item, accent: Tool.installer.accent,
                                   selected: model.selected.contains(item.id)) { model.toggle(item.id) }
                        Rectangle().fill(Brand.hairline).frame(height: 1).padding(.leading, 58)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
            }
            .scrollIndicators(.visible)
        }
    }

    private var bottomBar: some View {
        HStack {
            Text(model.selectionLabel).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
            Spacer()
            if !model.items.isEmpty {
                Button { model.toggleAll() } label: {
                    Text(model.allSelected ? "select none" : "select all")
                        .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                }.buttonStyle(.plain).padding(.trailing, 8)
            }
            Button { model.confirmAndTrash() } label: {
                Text("Move to Trash\(model.selected.isEmpty ? "" : " (\(model.selected.count))")")
                    .font(Brand.sans(12, .semibold))
                    .foregroundStyle(model.selected.isEmpty ? Brand.textTertiary : .white)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(model.selected.isEmpty ? Color.white.opacity(0.06) : Tool.installer.accent))
            }
            .buttonStyle(.plain)
            .disabled(model.selected.isEmpty)
        }
    }
}

/// A selectable file row (icon, name, size · location, checkbox). Shared
/// shape with the Uninstall tab's AppRow.
struct FindingRow: View {
    let item: FileFinding
    let accent: Color
    let selected: Bool
    let onToggle: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                .resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(Brand.sans(13, .medium)).foregroundStyle(Brand.textPrimary).lineLimit(1)
                Text("\(Fmt.bytes(item.size)) · \(item.location)")
                    .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17)).foregroundStyle(selected ? accent : Brand.textTertiary)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(hover ? Brand.cardFillHover : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { onToggle() }
    }
}

@MainActor
final class InstallerModel: ObservableObject {
    @Published var items: [FileFinding] = []
    @Published var selected: Set<String> = []
    @Published var loading = false
    private var started = false

    var summaryLine: String {
        items.isEmpty ? "" : "\(items.count) found · \(Fmt.bytes(items.reduce(Int64(0)) { $0 + $1.size }))"
    }
    var selectionLabel: String {
        if selected.isEmpty { return items.isEmpty ? "Nothing to remove" : "\(items.count) installers" }
        let total = items.filter { selected.contains($0.id) }.reduce(Int64(0)) { $0 + $1.size }
        return "\(selected.count) selected · \(Fmt.bytes(total))"
    }
    var allSelected: Bool { !items.isEmpty && selected.count == items.count }

    func startIfNeeded() { guard !started else { return }; started = true; load() }
    func refresh() { load() }
    func toggle(_ id: String) { if selected.contains(id) { selected.remove(id) } else { selected.insert(id) } }
    func toggleAll() { selected = allSelected ? [] : Set(items.map { $0.id }) }

    func load() {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = InstallerFinder.scan()
            Task { @MainActor in
                self.items = found
                self.selected = self.selected.intersection(Set(found.map { $0.id }))   // drop stale
                self.loading = false
            }
        }
    }

    /// Confirm, then move the selected files to the Trash. User action only.
    func confirmAndTrash() {
        let targets = items.filter { selected.contains($0.id) }
        guard !targets.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Move \(targets.count) installer\(targets.count == 1 ? "" : "s") to the Trash?"
        alert.informativeText = "These move to the Trash (recoverable):\n\n"
            + targets.prefix(12).map { "• \($0.name)" }.joined(separator: "\n")
            + (targets.count > 12 ? "\n… and \(targets.count - 12) more" : "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let failed = CleanupTrasher.trash(targets.map { $0.path })
        if !failed.isEmpty {
            let f = NSAlert()
            f.messageText = "Couldn't remove \(failed.count) item\(failed.count == 1 ? "" : "s")"
            f.informativeText = "Some files couldn't be moved to the Trash (permission denied or in use)."
            f.runModal()
        }
        selected = []
        load()
    }
}
