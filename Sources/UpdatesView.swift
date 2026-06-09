//
//  UpdatesView.swift
//  Burrow
//
//  The Software → Updates pane. mole.fit checks Sparkle / Homebrew / Mac
//  App Store; Burrow does the part it can do cleanly today: Homebrew
//  (`brew outdated --json=v2`) with per-item and "update all" upgrades.
//  Casks that auto-update are skipped by brew (they update themselves);
//  `mas` isn't assumed installed, so MAS updates are out of scope here.
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

struct UpdatesView: View {
    @ObservedObject var model: UpdatesModel

    var body: some View {
        Group {
            if model.loading && model.items.isEmpty {
                center { ProgressView("Checking Homebrew…").controlSize(.large).tint(Tool.apps.accent).font(Brand.mono(11)) }
            } else if let e = model.error {
                center {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 26)).foregroundStyle(Brand.orange)
                        Text(e).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                            .multilineTextAlignment(.center).frame(maxWidth: 360)
                    }
                }
            } else if model.items.isEmpty {
                center {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 30)).foregroundStyle(Brand.green)
                        Text("Everything's up to date").font(Brand.serif(18)).foregroundStyle(Brand.textPrimary)
                        Text("Homebrew formulae & casks").font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    header.padding(.horizontal, 18).padding(.vertical, 11)
                    Rectangle().fill(Brand.hairline).frame(height: 1)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.items) { item in
                                row(item)
                                Rectangle().fill(Brand.hairline).frame(height: 1).padding(.leading, 44)
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 4)
                    }
                }
            }
        }
        .onAppear { model.startIfNeeded() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(String(format: NSLocalizedString(model.items.count == 1 ? "%d update" : "%d updates", comment: ""), model.items.count))
                .font(Brand.mono(12)).foregroundStyle(Brand.textSecondary)
            Spacer()
            Button { model.reload() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.textSecondary)
            }.buttonStyle(.plain)
            PillButton(title: model.upgrading.isEmpty ? "Update all" : "Updating…") {
                model.upgradeAll()
            }
        }
    }

    private func row(_ item: OutdatedItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.kind == "cask" ? "macwindow" : "shippingbox")
                .font(.system(size: 14)).foregroundStyle(Tool.apps.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(Brand.sans(13, .medium)).foregroundStyle(Brand.textPrimary).lineLimit(1)
                Text("\(item.installed) → \(item.latest)").font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
            }
            Spacer(minLength: 8)
            Chip(text: item.kind, color: Brand.textSecondary)
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
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private func center<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack { Spacer(); content(); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
final class UpdatesModel: ObservableObject {
    @Published var items: [OutdatedItem] = []
    @Published var loading = false
    @Published var error: String?
    @Published var upgrading: Set<String> = []
    private var started = false

    func startIfNeeded() { if !started { started = true; reload() } }

    func reload() {
        guard let brew = Self.brewPath() else {
            error = NSLocalizedString("Homebrew (`brew`) not found on this Mac.", comment: "")
            return
        }
        loading = true; error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Self.runBrew(brew, ["outdated", "--json=v2"])
            let parsed = Self.parseOutdated(r.out)
            Task { @MainActor in
                if r.code != 0 && parsed.isEmpty && !r.err.isEmpty {
                    self.error = String(r.err.prefix(160))
                }
                self.items = parsed
                self.loading = false
            }
        }
    }

    func upgrade(_ item: OutdatedItem) {
        guard let brew = Self.brewPath() else { return }
        upgrading.insert(item.id)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Self.runBrew(brew, ["upgrade", item.name], timeout: 1800)
            Task { @MainActor in self.upgrading.remove(item.id); self.reload() }
        }
    }

    func upgradeAll() {
        guard let brew = Self.brewPath() else { return }
        let ids = Set(items.map(\.id))
        upgrading.formUnion(ids)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Self.runBrew(brew, ["upgrade"], timeout: 3600)
            Task { @MainActor in self.upgrading.subtract(ids); self.reload() }
        }
    }

    static func brewPath() -> String? {
        for p in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    private struct BrewResult { let out: String; let err: String; let code: Int32 }

    private static func runBrew(_ brew: String, _ args: [String], timeout: TimeInterval = 120) -> BrewResult {
        var env = Foundation.ProcessInfo.processInfo.environment
        let dir = (brew as NSString).deletingLastPathComponent
        env["PATH"] = "\(dir):/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        do {
            let result = try MoleProcess.capture(
                executable: brew,
                args: args,
                environment: env,
                timeout: timeout
            )
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
