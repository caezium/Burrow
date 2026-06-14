//
//  UpdatesView.swift
//  Burrow
//
//  The Software → Updates pane (design 2.3): one unified list across
//  update mechanisms with per-source badges — Sparkle, App Store,
//  Electron, Homebrew — split into "Updates available" / "Up to date" /
//  "Not checkable". Source detection is local bundle inspection (free);
//  version checks contact Apple / vendor appcast servers, so they run
//  ONLY when the user clicks Check — never silently (the network story
//  in SECURITY.md depends on this).
//
//  v1 actions are deep-links: Sparkle/Electron apps open themselves
//  (their own updater takes it from there), App Store opens the product
//  page, Homebrew upgrades inline as before.
//

import SwiftUI
import AppKit

struct OutdatedItem: Identifiable {
    let id: String
    let name: String
    let installed: String
    let latest: String
    let kind: String   // "formula" | "cask"
}

/// One GUI app in the unified list.
struct AppUpdateItem: Identifiable {
    let id: String
    let name: String
    let path: String
    let bundleID: String
    let installedVersion: String
    let sizeStr: String
    let source: UpdateSources.Source
    var latestVersion: String?
    var pageURL: URL?
    var lastUsed: Date?

    var updateAvailable: Bool {
        guard let latest = latestVersion else { return false }
        return UpdateCheck.isNewer(latest, than: installedVersion)
    }
}

struct UpdatesView: View {
    @ObservedObject var model: UpdatesModel
    var apps: [InstalledApp] = []

    var body: some View {
        Group {
            if model.checking && model.appItems.isEmpty {
                center { ProgressView("Checking update sources…").controlSize(.large).tint(Tool.apps.accent).font(Brand.mono(11)) }
            } else {
                VStack(spacing: 0) {
                    header.padding(.horizontal, 18).padding(.vertical, 11)
                    Rectangle().fill(Brand.hairline).frame(height: 1)
                    list
                }
            }
        }
        .onAppear { model.prepare(apps: apps) }
        .onChange(of: apps.count) { _, _ in model.prepare(apps: apps) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if model.checked {
                let n = model.availableItems.count + model.brewItems.count
                Text(String(format: NSLocalizedString(n == 1 ? "%d update" : "%d updates", comment: ""), n))
                    .font(Brand.mono(12)).foregroundStyle(Brand.textSecondary)
            } else {
                Text("Sources detected locally — checking versions contacts Apple and vendor servers.")
                    .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
            }
            Spacer()
            if model.checking {
                ProgressView().controlSize(.small)
            }
            PillButton(title: model.checked ? "Check again" : "Check for updates", filled: !model.checked) {
                model.checkNow()
            }
            if model.checked, !model.brewItems.isEmpty {
                PillButton(title: model.upgrading.isEmpty ? "Update all brews" : "Updating…", filled: false) {
                    model.upgradeAll()
                }
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.checked, model.availableItems.isEmpty, model.brewItems.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 30)).foregroundStyle(Brand.green)
                        Text("Everything's up to date").font(Brand.serif(18)).foregroundStyle(Brand.textPrimary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 36)
                }
                if model.checked, !model.availableItems.isEmpty || !model.brewItems.isEmpty {
                    sectionHeader(NSLocalizedString("Updates available", comment: ""),
                                  count: model.availableItems.count + model.brewItems.count)
                    ForEach(model.availableItems) { appRow($0) }
                    ForEach(model.brewItems) { brewRow($0) }
                }
                if model.checked, !model.upToDateItems.isEmpty {
                    sectionHeader(NSLocalizedString("Up to date", comment: ""), count: model.upToDateItems.count)
                    ForEach(model.upToDateItems) { appRow($0) }
                }
                if !model.checked {
                    sectionHeader(NSLocalizedString("Apps with an update mechanism", comment: ""), count: model.appItems.count)
                    ForEach(model.appItems) { appRow($0) }
                }
                if !model.uncheckableApps.isEmpty {
                    sectionHeader(NSLocalizedString("Not checkable", comment: ""), count: model.uncheckableApps.count)
                    Text("No App Store receipt, Sparkle feed, or known updater inside these bundles.")
                        .font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                        .padding(.horizontal, 14).padding(.bottom, 4)
                    ForEach(model.uncheckableApps, id: \.id) { app in
                        plainRow(app)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
        }
        .scrollIndicators(.visible)
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).font(Brand.mono(10, .bold)).tracking(0.7).foregroundStyle(Brand.textTertiary)
            Text(verbatim: "\(count)").font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 6)
    }

    // MARK: Rows

    private func appRow(_ item: AppUpdateItem) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: SoftwareIcons.icon(item.path)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 7) {
                    Text(item.name).font(Brand.sans(13, .medium)).foregroundStyle(Brand.textPrimary).lineLimit(1)
                    Chip(text: item.source.badge, color: Brand.textSecondary)
                }
                metaLine(version: item.installedVersion, latest: item.latestVersion,
                         size: item.sizeStr, lastUsed: item.lastUsed)
            }
            Spacer(minLength: 8)
            if item.updateAvailable {
                Button { model.update(item) } label: {
                    Text("Update").font(Brand.sans(11, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(Tool.apps.accent))
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    private func brewRow(_ item: OutdatedItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.kind == "cask" ? "macwindow" : "shippingbox")
                .font(.system(size: 14)).foregroundStyle(Tool.apps.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 7) {
                    Text(item.name).font(Brand.sans(13, .medium)).foregroundStyle(Brand.textPrimary).lineLimit(1)
                    Chip(text: UpdateSources.Source.homebrew.badge, color: Brand.textSecondary)
                }
                Text(verbatim: "\(item.installed) → \(item.latest)")
                    .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
            }
            Spacer(minLength: 8)
            if model.upgrading.contains(item.id) {
                ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 64)
            } else {
                Button { model.upgrade(item) } label: {
                    Text("Update").font(Brand.sans(11, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(Tool.apps.accent))
                }.buttonStyle(.plain).frame(width: 64)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private func plainRow(_ app: InstalledApp) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: SoftwareIcons.icon(app.path)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(Brand.sans(13, .medium)).foregroundStyle(Brand.textPrimary).lineLimit(1)
                Text(verbatim: "\(SoftwareIcons.version(app.path).map { "v\($0)" } ?? "—") · \(app.sizeStr)")
                    .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    /// `version · size · active 7 months ago` — recency phrase amber when stale.
    private func metaLine(version: String, latest: String?, size: String, lastUsed: Date?) -> some View {
        let versionText = latest.map { l in
            UpdateCheck.isNewer(l, than: version) ? "v\(version) → v\(l)" : "v\(version)"
        } ?? "v\(version)"
        let recency = Self.recencyPhrase(lastUsed)
        let stale = Self.isStale(lastUsed)
        return HStack(spacing: 0) {
            Text(verbatim: "\(versionText) · \(size) · ")
                .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
            Text(recency)
                .font(Brand.mono(10)).foregroundStyle(stale ? Brand.amber : Brand.textTertiary)
        }
    }

    static func recencyPhrase(_ date: Date?) -> String {
        guard let date else { return NSLocalizedString("never opened", comment: "") }
        let interval = Date().timeIntervalSince(date)
        if interval < 3600 { return NSLocalizedString("active now", comment: "") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return String(format: NSLocalizedString("opened %@", comment: "recency"),
                      formatter.localizedString(for: date, relativeTo: Date()))
    }

    static func isStale(_ date: Date?) -> Bool {
        guard let date else { return true }
        return Date().timeIntervalSince(date) > 30 * 86_400
    }

    private func center<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack { Spacer(); content(); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
final class UpdatesModel: ObservableObject {
    @Published var appItems: [AppUpdateItem] = []
    @Published var uncheckableApps: [InstalledApp] = []
    @Published var brewItems: [OutdatedItem] = []
    @Published var checking = false
    @Published var checked = false
    @Published var error: String?
    @Published var upgrading: Set<String> = []
    private var preparedCount = -1

    var availableItems: [AppUpdateItem] { appItems.filter(\.updateAvailable) }
    var upToDateItems: [AppUpdateItem] {
        appItems.filter { !$0.updateAvailable && $0.latestVersion != nil }
    }

    /// Local-only pass: detect each app's update mechanism from bundle
    /// shape. No network.
    func prepare(apps: [InstalledApp]) {
        guard apps.count != preparedCount else { return }
        preparedCount = apps.count
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var detected: [AppUpdateItem] = []
            var unknown: [InstalledApp] = []
            for app in apps {
                if let source = UpdateSources.detect(appPath: app.path) {
                    detected.append(AppUpdateItem(
                        id: app.id, name: app.name, path: app.path, bundleId: app.bundleId, app: app, source: source))
                } else {
                    unknown.append(app)
                }
            }
            Task { @MainActor in
                self?.appItems = detected
                self?.uncheckableApps = unknown
            }
        }
    }

    /// The manual check: Sparkle appcasts + iTunes lookups + brew
    /// outdated, bounded concurrency.
    func checkNow() {
        guard !checking else { return }
        checking = true
        error = nil
        let items = appItems
        Task {
            var updated: [AppUpdateItem] = []
            await withTaskGroup(of: AppUpdateItem.self) { group in
                var iterator = items.makeIterator()
                var inFlight = 0
                func enqueue(_ item: AppUpdateItem) {
                    group.addTask { await Self.check(item) }
                }
                while inFlight < 6, let next = iterator.next() { enqueue(next); inFlight += 1 }
                for await result in group {
                    updated.append(result)
                    if let next = iterator.next() { enqueue(next) }
                }
            }
            let brews = await Self.brewOutdated()
            await MainActor.run {
                self.appItems = updated.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                self.brewItems = brews
                self.checking = false
                self.checked = true
            }
        }
        // Recency for the meta line, cheap filesystem dates.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var dates: [String: Date] = [:]
            for item in items {
                let url = URL(fileURLWithPath: item.path)
                if let vals = try? url.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey]) {
                    dates[item.id] = vals.contentAccessDate ?? vals.contentModificationDate
                }
            }
            Task { @MainActor in
                guard let self else { return }
                self.appItems = self.appItems.map { item in
                    var copy = item
                    copy.lastUsed = dates[item.id]
                    return copy
                }
            }
        }
    }

    private static func check(_ item: AppUpdateItem) async -> AppUpdateItem {
        var result = item
        switch item.source {
        case .sparkle:
            guard let feed = UpdateSources.feedURL(appPath: item.path),
                  let data = await fetch(feed) else { return result }
            result.latestVersion = UpdateSources.parseAppcast(data)
        case .appStore:
            guard !item.bundleID.isEmpty,
                  let data = await fetch(UpdateSources.itunesLookupURL(bundleID: item.bundleID)),
                  let lookup = UpdateSources.parseITunesLookup(data) else { return result }
            result.latestVersion = lookup.version
            result.pageURL = lookup.pageURL
        case .electron, .homebrew:
            break   // v1: badge only; their own updaters handle it
        }
        return result
    }

    private static func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        return try? await URLSession.shared.data(for: request).0
    }

    /// v1 update action per source: deep-link the right updater.
    func update(_ item: AppUpdateItem) {
        switch item.source {
        case .sparkle, .electron:
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: item.path),
                                               configuration: NSWorkspace.OpenConfiguration())
        case .appStore:
            if let page = item.pageURL { NSWorkspace.shared.open(page) }
            else { NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!) }
        case .homebrew:
            break
        }
    }

    // MARK: Homebrew (the existing flow)

    func upgrade(_ item: OutdatedItem) {
        guard let brew = Self.brewPath() else { return }
        // Already upgrading (this row, or an upgrade-all in flight): a
        // second concurrent `brew` just trips over brew's own lock.
        guard !upgrading.contains(item.id) else { return }
        upgrading.insert(item.id)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Self.runBrew(brew, ["upgrade", item.name], timeout: 1800)
            Task { @MainActor in
                self.upgrading.remove(item.id)
                self.brewItems = await Self.brewOutdated()
            }
        }
    }

    func upgradeAll() {
        guard let brew = Self.brewPath() else { return }
        guard upgrading.isEmpty else { return }
        let ids = Set(brewItems.map(\.id))
        upgrading.formUnion(ids)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Self.runBrew(brew, ["upgrade"], timeout: 3600)
            Task { @MainActor in
                self.upgrading.subtract(ids)
                self.brewItems = await Self.brewOutdated()
            }
        }
    }

    private static func brewOutdated() async -> [OutdatedItem] {
        guard let brew = brewPath() else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let r = runBrew(brew, ["outdated", "--json=v2"])
            return parseOutdated(r.out)
        }.value
    }

    nonisolated static func brewPath() -> String? {
        for p in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    private struct BrewResult { let out: String; let err: String; let code: Int32 }

    private nonisolated static func runBrew(_ brew: String, _ args: [String], timeout: TimeInterval = 120) -> BrewResult {
        var env = Foundation.ProcessInfo.processInfo.environment
        let dir = (brew as NSString).deletingLastPathComponent
        env["PATH"] = "\(dir):/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        do {
            let result = try MoEngine.shared.capture(
                MoCommand(target: .executable(brew), args: args,
                          environment: env, timeout: timeout))
            return BrewResult(out: result.stdout, err: result.stderr, code: result.exitCode)
        } catch {
            return BrewResult(out: "", err: "\(error)", code: -1)
        }
    }

    /// Pure parser for `brew outdated --json=v2` — unit-tested against captured
    /// brew output, like the other `mo`/CLI parsers.
    nonisolated static func parseOutdated(_ json: String) -> [OutdatedItem] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: [OutdatedItem] = []
        func add(_ arr: [[String: Any]]?, kind: String) {
            for d in arr ?? [] {
                guard let name = d["name"] as? String else { continue }
                let installed = (d["installed_versions"] as? [String])?.first ?? "?"
                let latest = d["current_version"] as? String ?? "?"
                out.append(OutdatedItem(id: "\(kind):\(name)", name: name,
                                        installed: installed, latest: latest, kind: kind))
            }
        }
        add(root["formulae"] as? [[String: Any]], kind: "formula")
        add(root["casks"] as? [[String: Any]], kind: "cask")
        return out
    }
}

private extension AppUpdateItem {
    init(id: String, name: String, path: String, bundleId: String,
         app: InstalledApp, source: UpdateSources.Source) {
        self.init(id: id, name: name, path: path, bundleID: bundleId,
                  installedVersion: SoftwareIcons.version(path) ?? "0",
                  sizeStr: app.sizeStr, source: source,
                  latestVersion: nil, pageURL: nil, lastUsed: nil)
    }
}
