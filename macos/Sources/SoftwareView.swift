//
//  SoftwareView.swift
//  Burrow
//
//  The Software tab, three segments (design 2.2 / 2.3 / 2.4):
//
//    Uninstall — installed apps from `mo uninstall --list`, sort chips
//      with direction carets, and an expandable leftover review per
//      app: `mo uninstall --dry-run` enumerates the paths, classified
//      into "Auto selected" (Application / App Support / Preferences /
//      containers / helpers / login items) and "Needs review" (caches,
//      logs, group containers), each individually tickable.
//      Removal is two-path: every enumerated item ticked (or never
//      reviewed) → the engine's own `mo uninstall` (history stays in
//      `mo history`); a subset → Burrow trashes exactly the reviewed,
//      ticked paths (Trash semantics, logged in Burrow's Activity
//      instead — the trade-off the review header states).
//      SCOPE, on the whole-app path: the `.app` bundle AND the per-app
//      support files under ~/Library. The bundle is entry 0 of the
//      dry run and goes to the Trash with everything else, except for
//      a Homebrew cask, which `brew uninstall --cask --zap` removes
//      without the Trash and with an unbounded zap stanza —
//      `confirmCopy` is where both are said to the user before consent,
//      and `UninstallGuard` confirms the engine resolved exactly the
//      confirmed set before anything is removed.
//
//    Updates — unified list with per-source badges (UpdatesView).
//
//    Startup — launch agents/daemons inventory, read-only with reveal
//      (StartupInventory).
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct InstalledApp: Identifiable, Equatable {
    let id: String
    let name: String
    let bundleId: String
    let source: String
    let uninstallName: String
    let path: String
    let sizeStr: String
    let sizeBytes: Int64
    let lastUsed: Date?
}

enum AppSort: String, CaseIterable {
    case name = "Name", size = "Size", recent = "Last Used"
    var label: String { NSLocalizedString(rawValue, comment: "") }
}

enum SoftwareSegment { case uninstall, updates, startup, services }

struct SoftwareView: View {
    @StateObject private var model = SoftwareModel()
    @StateObject private var updates = UpdatesModel()
    @StateObject private var startup = StartupModel()
    @StateObject private var services = BrewServicesModel()
    var isActive: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            toolbar.padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 12)
            Rectangle().fill(Brand.hairline).frame(height: 1)
            content
            if model.segment == .uninstall {
                Rectangle().fill(Brand.hairline).frame(height: 1)
                bottomBar.padding(.horizontal, 18).padding(.vertical, 10)
            }
        }
        // Pre-warm both LOCAL segments when the pane opens, so switching to
        // Startup is instant instead of a fresh scan-on-click. Updates is left
        // out on purpose — it reaches out to Apple / vendor appcasts, so it
        // stays gated behind an explicit check (privacy).
        .onAppear { if isActive { model.startIfNeeded(); startup.startIfNeeded() } }
        .onChange(of: isActive) { _, now in if now { model.startIfNeeded(); startup.startIfNeeded() } }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            segmented
            Spacer()
            if model.segment == .uninstall {
                sortChips
                Button { model.load() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Brand.textSecondary)
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("Refresh", comment: ""))
                .accessibilityLabel(NSLocalizedString("Refresh", comment: ""))
                searchField
            } else if model.segment == .startup {
                startupFilter
                Button { startup.reload() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Brand.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("Refresh", comment: ""))
                startupSearch
            }
        }
    }

    /// Sort chips with direction carets — Name ⇅ · Size ⇅ · Last Used ⇅.
    /// Tapping the active chip flips direction.
    private var sortChips: some View {
        HStack(spacing: 4) {
            ForEach(AppSort.allCases, id: \.self) { s in
                let active = model.sort == s
                Button { model.setSort(s) } label: {
                    HStack(spacing: 3) {
                        Text(s.label.lowercased()).font(Brand.mono(11, active ? .semibold : .regular))
                        Image(systemName: active
                              ? (model.sortAscending ? "chevron.up" : "chevron.down")
                              : "chevron.up.chevron.down")
                            .font(.system(size: active ? 7 : 8, weight: .semibold))
                    }
                    .foregroundStyle(active ? Tool.apps.accent : Brand.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background { if active { Capsule().fill(Tool.apps.accent.opacity(0.12)) } }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(format: NSLocalizedString("Sort by %@", comment: ""), s.label))
                .accessibilityValue(active
                    ? (model.sortAscending ? NSLocalizedString("ascending", comment: "") : NSLocalizedString("descending", comment: ""))
                    : "")
            }
        }
    }

    private var segmented: some View {
        HStack(spacing: 2) {
            seg("Uninstall", .uninstall)
            seg("Updates", .updates)
            seg("Startup", .startup)
            if BrewClient.isInstalled { seg("Services", .services) }
        }
        .padding(3)
        .background(Capsule().fill(Brand.insetFill))
        .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 1))
    }

    private func seg(_ title: String, _ value: SoftwareSegment) -> some View {
        let on = model.segment == value
        return Button { model.segment = value } label: {
            Text(NSLocalizedString(title, comment: "")).font(Brand.mono(11, on ? .semibold : .regular))
                .foregroundStyle(on ? Brand.onInverse : Brand.textSecondary)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background { if on { Capsule().fill(Brand.inverse) } }
                .contentShape(Capsule())
        }.buttonStyle(.plain)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Brand.textTertiary)
            TextField("Search apps", text: $model.query)
                .textFieldStyle(.plain).font(Brand.sans(12)).frame(width: 130)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Capsule().fill(Brand.insetFill))
        .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 1))
    }

    private var startupFilter: some View {
        Picker("", selection: $startup.filter) {
            Text(NSLocalizedString("All", comment: "")).tag(StartupModel.Filter.all)
            Text(NSLocalizedString("Launch agents", comment: "")).tag(StartupModel.Filter.agents)
            Text(NSLocalizedString("Launch daemons", comment: "")).tag(StartupModel.Filter.daemons)
            Text(NSLocalizedString("Problems", comment: "")).tag(StartupModel.Filter.problems)
        }
        .labelsHidden().pickerStyle(.menu).tint(Brand.textSecondary).fixedSize()
    }

    private var startupSearch: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Brand.textTertiary)
            TextField("Search items", text: $startup.query)
                .textFieldStyle(.plain).font(Brand.sans(12)).frame(width: 130)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Capsule().fill(Brand.insetFill))
        .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 1))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.segment {
        case .updates:
            UpdatesView(model: updates, apps: model.apps)
        case .startup:
            StartupView(model: startup)
        case .services:
            BrewServicesView(model: services)
        case .uninstall:
            if model.loading {
                VStack { Spacer(); ProgressView("Reading installed apps…").controlSize(.large).tint(Tool.apps.accent)
                    .font(Brand.mono(11)); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.apps.isEmpty {
                // `MoleClient.listAppsResult()` is what makes these two cases distinguishable —
                // an empty ARRAY used to mean either "the lookup failed" or "genuinely zero
                // apps" with no way to tell them apart, so this used to always render the
                // failure copy below as a blanket guess. Say the true one plainly instead of
                // rendering a silent blank list either way.
                if model.inventoryUnavailable {
                    // This used to be the ONLY case that happened, because the bundled engine had
                    // no `--list` at all. It implements one now (135 rows on the machine this was
                    // verified on), so reaching this state means a real failure worth showing.
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "questionmark.app.dashed")
                            .font(.system(size: 26)).foregroundStyle(Brand.textTertiary)
                        Text("App inventory isn't available")
                            .font(Brand.sans(13, .semibold)).foregroundStyle(Brand.textPrimary)
                        Text("Burrow couldn't list installed apps this time. You can still uninstall from Finder in the meantime.")
                            .font(Brand.sans(11)).foregroundStyle(Brand.textSecondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 320)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // The lookup genuinely ran and found nothing — rare (a fresh or minimal
                    // account), and a materially different claim from the failure above, so it
                    // gets its own copy rather than reusing it.
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 26)).foregroundStyle(Brand.textTertiary)
                        Text("No apps found")
                            .font(Brand.sans(13, .semibold)).foregroundStyle(Brand.textPrimary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.filtered) { app in
                            AppRow(app: app,
                                   selected: model.selected.contains(app.id),
                                   expanded: model.expandedAppID == app.id,
                                   preview: model.previews[app.id],
                                   previewLoading: model.previewLoading.contains(app.id),
                                   pathSelection: model.pathSelectionBinding(app.id),
                                   onToggle: { model.toggle(app.id) },
                                   onExpand: { model.toggleExpansion(app) })
                            Rectangle().fill(Brand.hairline).frame(height: 1).padding(.leading, 58)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                }
                .scrollIndicators(.visible)
            }
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if !model.selected.isEmpty {
                HStack(spacing: -6) {
                    ForEach(model.selectedApps.prefix(3), id: \.id) { app in
                        Image(nsImage: SoftwareIcons.icon(app.path))
                            .resizable().frame(width: 20, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                }
                .accessibilityHidden(true)
            }
            Text(model.selectionLabel).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
            Spacer()
            if !model.selected.isEmpty {
                Button { model.selected = [] } label: {
                    Text("Deselect all").font(Brand.sans(11, .semibold)).foregroundStyle(Brand.red)
                }
                .buttonStyle(.plain)
            }
            Button {
                model.confirmAndUninstall()
            } label: {
                Text(model.uninstallButtonTitle)
                    .font(Brand.sans(12, .semibold))
                    .foregroundStyle(model.selected.isEmpty ? Brand.textTertiary : Brand.onInverse)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Capsule().fill(model.selected.isEmpty ? Brand.chipFill : Brand.inverse))
            }
            .buttonStyle(.plain)
            .disabled(model.selected.isEmpty)
        }
    }
}

// MARK: - App row (with expandable leftover review)

struct AppRow: View {
    let app: InstalledApp
    let selected: Bool
    let expanded: Bool
    let preview: UninstallPreview?
    let previewLoading: Bool
    @Binding var pathSelection: Set<String>
    let onToggle: () -> Void
    let onExpand: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(Brand.textTertiary)
                    .frame(width: 12)
                Image(nsImage: SoftwareIcons.icon(app.path)).resizable().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(Brand.sans(13, .medium)).foregroundStyle(Brand.textPrimary).lineLimit(1)
                    Text(versionLine)
                        .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let preview, !preview.isEmpty {
                    Text(String(format: NSLocalizedString("%d files · %@", comment: "leftover summary"),
                                preview.entries.count, preview.totalText ?? app.sizeStr))
                        .font(Brand.mono(10)).foregroundStyle(Brand.textSecondary)
                } else {
                    Text(app.sizeStr).font(Brand.mono(10)).foregroundStyle(Brand.textSecondary)
                }
                Button(action: onToggle) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17))
                        .foregroundStyle(selected ? Tool.apps.accent : Brand.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(format: NSLocalizedString("Select %@", comment: ""), app.name))
                .accessibilityValue(selected ? NSLocalizedString("selected", comment: "") : NSLocalizedString("not selected", comment: ""))
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(hover ? Brand.cardFillHover : Color.clear)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { onExpand() }

            if expanded {
                expansion
                    .padding(.leading, 22).padding(.trailing, 10).padding(.bottom, 10)
            }
        }
    }

    private var versionLine: String {
        var parts: [String] = []
        if let v = SoftwareIcons.version(app.path) { parts.append("v\(v)") }
        parts.append(app.source)
        parts.append(prettyPath)
        return parts.joined(separator: " · ")
    }

    // MARK: Expanded leftover breakdown

    @ViewBuilder
    private var expansion: some View {
        if previewLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Enumerating files…").font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
            }
            .padding(10)
        } else if let preview, !preview.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                // Header: name + mono bundle path · k/n selected · clear-data · select all
                HStack {
                    // "Clear Data" = every leftover except the .app bundle. Shown only
                    // when there's a bundle to exclude, so it's always a true subset
                    // (kept app, removed data) routed through the native-trash path.
                    let tickable = preview.entries.filter { preview.handRemovalRefusals[$0.path] == nil }
                    let dataPaths = UninstallPlan.dataOnly(paths: tickable.map(\.path))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name).font(Brand.sans(12, .semibold)).foregroundStyle(Brand.textPrimary)
                        Text(prettyPath).font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Text(verbatim: "\(pathSelection.count)/\(tickable.count) selected")
                        .font(Brand.mono(10)).foregroundStyle(Brand.textSecondary)
                    if dataPaths.count < tickable.count {
                        Button(NSLocalizedString("Clear Data", comment: "")) {
                            pathSelection = Set(dataPaths)
                        }
                        .buttonStyle(.plain).font(Brand.sans(10, .semibold)).foregroundStyle(Tool.apps.accent)
                        .help(NSLocalizedString("Select everything except the app itself — removes its data but keeps the app installed.", comment: ""))
                    }
                    Button(NSLocalizedString("Select all", comment: "")) {
                        pathSelection = Set(tickable.map(\.path))
                    }
                    .buttonStyle(.plain).font(Brand.sans(10, .semibold)).foregroundStyle(Tool.apps.accent)
                }

                let auto = preview.entries.filter(\.kind.autoSelected)
                let review = preview.entries.filter { !$0.kind.autoSelected }
                if !auto.isEmpty {
                    groupHeader(NSLocalizedString("Auto selected", comment: ""), entries: auto)
                    ForEach(auto) { entryRow($0) }
                }
                if !review.isEmpty {
                    groupHeader(NSLocalizedString("Needs review", comment: ""), entries: review)
                    Text("Not selected by default. Review these before removing.")
                        .font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                    ForEach(review) { entryRow($0) }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Brand.insetFill))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Brand.hairline, lineWidth: 1))
        } else if preview != nil {
            // Still says nothing about what Remove will then do, for the one reason that survived
            // the engine gaining bundle removal: a row Burrow can't name to the engine at all is
            // skipped rather than run, so promising anything here would be a promise about a run
            // that may not include this app. The confirm sheet states the scope per app at the
            // moment it matters — before consent.
            Text("Couldn't enumerate this app's files — there's nothing to review here.")
                .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                .padding(10)
        }
    }

    private func groupHeader(_ title: String, entries: [UninstallPreview.Entry]) -> some View {
        // "All of them" means all the ones Burrow may actually remove. Counting a locked row in
        // the denominator would leave the group toggle permanently stuck on "some selected".
        let tickable = entries.filter { preview?.handRemovalRefusals[$0.path] == nil }
        let selectedCount = tickable.filter { pathSelection.contains($0.path) }.count
        let allSelected = !tickable.isEmpty && selectedCount == tickable.count
        return HStack(spacing: 8) {
            Button {
                let paths = tickable.map(\.path)
                if allSelected {
                    pathSelection.subtract(paths)
                } else {
                    pathSelection.formUnion(paths)
                }
            } label: {
                Image(systemName: allSelected ? "checkmark.square.fill"
                      : (selectedCount == 0 ? "square" : "minus.square.fill"))
                    .font(.system(size: 12))
                    .foregroundStyle(selectedCount == 0 ? Brand.textTertiary : Tool.apps.accent)
            }
            .buttonStyle(.plain)
            .disabled(tickable.isEmpty)
            .accessibilityLabel(String(format: NSLocalizedString("Toggle %@ group", comment: ""), title))
            Text(title.uppercased()).font(Brand.mono(9, .bold)).tracking(0.6).foregroundStyle(Brand.textTertiary)
            Text(verbatim: "\(selectedCount)/\(tickable.count)")
                .font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
            Spacer()
        }
        .padding(.top, 2)
    }

    private func entryRow(_ entry: UninstallPreview.Entry) -> some View {
        // The engine's verdict for this exact path, when it has one. A refused bundle and a
        // Homebrew cask's `.app` are shown — they ARE in scope for the run — but Burrow will not
        // hand-trash either, so the tick is not offered rather than offered and then failing
        // closed somewhere the user can't see.
        let refusal = preview?.handRemovalRefusals[entry.path]
        let ticked = pathSelection.contains(entry.path)
        return HStack(spacing: 9) {
            Button {
                guard refusal == nil else { return }
                if ticked { pathSelection.remove(entry.path) } else { pathSelection.insert(entry.path) }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(ticked ? Tool.apps.accent.opacity(0.9) : Brand.chipFill)
                        .frame(width: 14, height: 14)
                    if refusal != nil {
                        Image(systemName: "lock.fill").font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Brand.textTertiary)
                    } else if ticked {
                        Image(systemName: "checkmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.black)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Brand.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(refusal != nil)
            .accessibilityLabel(entry.path)
            .accessibilityValue(refusal ?? (ticked ? NSLocalizedString("selected", comment: "")
                                                   : NSLocalizedString("not selected", comment: "")))

            Text(entry.kind.label).font(Brand.sans(10, .medium)).foregroundStyle(Brand.textSecondary)
                .frame(width: 96, alignment: .leading)
            Text(entry.path).font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                .lineLimit(1).truncationMode(.middle)
            if let refusal {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 9)).foregroundStyle(Brand.gold)
                    .help(refusal)
                    .accessibilityLabel(refusal)
            }
            if UninstallPlan.isInputMethod(entry.path) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9)).foregroundStyle(Brand.gold)
                    .help(NSLocalizedString("Input method — removing this can disable typing for its language until you log out.", comment: ""))
            }
            Spacer()
            Button { AnalyzeIcons.reveal(entry.expandedPath) } label: {
                Image(systemName: "magnifyingglass.circle").font(.system(size: 11)).foregroundStyle(Brand.textTertiary)
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("Reveal in Finder", comment: ""))
            .accessibilityLabel(NSLocalizedString("Reveal in Finder", comment: ""))
        }
    }

    private var prettyPath: String {
        app.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

enum SoftwareIcons {
    private static let lock = NSLock()
    private static var cache: [String: NSImage] = [:]
    private static var versions: [String: String?] = [:]
    private static let resolveQueue = DispatchQueue(label: "dev.caezium.burrow.softwareicons", qos: .utility)
    /// Generic app-bundle icon shown for the brief window before an off-main
    /// resolve fills the cache (the normal flow pre-warms, so this is rare).
    private static let placeholder = NSWorkspace.shared.icon(for: .applicationBundle)

    /// Icon for an app bundle. MAIN-SAFE: returns the cached icon, or a generic
    /// placeholder while an off-main resolve fills the cache (the row picks up
    /// the real icon on a later redraw). `NSWorkspace.icon(forFile:)` reads the
    /// bundle, so calling it per row during layout stalled the app list on its
    /// first paint (Sentry BURROW-20) — that read now happens off the main
    /// thread, pre-warmed by `prewarm(_:)` from the off-main app fetch.
    static func icon(_ path: String) -> NSImage {
        lock.lock()
        let cached = cache[path]
        lock.unlock()
        if let cached { return cached }
        resolveQueue.async { resolve([path]) }
        return placeholder
    }

    /// CFBundleShortVersionString. MAIN-SAFE: the cached value, or nil while an
    /// off-main resolve runs (nil is cached too — most reads repeat). Reading
    /// Info.plist is disk I/O, so it never runs on the calling thread.
    static func version(_ path: String) -> String? {
        lock.lock()
        let cached = versions[path]
        lock.unlock()
        if let cached { return cached }
        resolveQueue.async { resolve([path]) }
        return nil
    }

    /// Resolve icons + versions for a set of apps, filling the shared cache.
    /// Call from an OFF-MAIN context (the app fetch) so the rows then render
    /// from pure cache reads instead of reading the disk during layout.
    static func prewarm(_ apps: [InstalledApp]) {
        resolve(apps.map(\.path))
    }

    /// MUST run off the main thread (disk I/O per path).
    private static func resolve(_ paths: [String]) {
        for path in paths {
            lock.lock()
            let needIcon = cache[path] == nil
            let needVersion = versions[path] == nil
            lock.unlock()
            if !needIcon && !needVersion { continue }

            let img = needIcon ? NSWorkspace.shared.icon(forFile: path) : nil
            var version: String?
            if needVersion {
                let plist = (path as NSString).appendingPathComponent("Contents/Info.plist")
                version = NSDictionary(contentsOfFile: plist)?["CFBundleShortVersionString"] as? String
            }

            lock.lock()
            if let img { cache[path] = img }
            if needVersion { versions[path] = version }
            lock.unlock()
        }
    }
}

// MARK: - Model

@MainActor
final class SoftwareModel: ObservableObject {
    @Published var apps: [InstalledApp] = [] { didSet { rebuildLoweredNames() } }
    @Published var loading = false
    @Published var error: String?
    /// True when the last `load()` came back empty BECAUSE `mo uninstall --list` failed, as
    /// opposed to a genuinely empty result. `apps.isEmpty` alone can't tell those apart — see
    /// `MoleClient.ListAppsResult` and the empty-state branch in `content` above, which is the
    /// only reader.
    @Published var inventoryUnavailable = false
    @Published var query = ""
    @Published var sort: AppSort = .size
    @Published var sortAscending = false
    @Published var selected: Set<String> = []
    @Published var segment: SoftwareSegment = .uninstall
    // Leftover review state (2.2)
    @Published var expandedAppID: String?
    @Published var previews: [String: UninstallPreview] = [:]
    @Published var previewLoading: Set<String> = []
    @Published var pathSelections: [String: Set<String>] = [:]
    private var started = false
    private let appsLoader: () -> (apps: [InstalledApp], unavailable: Bool)
    private let recentDateLoader: (String) -> Date?
    private let previewLoader: (InstalledApp) -> UninstallPreview
    private var loadGeneration = 0
    private var recentGeneration = 0

    /// `loadApps` hands back rows only: a test that can produce a list has, by construction, a
    /// working inventory, so the "couldn't check" half of `fetch()`'s answer is false for it.
    /// `loadPreview` takes the whole row rather than a name because the real loader
    /// (`fetchPreview`) chooses between the engine's bundle-id argv and the legacy name argv.
    init(
        loadApps: (() -> [InstalledApp])? = nil,
        lastUsedDate: ((String) -> Date?)? = nil,
        loadPreview: ((InstalledApp) -> UninstallPreview)? = nil
    ) {
        appsLoader = loadApps.map { load in { (apps: load(), unavailable: false) } } ?? { Self.fetch() }
        recentDateLoader = lastUsedDate ?? { Self.lastUsedDate($0) }
        previewLoader = loadPreview ?? { Self.fetchPreview(for: $0) }
    }

    /// `id` → lowercased name, rebuilt once per `apps` load. The search field
    /// filters on every keystroke, so doing the ICU case-folding
    /// (`u_isUAlphabetic`, `icu::CharString::append`) per app per keystroke
    /// over a 100+ app list hung the main thread (Sentry App Hang). Folding
    /// once up front turns each keystroke into a plain substring scan.
    /// `loweredNames` stays name-only for the Name sort; `loweredSearch` is the
    /// name + bundle id + uninstall name haystack for alias-aware filtering —
    /// folding those two extra fields per keystroke instead brought the App
    /// Hang straight back.
    private var loweredNames: [String: String] = [:]
    private var loweredSearch: [String: String] = [:]

    private func rebuildLoweredNames() {
        var names = [String: String](minimumCapacity: apps.count)
        var search = [String: String](minimumCapacity: apps.count)
        for a in apps {
            let name = a.name.lowercased()
            names[a.id] = name
            search[a.id] = "\(name) \(a.bundleId.lowercased()) \(a.uninstallName.lowercased())"
        }
        loweredNames = names
        loweredSearch = search
    }

    var filtered: [InstalledApp] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        // Alias-aware (name + bundle id + uninstall name, PRD §Uninstall), but
        // matched against the haystack pre-folded once per load — so a keystroke
        // is one substring scan per app, not three ICU foldings.
        let base = q.isEmpty ? apps : apps.filter {
            (loweredSearch[$0.id] ?? $0.name.lowercased()).contains(q)
        }
        let sorted: [InstalledApp]
        switch sort {
        case .size:   sorted = base.sorted { $0.sizeBytes > $1.sizeBytes }
        // Compare the pre-folded names instead of a per-pair
        // `localizedCaseInsensitiveCompare` (ICU) on every keystroke.
        case .name:   sorted = base.sorted { (loweredNames[$0.id] ?? "") < (loweredNames[$1.id] ?? "") }
        case .recent: sorted = base.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
        }
        return sortAscending ? sorted.reversed() : sorted
    }

    var selectedApps: [InstalledApp] { apps.filter { selected.contains($0.id) } }

    var selectionLabel: String {
        if selected.isEmpty {
            return String(format: NSLocalizedString("%d apps", comment: ""), apps.count)
        }
        let targets = selectedApps
        let total = targets.reduce(Int64(0)) { $0 + $1.sizeBytes }
        if targets.count == 1, let app = targets.first {
            return String(format: NSLocalizedString("%@ · 1 app · %@", comment: "selection summary"), app.name, Fmt.bytes(total))
        }
        return String(format: NSLocalizedString("%d apps · %@", comment: ""), targets.count, Fmt.bytes(total))
    }

    var uninstallButtonTitle: String {
        selected.isEmpty
            ? NSLocalizedString("Remove", comment: "")
            : String(format: NSLocalizedString("Remove %d", comment: ""), selected.count)
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        load()
    }

    func setSort(_ s: AppSort) {
        if sort == s {
            sortAscending.toggle()   // active chip flips direction
        } else {
            sort = s
            sortAscending = false
        }
        if s == .recent { ensureRecentDates() }
    }

    func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    // MARK: Leftover review (2.2)

    func pathSelectionBinding(_ appID: String) -> Binding<Set<String>> {
        Binding(get: { [weak self] in self?.pathSelections[appID] ?? [] },
                set: { [weak self] in self?.pathSelections[appID] = $0 })
    }

    /// Expand → run the dry-run enumeration once per app per session.
    func toggleExpansion(_ app: InstalledApp) {
        if expandedAppID == app.id {
            expandedAppID = nil
            return
        }
        expandedAppID = app.id
        guard previews[app.id] == nil, !previewLoading.contains(app.id) else { return }
        previewLoading.insert(app.id)
        let path = app.path
        let generation = loadGeneration
        let loader = previewLoader
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // The whole app, not just its uninstall name: `fetchPreview` decides between the
            // engine's bundle-id argv and the legacy name argv, and it needs the row to do it.
            let preview = loader(app)
            Task { @MainActor in
                guard let self,
                      generation == self.loadGeneration,
                      self.apps.contains(where: { $0.id == app.id && $0.path == path }) else { return }
                self.previewLoading.remove(app.id)
                self.previews[app.id] = preview
                // Default ticks: the auto-selected kinds, minus anything the engine already said
                // Burrow may not remove by hand (a refused bundle, a Homebrew cask's `.app`).
                if self.pathSelections[app.id] == nil {
                    self.pathSelections[app.id] = preview.defaultTicked
                }
            }
        }
    }

    /// Which identifier Burrow puts on argv for ONE app, given whether `.mo` is about to resolve
    /// to the bundled engine. Pure and separated from the actual spawn so the one dangerous
    /// decision here — when it's safe to send a bundle id vs. when to refuse outright — is
    /// unit-tested without a real process.
    ///
    /// ONE function for BOTH the dry-run enumeration (`fetchPreview`) and the real removal
    /// (`engineUninstall`), because the two used to decide separately and disagree: the preview
    /// sent `app.bundleId` while the removal sent `app.uninstallName`. Where two installed apps
    /// share a display name those are DIFFERENT inventory rows, verified against the real binary
    /// on a 135-app machine:
    ///
    ///     uninstall com.valvesoftware.steam → Steam,  /Applications/Steam.app
    ///     uninstall Steam                   → Steam,  ~/Applications/CrossOver/Steam/Steam.app
    ///                                                 (com.codeweavers.CrossOverHelper.4DB4…)
    ///
    /// Three `Restarter`, two `Updater` and two `Steam` on that machine alone — so the user would
    /// review one app's leftovers and the apply would act on another's. The engine's exact pass
    /// takes the first name hit and stops (a faithful port of bash's `break`), so the ambiguity
    /// is inherited and cannot be fixed by argument choice; sending the same UNAMBIGUOUS
    /// identifier from both call sites is what makes preview and apply name the same row.
    enum UninstallTarget: Equatable {
        /// Ask the bundled engine for this exact bundle id.
        case engine(bundleId: String)
        /// Ask a real legacy `mo`/MIT-fork binary for this display name — unchanged pre-repoint
        /// behavior, and the only namespace that binary's matcher understands.
        case legacy(name: String)
        /// Don't ask anything. See `isSendableBundleID` for the values that land here.
        case unavailable
    }

    /// Whether a `--list` row's `bundle_id` is a real identifier that may go on the engine's argv,
    /// or one of the values that resolve to the WRONG app — or to every app. All three verified
    /// against the real `burrow-engine` binary, not inferred from its source:
    ///
    ///  - **`""`** — an empty positional survives the engine's `positionals` scan and reaches
    ///    `match_apps_by_name`, whose substring pass asks `name.contains("")`. That is true of
    ///    every row: `uninstall --dry-run ""` resolved all 135 installed apps and enumerated 224
    ///    leftover paths as one app's. (The older failure this check was written for was
    ///    different but no less bad — a straight `leftover_paths(home, "")`, i.e. `~/Library/
    ///    Caches` itself reported as one app's leftovers. Multi-app resolution changed the shape
    ///    of the damage, not the need to refuse.)
    ///  - **`"unknown"`** — the literal string `uninstall --list` records for a bundle with no
    ///    `CFBundleIdentifier`; five rows on the same machine (Synergy, Stardew Valley, Oxygen
    ///    Not Included, Sid Meier's Civilization VII, Slay the Spire 2). It is not empty, so an
    ///    `isEmpty` check does not catch it, and it resolves through the engine's bundle-id pass
    ///    to whichever unknown-id row comes first — Synergy, verified. The engine then
    ///    short-circuits `bundle_id == "unknown"` to zero leftovers, so today it is a
    ///    MIS-ATTRIBUTED EMPTY report rather than a misdirected deletion; that is a property of
    ///    the engine's current internals, not a guarantee this side may lean on, and "no leftovers
    ///    found" presented for the wrong app is a claim Burrow has no business making.
    ///  - **a leading `-`** — `positionals` skips any token starting with `-`, so such an id would
    ///    vanish from argv and the run would silently act on fewer apps than it reported. No real
    ///    bundle id looks like this; refusing costs nothing and closes the shape.
    ///
    /// A row that fails this is never silently dropped from a removal — see `uninstallBatch`.
    ///
    /// The rule itself now lives in `UninstallGuard`, because it was this surface's alone and the
    /// MCP tool's `apps[]` went to the same argv having been only trimmed for whitespace — so an
    /// agent could send the one value this predicate exists to refuse. One predicate, both
    /// surfaces, plus the guard's own last look before an apply. (It also folds case now: the
    /// engine lowercases both sides of its bundle-id comparison, so `"Unknown"` resolves exactly
    /// as `"unknown"` does.)
    nonisolated static func isSendableBundleID(_ bundleId: String) -> Bool {
        UninstallGuard.isSendableArgument(bundleId)
    }

    nonisolated static func uninstallTarget(for app: InstalledApp,
                                            resolvedIsBundledEngine: Bool) -> UninstallTarget {
        guard resolvedIsBundledEngine else { return .legacy(name: app.uninstallName) }
        guard isSendableBundleID(app.bundleId) else { return .unavailable }
        return .engine(bundleId: app.bundleId)
    }

    /// A confirmed multi-app selection split by whether Burrow can name each app to the resolved
    /// binary at all. Pure, so the rule that matters is unit-tested: an app Burrow cannot name is
    /// SURFACED and skipped, never quietly folded into a run that then reports success for it.
    struct UninstallBatch: Equatable {
        /// argv positionals, one per addressable app, in selection order.
        let arguments: [String]
        /// The apps those arguments name, positionally aligned with `arguments`.
        let addressable: [InstalledApp]
        /// Apps with no identifier the resolved binary can be trusted with (`isSendableBundleID`).
        let unaddressable: [InstalledApp]
    }

    nonisolated static func uninstallBatch(for apps: [InstalledApp],
                                           resolvedIsBundledEngine: Bool) -> UninstallBatch {
        var arguments: [String] = []
        var addressable: [InstalledApp] = []
        var unaddressable: [InstalledApp] = []
        for app in apps {
            switch uninstallTarget(for: app, resolvedIsBundledEngine: resolvedIsBundledEngine) {
            case .engine(let bundleId):
                arguments.append(bundleId); addressable.append(app)
            case .legacy(let name):
                arguments.append(name); addressable.append(app)
            case .unavailable:
                unaddressable.append(app)
            }
        }
        return UninstallBatch(arguments: arguments, addressable: addressable,
                              unaddressable: unaddressable)
    }

    /// The dry-run enumeration behind the expanded leftover review. Two incompatible output
    /// contracts reach this call depending on which binary `.mo` resolves to:
    ///
    ///  - The BUNDLED ENGINE wants a bundle id positionally and answers JSON, never the ANSI
    ///    text this used to always send/parse. `app.uninstallName` is a DISPLAY NAME (sourced
    ///    from the old digger-era `--list`, i.e. mo's own matcher convention, not the engine's),
    ///    and a display name is not unique — see `UninstallTarget` for the live Steam collision
    ///    that made the preview and the apply enumerate two different applications. `app.bundleId`
    ///    is what the engine wants, but only when `isSendableBundleID` accepts it; that predicate
    ///    owns the three values that must never reach argv and the evidence for each.
    ///  - A real legacy `mo`/MIT fork resolved instead — unchanged from before this fix: its
    ///    `--dry-run <name>` prompts, EOF-on-stdin prints the ANSI enumeration
    ///    `UninstallPreview.parse` already understands, and it wants the display name, not a
    ///    bundle id.
    ///
    /// `resolved == MoleCLI.bundledExecutable()` is a path-identity check, and it is the same one
    /// two other places make before assuming engine semantics — go read them rather than take
    /// this sentence's word for it: `OperationFlow.start` compares `resolved` against
    /// `MoleCLI.bundledExecutable()` inline before translating its fallback spawn's argv, and
    /// `MoActions.mint` gets the same answer as data, from `EngineTarget.isBundledEngine`, and
    /// carries it on the ticket so the spawn cannot re-resolve to a different file.
    ///
    /// This call site resolves independently because it is a different action — expanding a row,
    /// not confirming a removal. `confirmAndUninstall` is where one user action means one
    /// resolution, shared by the sheet, the argv and the gate.
    ///
    /// No longer unreachable: this used to note that `MoleClient.listAppsResult()` always came
    /// back `.unavailable` against the bundled engine because it had no `--list`, so no row
    /// existed to expand. The engine implements `uninstall --list` now — it answered with 135
    /// rows on the machine this was verified on — so the `.engine` branch below is the live one
    /// in a shipped build, not a written-ahead placeholder.
    nonisolated private static func fetchPreview(for app: InstalledApp) -> UninstallPreview {
        let resolved = MoleCLI.findExecutable()
        let source = uninstallTarget(for: app,
                                     resolvedIsBundledEngine: resolved != nil && resolved == MoleCLI.bundledExecutable())
        // Spawn the file this resolution named, not a second lookup: `source` above already
        // decided what to SAY to the binary, and the two answers have to be about the same one.
        // `/usr/bin/false` for an unresolved lookup is the same degradation `.mo` already gave.
        let target = MoCommand.Target.executable(resolved ?? "/usr/bin/false")
        switch source {
        case .unavailable:
            return UninstallPreview(appName: nil, totalText: nil, entries: [])
        case .engine(let bundleId):
            let res = try? MoEngine.shared.capture(
                MoCommand(target: target, args: ["uninstall", "--dry-run", bundleId], timeout: 120))
            return UninstallPreview.fromEngineEnvelope(res?.stdout ?? "")
                ?? UninstallPreview(appName: nil, totalText: nil, entries: [])
        case .legacy(let name):
            // EOF after the prompt makes --dry-run print the enumeration and exit.
            let res = try? MoEngine.shared.capture(
                MoCommand(target: target, args: ["uninstall", "--dry-run", name], stdin: "y\n", timeout: 120))
            let text = Ansi.strip((res?.stdout ?? "") + "\n" + (res?.stderr ?? ""))
            return UninstallPreview.parse(text.components(separatedBy: "\n"))
        }
    }

    private var recentLoaded = false

    /// "Last used" needs a filesystem date per app — only worth it when
    /// the user actually sorts by it.
    private func ensureRecentDates() {
        guard !recentLoaded, !apps.isEmpty else { return }
        recentLoaded = true
        let snapshot = apps
        recentGeneration &+= 1
        let generation = recentGeneration
        let inventoryGeneration = loadGeneration
        let dateLoader = recentDateLoader
        DispatchQueue.global(qos: .userInitiated).async {
            let dates = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, dateLoader($0.path)) })
            Task { @MainActor in
                guard generation == self.recentGeneration,
                      inventoryGeneration == self.loadGeneration else { return }
                // The inventory may have refreshed metadata while dates were
                // loading. Merge onto the live rows by stable app identity so
                // a late date pass never resurrects an old snapshot.
                self.apps = self.apps.map { app in
                    guard let date = dates[app.id] else { return app }
                    return InstalledApp(
                        id: app.id, name: app.name, bundleId: app.bundleId, source: app.source,
                        uninstallName: app.uninstallName, path: app.path, sizeStr: app.sizeStr,
                        sizeBytes: app.sizeBytes, lastUsed: date
                    )
                }
            }
        }
    }

    func load() {
        loadGeneration &+= 1
        recentGeneration &+= 1
        let generation = loadGeneration
        let loader = appsLoader
        loading = true
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let (parsed, unavailable) = loader()
            Task { @MainActor in
                guard generation == self.loadGeneration else { return }
                self.apps = parsed
                self.inventoryUnavailable = unavailable
                self.loading = false
                self.recentLoaded = false
                self.previews = [:]
                self.previewLoading = []
                self.pathSelections = [:]
                self.expandedAppID = nil
                self.selected.formIntersection(parsed.map(\.id))
                if self.sort == .recent { self.ensureRecentDates() }
            }
        }
    }

    /// `mo uninstall --list` computes a size for every installed app, which can take a while on
    /// a full /Applications — the client gives it room. `unavailable` is true exactly when the
    /// underlying command failed (see `MoleClient.ListAppsResult`) — NOT when it succeeded with
    /// zero rows — so the empty-state view can tell "couldn't check" from "genuinely nothing".
    nonisolated private static func fetch() -> (apps: [InstalledApp], unavailable: Bool) {
        switch MoleClient.listAppsResult() {
        case .ok(let apps):
            // Pre-warm the icon + version cache here — `fetch` always runs on a
            // background queue, so the per-bundle icon/Info.plist disk reads happen
            // off-main and the rows then render from a pure cache read instead of
            // hitting the disk during layout (Sentry BURROW-20: InstalledApp hang).
            SoftwareIcons.prewarm(apps)
            return (apps, false)
        case .unavailable:
            return ([], true)
        }
    }

    /// Best-effort "last used" from the filesystem (access date, falling back to
    /// modification date). Deliberately NOT Spotlight (`kMDItemLastUsedDate`):
    /// querying metadata for every installed app woke `mds`/`mdworker` and spiked
    /// CPU/energy. Filesystem dates are close enough for the Recent sort and cost
    /// nothing — no metadata server, no indexing.
    private nonisolated static func lastUsedDate(_ path: String) -> Date? {
        let url = URL(fileURLWithPath: path)
        if let vals = try? url.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey]) {
            return vals.contentAccessDate ?? vals.contentModificationDate
        }
        return nil
    }

    // MARK: Removal

    /// Whether this app's removal is a reviewed SUBSET (some enumerated
    /// paths unticked) → native-trash path; full set / never reviewed →
    /// the engine's own uninstall.
    private func isSubsetRemoval(_ app: InstalledApp) -> Bool {
        guard let preview = previews[app.id], !preview.isEmpty,
              let ticked = pathSelections[app.id] else { return false }
        return ticked.count < preview.entries.count
    }

    /// One app's line in the confirm sheet, plus how many of its enumerated paths the user kept
    /// ticked when the removal is a reviewed subset. Named rather than a tuple so `confirmCopy`
    /// stays readable from its tests.
    struct ConfirmLine: Equatable {
        let name: String
        /// nil = the whole enumerated set (or never reviewed); a count = a reviewed subset.
        let reviewedCount: Int?
        /// The Homebrew cask token when this app is brew-managed (`--list` row `source:
        /// "Homebrew"`, `uninstall_name` = the token), else nil.
        ///
        /// It is here because it changes what is TRUE of this line, not how it looks. A brew app is
        /// removed by `brew uninstall --cask --zap <token>` — brew unlinks, it does not Trash, so
        /// "you can put it back" is false for it, and `--zap` runs the cask's zap stanza, which
        /// deletes paths no enumeration can predict. Both facts come from the inventory row, so the
        /// sheet can state them without paying for a dry run first.
        let homebrewCask: String?
        /// Whether THIS line's removal takes the `.app` with it.
        ///
        /// True for a whole-app removal. For a reviewed subset it is whatever the user left
        /// ticked — and "Clear Data" is the button that deliberately leaves it unticked, which is
        /// the case that made the sheet lie: `UninstallPlan.dataOnly` filters the bundle out, the
        /// removal is therefore a subset, and the sheet still printed "These move to the Trash —
        /// the app itself and the support files…" over a run that keeps the app installed. The
        /// copy branched on this before the rewrite; it has to again.
        let removesAppBundle: Bool

        init(name: String, reviewedCount: Int?, homebrewCask: String? = nil,
             removesAppBundle: Bool = true) {
            self.name = name
            self.reviewedCount = reviewedCount
            self.homebrewCask = homebrewCask
            self.removesAppBundle = removesAppBundle
        }
    }

    /// The confirm sheet's exact words. Pure and split out from `NSAlert` because the claim it
    /// makes is the thing that keeps being wrong, and a claim about where your applications go
    /// deserves a test.
    ///
    /// # What it now says, and why each part is load-bearing
    ///
    /// It said "These move to the Trash (recoverable)". Then the engine turned out to remove only
    /// `~/Library` leftovers, so it was rewritten to "The apps themselves stay installed". Now
    /// burrow-engine @ df9ea3f removes the `.app` too — the port of `lib/uninstall/batch.sh` — so
    /// the second wording is false in the other direction, and there is no longer any engine/legacy
    /// split to describe: BOTH binaries remove the bundle, both route it through Trash by default,
    /// and both hand a Homebrew cask to `brew uninstall --cask --zap`. One copy, no flag.
    ///
    ///  - **Where the app goes.** Burrow's GUI ticket is minted with `permanent: false`
    ///    (`engineUninstall`), so the bundle and its support files go to the real Trash and can be
    ///    put back. `--permanent` is the only thing that deletes outright and the GUI never sends
    ///    it; the sheet therefore promises the Trash without hedging.
    ///  - **Homebrew is a different sentence, not a footnote.** `brew uninstall --cask --zap` does
    ///    not Trash anything and removes bytes outside the enumerated paths, so brew-managed apps
    ///    get their own paragraph naming the command. Mixing them into the Trash sentence would
    ///    make the sheet's central promise false for exactly the apps where it matters most.
    ///  - **Partial outcomes.** The engine gates the leftover sweep on the bundle coming away
    ///    (`batch.sh:840`), so an app it cannot remove keeps its support files too. Stating that
    ///    here is what makes an "nothing happened for this one" outcome legible rather than
    ///    baffling; `UninstallGuard.problemReport` says which app afterwards.
    ///  - **A kept app is a third sentence, not an exception to the first.** "One copy, no flag"
    ///    was too few copies: the rewrite dropped the branch on whether the `.app` is actually in
    ///    the removal, and "Clear Data" — the button whose own tooltip says it keeps the app
    ///    installed — then consented the user to "the app itself … moves to the Trash". Whether
    ///    the bundle goes is a per-LINE fact (`ConfirmLine.removesAppBundle`), like Homebrew is,
    ///    so it gets a per-line paragraph the same way.
    nonisolated static func confirmCopy(lines: [ConfirmLine], skipped: [String],
                                        hasReviewedSubset: Bool) -> (title: String, body: String, confirmButton: String) {
        func render(_ subset: [ConfirmLine]) -> String {
            subset.map { line -> String in
                guard let count = line.reviewedCount else { return "• \(line.name)" }
                return "• \(line.name) — \(String(format: NSLocalizedString("%d reviewed files", comment: ""), count))"
            }.joined(separator: "\n")
        }
        let brewed = lines.filter { $0.homebrewCask != nil }
        let direct = lines.filter { $0.homebrewCask == nil && $0.removesAppBundle }
        // Kept apps: a reviewed subset that leaves the `.app` unticked. Their own sentence,
        // because the promise being made about them is the opposite one.
        let dataOnly = lines.filter { $0.homebrewCask == nil && !$0.removesAppBundle }

        // A sheet where nothing loses its bundle must not ASK to remove apps — that question and
        // the body underneath it would contradict each other on the one dialog that takes consent.
        let removesAnyApp = lines.contains { $0.removesAppBundle }
        let title: String
        if removesAnyApp {
            title = String(format: NSLocalizedString(lines.count == 1 ? "Remove %d app?" : "Remove %d apps?", comment: ""), lines.count)
        } else {
            title = String(format: NSLocalizedString(lines.count == 1 ? "Remove data from %d app?" : "Remove data from %d apps?", comment: ""), lines.count)
        }
        var blocks: [String] = []
        if !direct.isEmpty {
            blocks.append(String(format: NSLocalizedString("These move to the Trash — the app itself and the support files it keeps in your Library (containers, caches, preferences, saved state). You can put them back:\n\n%@", comment: ""),
                                 render(direct)))
        }
        if !dataOnly.isEmpty {
            blocks.append(String(format: NSLocalizedString("These stay installed — only the reviewed support files move to the Trash, and you can put them back:\n\n%@", comment: ""),
                                 render(dataOnly)))
        }
        if !brewed.isEmpty {
            blocks.append(String(format: NSLocalizedString("Homebrew removes these by running `brew uninstall --cask --zap`. That doesn't use the Trash, and `--zap` also deletes configuration and data the cask declares — more than the file list can show:\n\n%@", comment: ""),
                                 render(brewed)))
        }
        var body = blocks.joined(separator: "\n\n")
        // Only true of a run that removes bundles — it describes the engine's leftover gate. On a
        // data-only sheet it would describe a removal nobody is being asked to consent to.
        if removesAnyApp {
            body += "\n\n" + NSLocalizedString("If an app can't be removed, Burrow leaves its support files alone too, rather than half-removing it.", comment: "")
        }
        // The button names the mechanism it triggers. With a brew cask in the set there is no one
        // mechanism to name, and "Move to Trash" would be the false half.
        let confirmButton = brewed.isEmpty
            ? NSLocalizedString("Move to Trash", comment: "")
            : NSLocalizedString("Remove", comment: "")
        if hasReviewedSubset {
            body += "\n\n" + NSLocalizedString("Reviewed subsets are trashed by Burrow directly and appear in Burrow's Activity log, not `mo history`.", comment: "")
        }
        if !skipped.isEmpty {
            body += "\n\n" + String(format: NSLocalizedString("Skipped — these have no bundle identifier, so Burrow can't tell the engine which app it means:\n\n%@", comment: ""),
                                    skipped.map { "• \($0)" }.joined(separator: "\n"))
        }
        return (title, body, confirmButton)
    }

    func confirmAndUninstall() {
        let targets = selectedApps
        guard !targets.isEmpty else { return }
        // Resolve the binary ONCE, here, and hand the answer to the sheet, the argv AND the gate.
        // The sheet describes what a specific binary is about to do, so a second resolution later
        // could describe one binary and run another. In a shipped build this is a `Bundle.main`
        // lookup plus an `isExecutableFile` stat with no subprocess (`trustedExecutable` hits the
        // bundled engine first) — `AppDelegate` already gates its destructive actions on the same
        // call from the main thread.
        //
        // `elevated: false` is the truth about this flow, not a shortcut: an uninstall ticket is
        // never elevated (`ActionSpec.elevatedRealRunGUI` is false for `.uninstall`), so the
        // un-elevated lookup is the one the gate would have made anyway. Passing this same value
        // into `MoActions.decide` below is what keeps it at one resolution per user action.
        let engine = EngineTarget.resolve(elevated: false)
        let isEngine = engine.isBundledEngine

        let wholeApps = targets.filter { !isSubsetRemoval($0) }
        let subsetApps = targets.filter { isSubsetRemoval($0) }
        // Whole-app removals are the only ones that reach the engine's argv; a reviewed subset is
        // trashed by Burrow from paths the engine already enumerated, so it needs no identifier.
        let batch = Self.uninstallBatch(for: wholeApps, resolvedIsBundledEngine: isEngine)

        // A whole-app removal is the only kind brew can be involved in — a reviewed subset is
        // Burrow trashing ticked paths itself, which never shells out to brew — so only these
        // lines carry a cask token. `uninstallName` IS the token on a `source: "Homebrew"` row
        // (the engine's `--list` puts it there); on every other row it is the display name.
        var lines = batch.addressable.map {
            Self.ConfirmLine(name: $0.name, reviewedCount: nil,
                             homebrewCask: $0.source == "Homebrew" ? $0.uninstallName : nil)
        }
        lines += subsetApps.map { app in
            let ticked = pathSelections[app.id] ?? []
            // Does THIS subset take the bundle? "Clear Data" is exactly the subset that doesn't,
            // and the sheet has to say so rather than print the whole-app promise over it.
            let takesBundle = (previews[app.id]?.entries ?? [])
                .contains { ticked.contains($0.path) && $0.kind == .application }
            return Self.ConfirmLine(name: app.name, reviewedCount: ticked.count,
                                    removesAppBundle: takesBundle)
        }
        // Nothing addressable and nothing reviewed: there is no destructive action to consent to,
        // so don't offer one. Saying which apps and why beats a sheet whose OK button does nothing.
        guard !lines.isEmpty else {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Nothing Burrow can remove", comment: "")
            alert.informativeText = String(format: NSLocalizedString("These have no bundle identifier, so Burrow can't tell the engine which app it means:\n\n%@", comment: ""),
                                           batch.unaddressable.map { "• \($0.name)" }.joined(separator: "\n"))
            alert.alertStyle = .informational
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            alert.runModalQuiet()
            return
        }

        let copy = Self.confirmCopy(lines: lines,
                                    skipped: batch.unaddressable.map(\.name),
                                    hasReviewedSubset: !subsetApps.isEmpty)
        let alert = NSAlert()
        alert.messageText = copy.title
        alert.informativeText = copy.body
        alert.alertStyle = .warning
        alert.addButton(withTitle: copy.confirmButton)
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        guard alert.runModalQuiet() == .alertFirstButtonReturn else { return }

        switch Self.removalRoute(addressable: batch.addressable, subsets: subsetApps) {
        case .none:
            break
        case .trashOnly(let subsets):
            trashSubsets(subsets)
        case .engineThenTrash(let subsets):
            engineUninstall(batch.addressable, arguments: batch.arguments,
                            promised: Self.promisedMechanisms(batch.addressable, batch.arguments),
                            thenTrash: subsets, on: engine)
        }
    }

    /// Which of the two removal mechanisms runs, and — the part that matters — in what
    /// relationship to the pre-flight.
    ///
    /// **This is a safety property, so it is a value and not statement order.** The code here used
    /// to call `trashSubsets` FIRST and unconditionally — no guard, no dry run — and only then
    /// hand the rest to the engine. Every `abortReason` sentence ends "so nothing was removed";
    /// when the pre-flight aborted, the user read that over a Trash that already held a subset
    /// app's files, its `.app` included. There is no `.trashOnly` case alongside an engine run any
    /// more: with an addressable app present the subsets are handed to `engineUninstall` and go
    /// only once its dry run has confirmed the set.
    enum RemovalRoute: Equatable {
        /// Nothing to do.
        case none
        /// No engine argv, so no pre-flight to wait behind: Burrow trashes the reviewed paths.
        case trashOnly([InstalledApp])
        /// The engine runs, and these subsets are trashed AFTER its dry run confirms the set.
        case engineThenTrash([InstalledApp])
    }

    nonisolated static func removalRoute(addressable: [InstalledApp],
                                         subsets: [InstalledApp]) -> RemovalRoute {
        if addressable.isEmpty {
            return subsets.isEmpty ? .none : .trashOnly(subsets)
        }
        return .engineThenTrash(subsets)
    }

    /// What the sheet just told the user about each engine-bound app: Trash, or Homebrew.
    ///
    /// Keyed by the lowercased argument so `UninstallGuard.consentDivergence` can line it up with
    /// `apps[].query`. This is the tab's INVENTORY SNAPSHOT talking — the same `source ==
    /// "Homebrew"` the confirm lines were built from — which is precisely why it has to be handed
    /// forward and checked against the engine's own fresh answer rather than trusted.
    nonisolated static func promisedMechanisms(_ apps: [InstalledApp],
                                               _ arguments: [String]) -> [String: UninstallGuard.Mechanism] {
        var out: [String: UninstallGuard.Mechanism] = [:]
        for (app, argument) in zip(apps, arguments) {
            out[argument.lowercased()] = app.source == "Homebrew" ? .homebrew : .direct
        }
        return out
    }

    /// Burrow trashes exactly the reviewed, ticked paths. Every path is
    /// asserted to come from the engine's own enumeration — the safety
    /// scan decided the candidate set, the review only narrowed it.
    ///
    /// "Came from the enumeration" turned out to be the weaker half of that sentence. The engine
    /// puts an app's `.app` in `items[]` on `bundle.present` ALONE, with no refusal check
    /// (`bundle.rs:584-591`) — being IN the preview is not permission to delete it. The verdict
    /// lives in `apps[].application`, which `UninstallPreview` now carries as
    /// `handRemovalRefusals`, and it covers the two cases where this method would otherwise
    /// hand-delete something the engine would not: a bundle a protection rail already declined,
    /// and a Homebrew cask, whose rule is `brew uninstall --cask --zap` or nothing (trashing the
    /// `.app` leaves brew's Caskroom believing it is still installed).
    private func trashSubsets(_ apps: [InstalledApp]) {
        guard !apps.isEmpty else { return }
        var refused: [(name: String, reason: String)] = []
        let work: [(app: InstalledApp, paths: [String])] = apps.compactMap { app in
            guard let preview = previews[app.id], let ticked = pathSelections[app.id] else { return nil }
            let enumerated = Set(preview.entries.map(\.path))
            // HARD SAFETY RULE, fail closed (a release-stripped assert is
            // decoration): every ticked path must come from the engine's
            // own enumeration. Anything else means corrupted review state —
            // trash NOTHING for this app rather than trusting a filter.
            guard ticked.isSubset(of: enumerated) else {
                assertionFailure("ticked paths must come from the dry-run enumeration")
                return nil
            }
            // SECOND HARD RULE, same shape: the engine's refusals win over the tick. Fail closed
            // for the whole app rather than dropping the refused path and trashing the rest — a
            // removal the user reviewed as one thing must not silently become a different one.
            let declined = preview.refusedAmong(ticked)
            guard declined.isEmpty else {
                refused.append(contentsOf: declined.map { (app.name, $0.reason) })
                return nil
            }
            let paths = ticked.map { ($0 as NSString).expandingTildeInPath }
            return (app, paths)
        }
        if !refused.isEmpty {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Burrow won't remove these itself", comment: "")
            alert.informativeText = refused
                .map { "\($0.name) — \($0.reason)" }
                .joined(separator: "\n\n")
            alert.alertStyle = .warning
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            alert.runModalQuiet()
        }
        guard !work.isEmpty else { return }
        let opId = UUID()
        OperationCenter.shared.begin(opId, label: NSLocalizedString("Removing reviewed files", comment: ""),
                                     notifiesOnEnd: true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var moved = 0, failed = 0
            for (_, paths) in work {
                for path in paths {
                    do {
                        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                        moved += 1
                    } catch { failed += 1 }
                }
            }
            Task { @MainActor in
                OperationCenter.shared.end(opId, success: failed == 0,
                                           detail: String(format: NSLocalizedString("%d moved · %d failed", comment: ""), moved, failed))
                self?.selected.subtract(work.map(\.app.id))
                self?.load()
            }
        }
    }

    /// The engine path — `mo uninstall <ids>`, Trash-based, with the matched-set pre-flight
    /// (audit H4) before any y is answered.
    ///
    /// `arguments` arrives already resolved by `uninstallBatch` rather than being derived here.
    /// That is the fix for the defect this method WAS: it built its own argv from
    /// `$0.uninstallName` while `fetchPreview` sent `$0.bundleId`, so for any two installed apps
    /// sharing a display name the sheet reviewed one app's leftovers and this ran against
    /// another's. One resolution per user action, shared by the preview, the sheet and the run.
    ///
    /// `arguments` is also what the pre-flight compares against — but only ever as one half of it.
    /// `apps[].query` echoes each argument back verbatim, so comparing the two confirms that the
    /// engine heard us and NOTHING about which applications it resolved; `unknown` in, `unknown`
    /// out, Synergy deleted. `targets` is positionally aligned with `arguments`, so the row the
    /// user actually picked — its path and its bundle id — goes to the guard as well, and the
    /// engine's `apps[].path` is checked against it.
    ///
    /// `promised` is what the confirm sheet claimed about each app (Trash or Homebrew), taken from
    /// the tab's inventory snapshot. The dry run below answers the same question from a fresh
    /// inventory, and the two can disagree — a `brew_wedged` breaker during one scan and not the
    /// other degrades every cask row to `source: "App"`. Where they disagree the user gets asked
    /// again, with the corrected sentence, rather than getting `--zap` after being promised the
    /// Trash.
    ///
    /// `thenTrash` is the reviewed-subset work, deliberately deferred to here: it runs once the
    /// dry run has confirmed the set, so an abort really does mean nothing was removed.
    private func engineUninstall(_ targets: [InstalledApp], arguments: [String],
                                 promised: [String: UninstallGuard.Mechanism],
                                 thenTrash subsets: [InstalledApp],
                                 on engine: EngineTarget) {
        // The dialog above is the consent; the ticket (argv / stdin /
        // timeout / preflight) is minted by the shared gate — the same
        // truth table and catalog the MCP server uses. (One deliberate
        // change rides along: the catalog's unified 600 s uninstall
        // timeout replaces this view's old 300 s.)
        //
        // `engine` is `confirmAndUninstall`'s own resolution, handed in rather than looked up
        // again here. It decides two things that must agree: which argv dialect this ticket
        // speaks, and which file the two spawns below run. `uninstallBatch` already built
        // `arguments` from the same answer, so the identifiers, the argv and the binary all come
        // from ONE lookup — the sheet the user agreed to describes the run that happens.
        //
        // The pre-flight comes off the ticket as ONE value — the policy and the read-only probe
        // that answers it — so unwrapping it here is the whole check. A real uninstall always
        // carries one; a ticket that somehow didn't would run the destructive apply below with no
        // guard in front of it, so this refuses instead, exactly like the verdict test it rides
        // with. Both refusals are silent because nothing has started yet: no HUD entry, no
        // `loading`, no Trash — there is nothing to unwind and nothing to explain.
        guard case .run(let ticket) = MoActions.decide(
                  .uninstall(apps: arguments, permanent: false), .real,
                  .gui(hasFullDiskAccess: true, userConfirmed: true),
                  resolve: { _ in engine }),
              let pre = ticket.preflight?.command else { return }
        loading = true
        // Surface the run in the menu-bar HUD's Activity section too. Both resolved binaries now
        // remove the `.app` as well as its support files, so "Uninstalling" is the true label —
        // it was "Removing leftover files" only for as long as the engine really did leave the
        // bundles installed.
        let opId = UUID()
        let hudLabel = "Uninstalling \(targets.count) app\(targets.count == 1 ? "" : "s")"
        OperationCenter.shared.begin(opId, label: hudLabel, notifiesOnEnd: true)
        DispatchQueue.global(qos: .userInitiated).async {
            // Pre-flight (audit H4): the resolved binary does its own matching, so before anything
            // is removed, verify what it says it will ACT ON equals what the user CONFIRMED.
            // `--dry-run` changes nothing; anything unreadable aborts (fail closed).
            // `pre` was minted with the ticket, from the same resolution, so this probe and the
            // apply below are the same binary reading argv built for it.
            let dry = try? MoEngine.shared.capture(
                MoCommand(target: .executable(pre.spawnPath), args: pre.args, stdin: pre.stdin,
                          timeout: pre.timeout ?? 120))
            let reading = UninstallGuard.readDryRun(stdout: dry?.stdout ?? "",
                                                    stderr: dry?.stderr ?? "")
            // A non-zero exit with an unreadable body is its own failure, and the engine's reason
            // lives on stdout (see BurrowEnvelope) — read it so an abort can name a bad bundle id
            // or a permission denial instead of blaming the format.
            let dryReason = ((dry?.exitCode ?? 1) != 0
                             || BurrowEnvelope.reportsFailure(stdout: dry?.stdout ?? ""))
                ? BurrowEnvelope.failureReason(stdout: dry?.stdout ?? "", stderr: dry?.stderr ?? "")
                : nil
            // The identity half of the pre-flight: which inventory row each argument was MEANT to
            // name. Built from `targets`, which `uninstallBatch` produced alongside `arguments` in
            // the same order, so the pairing is the batch's own and not re-derived here.
            let expecting = zip(arguments, targets).map {
                UninstallGuard.Expectation(query: $0, name: $1.name, path: $1.path,
                                           bundleId: $1.bundleId)
            }
            if let problem = UninstallGuard.abortReason(confirmed: arguments, dryRun: reading,
                                                        expecting: expecting) {
                Task { @MainActor in
                    self.loading = false
                    OperationCenter.shared.end(opId, success: false,
                                               detail: NSLocalizedString("aborted — nothing removed", comment: ""))
                    let alert = NSAlert()
                    alert.messageText = NSLocalizedString("Uninstall aborted", comment: "")
                    var informative = problem
                    // Only add the engine's raw reason when the abort didn't already come FROM it:
                    // `.engineRefused` already quotes that exact sentence, and printing it twice
                    // reads as two separate problems.
                    var quotesEngineReason = false
                    if case .engineRefused = reading { quotesEngineReason = true }
                    if let dryReason, !quotesEngineReason {
                        informative += "\n\n" + String(
                            format: NSLocalizedString("The engine reported: %@", comment: ""),
                            String(dryReason.prefix(300)))
                    }
                    alert.informativeText = informative
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
                    alert.runModalQuiet()
                }
                return
            }

            // THE POST-CONSENT DRY RUN IS THE AUTHORITY ON WHAT THE USER WAS TOLD.
            //
            // It was already being decoded and thrown away: `abortReason` reads the set and the
            // refusals, and `application.action`, `application.cask`, `external_commands[]`,
            // `warnings[]` and `requires_admin` — the fields that say HOW each app comes off the
            // disk and what else will happen — went nowhere. Meanwhile the sheet had answered the
            // brew-vs-Trash question minutes earlier from the tab's stale inventory. Two answers
            // to one question, and the newer, more expensive one was the one being discarded.
            //
            // A disagreement about the Trash is a re-consent, not a footnote: "you can put them
            // back" is false for `--zap`, and it is the sentence the user agreed on. Warnings get
            // the same treatment — the `/var/root` `$HOME` detection means the run will remove the
            // bundle and never even look for the support files, which is not the removal that was
            // described.
            if case .engine(let plan) = reading {
                let divergence = UninstallGuard.consentDivergence(plan: plan, promised: promised)
                if divergence != nil || !plan.warnings.isEmpty {
                    // `advisories` folds in `requires_admin`, the `--zap` commands and the engine's
                    // own `warnings[]` — all three previously had no production reader at all.
                    let advisories = UninstallGuard.advisories(for: plan)
                    // Synchronously, because the answer decides whether the very next line runs a
                    // destructive command. `Task { @MainActor }` would let it run first.
                    let confirmed: Bool = DispatchQueue.main.sync { MainActor.assumeIsolated {
                        let alert = NSAlert()
                        alert.messageText = NSLocalizedString("This isn't quite what Burrow just told you", comment: "")
                        var body: [String] = []
                        if let divergence { body.append(divergence) }
                        body.append(contentsOf: advisories)
                        alert.informativeText = body.joined(separator: "\n\n")
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: NSLocalizedString("Remove anyway", comment: ""))
                        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
                        return alert.runModalQuiet() == .alertFirstButtonReturn
                    } }
                    guard confirmed else {
                        Task { @MainActor in
                            self.loading = false
                            OperationCenter.shared.end(opId, success: false,
                                                       detail: NSLocalizedString("cancelled — nothing removed", comment: ""))
                        }
                        return
                    }
                }
            }

            // Past every gate: the subsets Burrow trashes itself go now, not before the dry run.
            if !subsets.isEmpty {
                DispatchQueue.main.sync { MainActor.assumeIsolated { self.trashSubsets(subsets) } }
            }

            // Verified — the ticket's stdin answers mo's prompts (proceed +
            // final confirm); they only ever apply to the set the dry run
            // just pinned.
            let res = try? MoEngine.shared.capture(
                MoCommand(target: .executable(ticket.command.spawnPath), args: ticket.command.args,
                          stdin: ticket.command.stdin, timeout: ticket.command.timeout ?? 600))
            // A zero exit alone isn't removal: an `ok:false` envelope is the engine saying it
            // refused or failed, so it counts as a failure here too. Narrowing only — a legacy
            // `mo` emits no envelope, and a success envelope leaves this untouched, so no
            // uninstall that really happened is re-labelled as failed.
            let ok = (res?.exitCode ?? 1) == 0
                && !BurrowEnvelope.reportsFailure(stdout: res?.stdout ?? "")

            // PARTIAL, and it has to be read BEFORE the generic failure branch below. A run where
            // one app's bundle was refused still exits non-zero with an `ok:TRUE` envelope — the
            // engine's `i32::from(failed)` — so `ok` is false while `failureReason` has no
            // classified message to find and would fall back to printing the whole JSON document.
            // The per-app `status` is the real answer, and it is also the only place "the leftovers
            // went and the app did not" is visible at all.
            let outcome = UninstallGuard.readOutcome(stdout: res?.stdout ?? "")
            if let outcome, let report = UninstallGuard.problemReport(outcome) {
                let (parsed, unavailable) = Self.fetch()
                Task { @MainActor in
                    // Something DID come away for the apps that succeeded, so the list is stale —
                    // re-scan (unlike the total-failure branch, which keeps the selection to retry).
                    self.apps = parsed
                    self.inventoryUnavailable = unavailable
                    self.selected = []
                    self.loading = false
                    self.recentLoaded = false
                    if self.sort == .recent { self.ensureRecentDates() }
                    OperationCenter.shared.end(
                        opId, success: false,
                        detail: "\(outcome.applicationsRemoved) removed · \(outcome.problems.count) not")
                    let alert = NSAlert()
                    alert.messageText = outcome.applicationsRemoved == 0
                        ? NSLocalizedString("Uninstall didn't finish", comment: "")
                        : NSLocalizedString("Uninstall finished partly", comment: "")
                    alert.informativeText = report
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
                    alert.runModalQuiet()
                }
                return
            }

            // FAILURE (#254): the apps are still installed, so there's nothing to re-scan —
            // keep the list AND the selection so the user can retry, and surface the
            // engine's actual error in an alert (the HUD alone can be invisible when the
            // menu-bar icon is off).
            guard ok else {
                // This site already fell back from stderr to stdout, which is why it kept
                // saying SOMETHING through the repoint — but what it said was the whole
                // envelope JSON, wrapped to the last six lines. `failureReason` reads the
                // classified `error.message` out of it and keeps the identical stderr→stdout
                // fallback for a legacy `mo`; the line trimming still applies, since that
                // fallback is where multi-line output comes from.
                let engineError = (BurrowEnvelope.failureReason(stdout: res?.stdout ?? "",
                                                                stderr: res?.stderr ?? "") ?? "")
                    .components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .suffix(6)
                    .joined(separator: "\n")
                Task { @MainActor in
                    self.loading = false
                    OperationCenter.shared.end(opId, success: false,
                                               detail: NSLocalizedString("uninstall failed", comment: ""))
                    let alert = NSAlert()
                    alert.messageText = NSLocalizedString("Uninstall failed", comment: "")
                    alert.informativeText = engineError.isEmpty
                        ? NSLocalizedString("The engine reported a failure with no error output. Nothing was removed.", comment: "")
                        : engineError
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
                    alert.runModalQuiet()
                }
                return
            }

            let (parsed, unavailable) = Self.fetch()
            Task { @MainActor in
                self.apps = parsed
                self.inventoryUnavailable = unavailable
                self.selected = []
                self.loading = false
                // Re-fetched apps have lastUsed == nil; recompute dates if the
                // user is still sorting by Recent (mirror load()), else Recent
                // would silently collapse after an uninstall.
                self.recentLoaded = false
                if self.sort == .recent { self.ensureRecentDates() }
                // Say which mechanism actually removed them. `via: "brew"` is NOT the Trash —
                // brew unlinks — so claiming "moved to Trash" for a cask would send the user
                // looking somewhere the app isn't.
                let viaBrew = outcome?.apps.filter { $0.application.via == "brew" }.count ?? 0
                OperationCenter.shared.end(
                    opId, success: true,
                    detail: viaBrew > 0
                        ? "\(targets.count) removed · \(viaBrew) via Homebrew"
                        : "\(targets.count) moved to Trash")
                // Reachable only on an elevated run, which this call site never mints — but a
                // warning the engine bothered to emit is not something to swallow on the way past.
                if let warnings = outcome?.warnings, !warnings.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = NSLocalizedString("Uninstall finished", comment: "")
                    alert.informativeText = warnings.joined(separator: "\n\n")
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
                    alert.runModalQuiet()
                }
            }
        }
    }
}

// MARK: - Startup segment (2.4)

@MainActor
final class StartupModel: ObservableObject {
    enum Filter { case all, agents, daemons, problems }

    @Published var items: [StartupItem] = [] { didSet { rebuildLoweredLabels() } }
    /// `label` → lowercased label, folded once per `items` load so the search
    /// field doesn't re-run ICU case-folding per item on every keystroke
    /// (same App-Hang pattern as the app list).
    private var loweredLabels: [String: String] = [:]
    private func rebuildLoweredLabels() {
        var map = [String: String](minimumCapacity: items.count)
        for i in items { map[i.label] = i.label.lowercased() }
        loweredLabels = map
    }
    /// Labels currently disabled in the per-user launchd database.
    @Published var disabled: Set<String> = []
    @Published var loading = false
    @Published var filter: Filter = .all
    @Published var query = ""
    private var started = false

    func startIfNeeded() {
        guard !started else { return }
        started = true
        reload()
    }

    func reload() {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scanned = StartupInventory.scanLiveIncludingLoginItems()
            let disabled = StartupControl.disabledLabels()
            Task { @MainActor in
                self?.items = scanned
                self?.disabled = disabled
                self?.loading = false
            }
        }
    }

    func isEnabled(_ item: StartupItem) -> Bool { !disabled.contains(item.label) }

    /// Toggle a controllable user agent (optimistic, then re-read to confirm).
    func setEnabled(_ enabled: Bool, _ item: StartupItem) {
        guard item.controllable else { return }
        if enabled { disabled.remove(item.label) } else { disabled.insert(item.label) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            StartupControl.setEnabled(enabled, item: item)
            let fresh = StartupControl.disabledLabels()
            Task { @MainActor in self?.disabled = fresh }
        }
    }

    var filtered: [StartupItem] {
        var base = items
        switch filter {
        case .all: break
        case .agents: base = base.filter { $0.kind == .launchAgent }
        case .daemons: base = base.filter { $0.kind == .launchDaemon }
        case .problems: base = base.filter { $0.problem != nil }
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter { (loweredLabels[$0.label] ?? $0.label.lowercased()).contains(q) }
    }

    var sections: [(title: String, items: [StartupItem])] {
        let f = filtered
        let user = f.filter { $0.scope == .user }
        let agents = f.filter { $0.scope == .system && $0.kind == .launchAgent }
        let daemons = f.filter { $0.scope == .system && $0.kind == .launchDaemon }
        return [
            (NSLocalizedString("Your launch agents", comment: ""), user),
            (NSLocalizedString("System launch agents", comment: ""), agents),
            (NSLocalizedString("System launch daemons", comment: ""), daemons),
        ].filter { !$0.1.isEmpty }
    }
}

struct StartupView: View {
    @ObservedObject var model: StartupModel

    var body: some View {
        Group {
            if model.loading && model.items.isEmpty {
                VStack { Spacer(); ProgressView("Reading startup items…").controlSize(.large)
                    .tint(Tool.apps.accent).font(Brand.mono(11)); Spacer() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.sections, id: \.title) { section in
                            HStack(spacing: 6) {
                                Text(section.title.uppercased())
                                    .font(Brand.mono(10, .bold)).tracking(0.7).foregroundStyle(Brand.textTertiary)
                                Text(verbatim: "\(section.items.count)")
                                    .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                            }
                            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 6)
                            ForEach(section.items) { item in
                                row(item)
                                Rectangle().fill(Brand.hairline).frame(height: 1).padding(.leading, 48)
                            }
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                }
                .scrollIndicators(.visible)
            }
        }
        .onAppear { model.startIfNeeded() }
    }

    private func row(_ item: StartupItem) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: icon(for: item))
                .resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 7) {
                    Text(item.label).font(Brand.sans(12, .medium)).foregroundStyle(Brand.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    if let problem = item.problem {
                        Chip(text: NSLocalizedString("Error", comment: ""), color: Brand.red)
                            .help(problem.label)
                    }
                }
                Text(item.subline).font(Brand.mono(9)).foregroundStyle(Brand.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { AnalyzeIcons.reveal(item.plistPath) } label: {
                Image(systemName: "magnifyingglass.circle").font(.system(size: 12)).foregroundStyle(Brand.textTertiary)
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("Reveal in Finder", comment: ""))
            .accessibilityLabel(NSLocalizedString("Reveal in Finder", comment: ""))
            // User agents get a real toggle (launchctl, no admin); bundled
            // and system-owned items stay review-only behind the lock —
            // macOS won't let us change those safely without root.
            if item.controllable {
                Toggle("", isOn: Binding(get: { model.isEnabled(item) },
                                         set: { model.setEnabled($0, item) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .tint(Tool.apps.accent)
                    .help(NSLocalizedString("Enable or disable this login item", comment: ""))
                    .accessibilityLabel(item.label)
                    .accessibilityValue(model.isEnabled(item)
                        ? NSLocalizedString("enabled", comment: "") : NSLocalizedString("disabled", comment: ""))
            } else {
                Image(systemName: "lock")
                    .font(.system(size: 10)).foregroundStyle(Brand.textTertiary)
                    .help(NSLocalizedString("Review only — managed by its app or the system.", comment: ""))
                    .accessibilityLabel(NSLocalizedString("Review only", comment: ""))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    private func icon(for item: StartupItem) -> NSImage {
        // Bundled helpers get their app's icon; loose ones a generic gear.
        if let exe = item.executable, let appRange = exe.range(of: ".app/") {
            let appPath = String(exe[..<appRange.lowerBound]) + ".app"
            return SoftwareIcons.icon(appPath)
        }
        return NSWorkspace.shared.icon(for: .propertyList)
    }
}
