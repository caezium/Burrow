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
        .background(Capsule().fill(Color.black.opacity(0.22)))
        .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 1))
    }

    private func seg(_ title: String, _ value: SoftwareSegment) -> some View {
        let on = model.segment == value
        return Button { model.segment = value } label: {
            Text(NSLocalizedString(title, comment: "")).font(Brand.mono(11, on ? .semibold : .regular))
                .foregroundStyle(on ? .black : Brand.textSecondary)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background { if on { Capsule().fill(.white) } }
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
        .background(Capsule().fill(Color.black.opacity(0.22)))
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
        .background(Capsule().fill(Color.black.opacity(0.22)))
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
                    .foregroundStyle(model.selected.isEmpty ? Brand.textTertiary : .black)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Capsule().fill(model.selected.isEmpty ? Color.white.opacity(0.06) : Color.white))
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
                    let dataPaths = UninstallPlan.dataOnly(paths: preview.entries.map(\.path))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name).font(Brand.sans(12, .semibold)).foregroundStyle(Brand.textPrimary)
                        Text(prettyPath).font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Text(verbatim: "\(pathSelection.count)/\(preview.entries.count) selected")
                        .font(Brand.mono(10)).foregroundStyle(Brand.textSecondary)
                    if dataPaths.count < preview.entries.count {
                        Button(NSLocalizedString("Clear Data", comment: "")) {
                            pathSelection = Set(dataPaths)
                        }
                        .buttonStyle(.plain).font(Brand.sans(10, .semibold)).foregroundStyle(Tool.apps.accent)
                        .help(NSLocalizedString("Select everything except the app itself — removes its data but keeps the app installed.", comment: ""))
                    }
                    Button(NSLocalizedString("Select all", comment: "")) {
                        pathSelection = Set(preview.entries.map(\.path))
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
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.black.opacity(0.22)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Brand.hairline, lineWidth: 1))
        } else if preview != nil {
            Text("Couldn't enumerate this app's files — Remove uses the engine's full uninstall.")
                .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                .padding(10)
        }
    }

    private func groupHeader(_ title: String, entries: [UninstallPreview.Entry]) -> some View {
        let selectedCount = entries.filter { pathSelection.contains($0.path) }.count
        return HStack(spacing: 8) {
            Button {
                let paths = entries.map(\.path)
                if selectedCount == entries.count {
                    pathSelection.subtract(paths)
                } else {
                    pathSelection.formUnion(paths)
                }
            } label: {
                Image(systemName: selectedCount == entries.count ? "checkmark.square.fill"
                      : (selectedCount == 0 ? "square" : "minus.square.fill"))
                    .font(.system(size: 12))
                    .foregroundStyle(selectedCount == 0 ? Brand.textTertiary : Tool.apps.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(format: NSLocalizedString("Toggle %@ group", comment: ""), title))
            Text(title.uppercased()).font(Brand.mono(9, .bold)).tracking(0.6).foregroundStyle(Brand.textTertiary)
            Text(verbatim: "\(selectedCount)/\(entries.count)")
                .font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
            Spacer()
        }
        .padding(.top, 2)
    }

    private func entryRow(_ entry: UninstallPreview.Entry) -> some View {
        let ticked = pathSelection.contains(entry.path)
        return HStack(spacing: 9) {
            Button {
                if ticked { pathSelection.remove(entry.path) } else { pathSelection.insert(entry.path) }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(ticked ? Tool.apps.accent.opacity(0.9) : Color.white.opacity(0.07))
                        .frame(width: 14, height: 14)
                    if ticked {
                        Image(systemName: "checkmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.black)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Brand.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.path)
            .accessibilityValue(ticked ? NSLocalizedString("selected", comment: "") : NSLocalizedString("not selected", comment: ""))

            Text(entry.kind.label).font(Brand.sans(10, .medium)).foregroundStyle(Brand.textSecondary)
                .frame(width: 96, alignment: .leading)
            Text(entry.path).font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                .lineLimit(1).truncationMode(.middle)
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
        let name = app.uninstallName
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // EOF after the prompt makes --dry-run print the enumeration and exit.
            let res = try? MoEngine.shared.capture(
                MoCommand(target: .mo, args: ["uninstall", "--dry-run", name], stdin: "y\n", timeout: 120))
            let text = Ansi.strip((res?.stdout ?? "") + "\n" + (res?.stderr ?? ""))
            let preview = UninstallPreview.parse(text.components(separatedBy: "\n"))
            Task { @MainActor in
                guard let self else { return }
                self.previewLoading.remove(app.id)
                self.previews[app.id] = preview
                // Default ticks: the auto-selected kinds.
                if self.pathSelections[app.id] == nil {
                    self.pathSelections[app.id] = Set(preview.entries.filter(\.kind.autoSelected).map(\.path))
                }
            }
        }
    }

    private var recentLoaded = false

    /// "Last used" needs a filesystem date per app — only worth it when
    /// the user actually sorts by it.
    private func ensureRecentDates() {
        guard !recentLoaded, !apps.isEmpty else { return }
        recentLoaded = true
        let snapshot = apps
        DispatchQueue.global(qos: .userInitiated).async {
            let dated = snapshot.map { a in
                InstalledApp(id: a.id, name: a.name, bundleId: a.bundleId, source: a.source,
                             uninstallName: a.uninstallName, path: a.path, sizeStr: a.sizeStr,
                             sizeBytes: a.sizeBytes, lastUsed: Self.lastUsedDate(a.path))
            }
            Task { @MainActor in self.apps = dated }
        }
    }

    func load() {
        loading = true
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let parsed = Self.fetch()
            Task { @MainActor in
                self.apps = parsed
                self.loading = false
                self.recentLoaded = false
                self.previews = [:]
                self.pathSelections = [:]
                self.expandedAppID = nil
                if self.sort == .recent { self.ensureRecentDates() }
            }
        }
    }

    private static func fetch() -> [InstalledApp] {
        // `mo uninstall --list` computes a size for every installed app, which can
        // take a while on a full /Applications — the client gives it room.
        let apps = MoleClient.listApps()
        // Pre-warm the icon + version cache here — `fetch` always runs on a
        // background queue, so the per-bundle icon/Info.plist disk reads happen
        // off-main and the rows then render from a pure cache read instead of
        // hitting the disk during layout (Sentry BURROW-20: InstalledApp hang).
        SoftwareIcons.prewarm(apps)
        return apps
    }

    /// Best-effort "last used" from the filesystem (access date, falling back to
    /// modification date). Deliberately NOT Spotlight (`kMDItemLastUsedDate`):
    /// querying metadata for every installed app woke `mds`/`mdworker` and spiked
    /// CPU/energy. Filesystem dates are close enough for the Recent sort and cost
    /// nothing — no metadata server, no indexing.
    private static func lastUsedDate(_ path: String) -> Date? {
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

    func confirmAndUninstall() {
        let targets = selectedApps
        guard !targets.isEmpty else { return }
        let engineApps = targets.filter { !isSubsetRemoval($0) }
        let subsetApps = targets.filter { isSubsetRemoval($0) }

        var bodyLines = engineApps.map { "• \($0.name)" }
        bodyLines += subsetApps.map {
            let count = pathSelections[$0.id]?.count ?? 0
            return "• \($0.name) — \(String(format: NSLocalizedString("%d reviewed files", comment: ""), count))"
        }
        let alert = NSAlert()
        alert.messageText = String(format: NSLocalizedString(targets.count == 1 ? "Remove %d app?" : "Remove %d apps?", comment: ""), targets.count)
        var info = String(format: NSLocalizedString("These move to the Trash (recoverable):\n\n%@", comment: ""),
                          bodyLines.joined(separator: "\n"))
        if !subsetApps.isEmpty {
            info += "\n\n" + NSLocalizedString("Reviewed subsets are trashed by Burrow directly and appear in Burrow's Activity log, not `mo history`.", comment: "")
        }
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Move to Trash", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        guard alert.runModalQuiet() == .alertFirstButtonReturn else { return }

        if !subsetApps.isEmpty { trashSubsets(subsetApps) }
        if !engineApps.isEmpty { engineUninstall(engineApps) }
    }

    /// Burrow trashes exactly the reviewed, ticked paths. Every path is
    /// asserted to come from the engine's own enumeration — the safety
    /// scan decided the candidate set, the review only narrowed it.
    private func trashSubsets(_ apps: [InstalledApp]) {
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
            let paths = ticked.map { ($0 as NSString).expandingTildeInPath }
            return (app, paths)
        }
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

    /// The engine path — `mo uninstall <names>`, Trash-based, with the
    /// matcher pre-flight (audit H4) before any y is answered.
    private func engineUninstall(_ targets: [InstalledApp]) {
        let names = targets.map { $0.uninstallName }
        // The dialog above is the consent; the ticket (argv / stdin /
        // timeout / preflight) is minted by the shared gate — the same
        // truth table and catalog the MCP server uses. (One deliberate
        // change rides along: the catalog's unified 600 s uninstall
        // timeout replaces this view's old 300 s.)
        guard case .run(let ticket) = MoActions.decide(
            .uninstall(apps: names, permanent: false), .real,
            .gui(hasFullDiskAccess: true, userConfirmed: true)) else { return }
        loading = true
        // Surface the run in the menu-bar HUD's Activity section too.
        let opId = UUID()
        OperationCenter.shared.begin(opId, label: "Uninstalling \(targets.count) app\(targets.count == 1 ? "" : "s")",
                                     notifiesOnEnd: true)
        DispatchQueue.global(qos: .userInitiated).async {
            // Pre-flight (audit H4): mo does its own name matching, so before
            // answering any prompt, verify what it MATCHED equals what the
            // user CONFIRMED. `--dry-run` changes nothing and exits at its
            // prompt on stdin EOF; an unparseable result aborts (fail closed).
            let pre = ticket.action.preflightCommand!
            let dry = try? MoEngine.shared.capture(
                MoCommand(target: .mo, args: pre.args, stdin: pre.stdin, timeout: pre.timeout ?? 120))
            let dryText = (dry?.stdout ?? "") + "\n" + (dry?.stderr ?? "")
            let matched = UninstallGuard.matchedApps(inDryRunOutput: dryText)
            let problem: String?
            if let matched {
                problem = UninstallGuard.mismatchDescription(confirmed: names, matched: matched)
            } else {
                problem = NSLocalizedString("couldn't verify which apps mo matched", comment: "")
            }
            if let problem {
                Task { @MainActor in
                    self.loading = false
                    OperationCenter.shared.end(opId, success: false,
                                               detail: NSLocalizedString("aborted — matcher mismatch", comment: ""))
                    let alert = NSAlert()
                    alert.messageText = NSLocalizedString("Uninstall aborted", comment: "")
                    alert.informativeText = String(
                        format: NSLocalizedString("mo's matcher didn't agree with your selection, so nothing was removed.\n\n%@", comment: ""),
                        problem)
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
                    alert.runModalQuiet()
                }
                return
            }

            // Verified — the ticket's stdin answers mo's prompts (proceed +
            // final confirm); they only ever apply to the set the dry run
            // just pinned.
            let res = try? MoEngine.shared.capture(
                MoCommand(target: .mo, args: ticket.command.args, stdin: ticket.command.stdin,
                          timeout: ticket.command.timeout ?? 600))
            let ok = (res?.exitCode ?? 1) == 0

            // FAILURE (#254): the apps are still installed, so there's nothing to re-scan —
            // keep the list AND the selection so the user can retry, and surface the
            // engine's actual error in an alert (the HUD alone can be invisible when the
            // menu-bar icon is off).
            guard ok else {
                let engineError = [res?.stderr, res?.stdout]
                    .compactMap { $0 }
                    .joined(separator: "\n")
                    .components(separatedBy: "\n")
                    .map { Ansi.strip($0).trimmingCharacters(in: .whitespaces) }
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

            let parsed = Self.fetch()
            Task { @MainActor in
                self.apps = parsed
                self.selected = []
                self.loading = false
                // Re-fetched apps have lastUsed == nil; recompute dates if the
                // user is still sorting by Recent (mirror load()), else Recent
                // would silently collapse after an uninstall.
                self.recentLoaded = false
                if self.sort == .recent { self.ensureRecentDates() }
                OperationCenter.shared.end(opId, success: true,
                                           detail: "\(targets.count) moved to Trash")
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
