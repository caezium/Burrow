//
//  OrphansView.swift
//  Burrow
//
//  The Leftovers tab — a conductor-tool surface copying the Duplicates pane's
//  idiom: Analyze's toolbar (up arrow + breadcrumbs + mono summary + icon
//  buttons), the same state ladder (conductorMissing / idle / scanning /
//  error / clean / results), and card-list results. Scanning runs
//  `burrow orphans <dir> --json` off the main thread through the pure
//  OrphansModel parser.
//
//  READ-ONLY v1: rows reveal in Finder, nothing is deleted. The scanner's
//  own volatile-roots policy (never flag Preferences / Keychains / Mail /
//  Containers) plus this pane's no-action stance keep it safe by
//  construction; a review-checklist + Trash flow is the follow-up.
//
//  Degrade: dev/CI builds without the vendor/burrow-cli submodule have no
//  bundled conductor — the pane explains instead of dead-ending.
//

import SwiftUI
import AppKit

struct OrphansView: View {
    @StateObject private var model = OrphansModel()

    var body: some View {
        VStack(spacing: 0) {
            toolbar.padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 12)
            Rectangle().fill(Brand.hairline).frame(height: 1)
            ZStack {
                if !BurrowConductor.isAvailable {
                    conductorMissing
                } else if model.scanning {
                    scanningProgress
                } else if let err = model.error {
                    errorState(err)
                } else if let report = model.report {
                    if report.orphans.isEmpty { cleanState } else { results(report) }
                } else {
                    idleState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Toolbar (Analyze's idiom: up + crumbs + info + icon buttons)

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { model.goUp() } label: {
                Image(systemName: "arrow.up").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.canGoUp ? Brand.textSecondary : Brand.textTertiary.opacity(0.35))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!model.canGoUp)
            .help(NSLocalizedString("Scan the parent folder", comment: ""))

            if model.crumbs.isEmpty {
                Text(NSLocalizedString("Choose a folder to scan", comment: ""))
                    .font(Brand.mono(12)).foregroundStyle(Brand.textTertiary)
            }
            ForEach(Array(model.crumbs.enumerated()), id: \.offset) { idx, crumb in
                if idx > 0 {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Brand.textTertiary)
                }
                Button { model.goToCrumb(idx) } label: {
                    Text(crumb.name)
                        .font(Brand.mono(12, idx == model.crumbs.count - 1 ? .semibold : .regular))
                        .foregroundStyle(idx == model.crumbs.count - 1 ? Brand.textPrimary : Brand.textSecondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if let report = model.report {
                Text(summaryLine(report))
                    .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
            }
            Button { pickFolder() } label: {
                Image(systemName: "folder").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Brand.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(!BurrowConductor.isAvailable)
            .help(NSLocalizedString("Choose a folder…", comment: ""))
            Button { model.rescan() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.folder == nil ? Brand.textTertiary.opacity(0.35) : Brand.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(!BurrowConductor.isAvailable || model.folder == nil || model.scanning)
            .help(NSLocalizedString("Rescan", comment: ""))
        }
    }

    /// "N leftovers · matched against M apps" — the scan's one-line truth.
    private func summaryLine(_ report: OrphansReport) -> String {
        String(format: NSLocalizedString("%d leftovers · matched against %d apps", comment: ""),
               report.orphans.count, report.installedCount)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("Scan", comment: "")
        if let folder = model.folder {
            panel.directoryURL = URL(fileURLWithPath: folder)
        }
        guard CrashReporter.withoutAppHangTracking({ panel.runModal() }) == .OK,
              let url = panel.url else { return }
        model.scan(url.path)
    }

    // MARK: States

    private var conductorMissing: some View {
        VStack(spacing: 10) {
            Image(systemName: "shippingbox").font(.system(size: 26)).foregroundStyle(Brand.textTertiary)
            Text(NSLocalizedString("The bundled burrow conductor is missing", comment: ""))
                .font(Brand.serif(17, .medium)).foregroundStyle(Brand.textPrimary)
            Text(NSLocalizedString("Leftover scanning runs through the bundled `burrow` CLI. This build shipped without it — a dev build without the vendor/burrow-cli submodule. Release builds include it.", comment: ""))
                .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
        }
    }

    private var idleState: some View {
        VStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.questionmark").font(.system(size: 26)).foregroundStyle(Tool.orphans.accent)
            Text(NSLocalizedString("Find what uninstalled apps left behind", comment: ""))
                .font(Brand.serif(17, .medium)).foregroundStyle(Brand.textPrimary)
            Text(NSLocalizedString("Choose a folder and Burrow flags app-shaped caches and logs that match nothing installed. Read-only — nothing is deleted; review the evidence and reveal anything in Finder.", comment: ""))
                .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
            HStack(spacing: 8) {
                quickChip(NSLocalizedString("Caches", comment: ""),
                          path: NSHomeDirectory() + "/Library/Caches")
                quickChip(NSLocalizedString("Logs", comment: ""),
                          path: NSHomeDirectory() + "/Library/Logs")
                Button { pickFolder() } label: {
                    Text(NSLocalizedString("Choose a folder…", comment: ""))
                        .font(Brand.sans(12, .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(.white))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
    }

    /// One-tap scan target for the usual leftover haunts.
    private func quickChip(_ label: String, path: String) -> some View {
        Button { model.scan(path) } label: {
            Text(label)
                .font(Brand.sans(12, .semibold)).foregroundStyle(Brand.textPrimary)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help((path as NSString).abbreviatingWithTildeInPath)
    }

    private var scanningProgress: some View {
        VStack(spacing: 12) {
            Text(NSLocalizedString("Hunting leftovers", comment: ""))
                .font(Brand.serif(18, .medium)).foregroundStyle(Brand.textPrimary)
            HStack(spacing: 8) {
                PulsingDot(color: Tool.orphans.accent)
                Text((model.folder.map { ($0 as NSString).abbreviatingWithTildeInPath }) ?? "")
                    .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 380)
            }
            Text(NSLocalizedString("Matching folder contents against your installed apps.", comment: ""))
                .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NSLocalizedString("Scanning for leftovers", comment: ""))
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 22)).foregroundStyle(Brand.orange)
            Text(message).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 340)
        }
    }

    private var cleanState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle").font(.system(size: 24)).foregroundStyle(Tool.orphans.accent)
            Text(NSLocalizedString("No leftovers here", comment: ""))
                .font(Brand.serif(17, .medium)).foregroundStyle(Brand.textPrimary)
            Text(NSLocalizedString("Everything in this folder matches an installed app.", comment: ""))
                .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
        }
    }

    // MARK: Results (confidence-tiered card list, strongest first)

    private func results(_ report: OrphansReport) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(NSLocalizedString("Review leftovers", comment: ""))
                        .font(Brand.serif(22, .medium)).foregroundStyle(Brand.textPrimary)
                    Text(NSLocalizedString("App-shaped files that match nothing installed. Read-only — hover a badge for the evidence, reveal anything in Finder before you act on it.", comment: ""))
                        .font(Brand.sans(11)).foregroundStyle(Brand.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(tiers(report), id: \.name) { tier in
                        tierCard(tier.name, hits: tier.hits)
                    }
                    Color.clear.frame(height: 16)
                }
                .padding(.horizontal, 18).padding(.bottom, 6)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// Group the (already rank-sorted) hits into contiguous confidence tiers.
    private func tiers(_ report: OrphansReport) -> [(name: String, hits: [OrphanHit])] {
        var out: [(name: String, hits: [OrphanHit])] = []
        for hit in report.orphans {
            if let last = out.indices.last, out[last].name == hit.confidence {
                out[last].hits.append(hit)
            } else {
                out.append((name: hit.confidence, hits: [hit]))
            }
        }
        return out
    }

    private func tierTitle(_ confidence: String) -> String {
        switch confidence {
        case "medium": return NSLocalizedString("Likely leftovers", comment: "orphan tier")
        case "low":    return NSLocalizedString("Possible leftovers", comment: "orphan tier")
        case "weak":   return NSLocalizedString("Faint traces", comment: "orphan tier")
        default:       return confidence
        }
    }

    private func tierCard(_ confidence: String, hits: [OrphanHit]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(tierTitle(confidence))
                    .font(Brand.sans(13, .semibold)).foregroundStyle(Brand.textPrimary)
                confidenceBadge(confidence)
                Spacer()
                Text(String(format: NSLocalizedString("%d items", comment: ""), hits.count))
                    .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
            }
            .padding(13)
            Rectangle().fill(Brand.hairline).frame(height: 1).padding(.horizontal, 13)
            VStack(spacing: 0) {
                ForEach(hits) { hitRow($0) }
            }
            .padding(.vertical, 4)
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.hairline, lineWidth: 1))
    }

    private func confidenceBadge(_ confidence: String) -> some View {
        Text(confidence)
            .font(Brand.mono(9, .medium)).foregroundStyle(Tool.orphans.accent)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Capsule().fill(Tool.orphans.accent.opacity(0.16)))
    }

    private func hitRow(_ hit: OrphanHit) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 13)).foregroundStyle(Tool.orphans.accent)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.name)
                    .font(Brand.sans(12)).foregroundStyle(Brand.textPrimary)
                    .lineLimit(1)
                Text((hit.path as NSString).abbreviatingWithTildeInPath)
                    .font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if !hit.evidence.isEmpty {
                Image(systemName: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(Brand.textTertiary)
                    .help(String(format: NSLocalizedString("Why it's flagged: %@", comment: ""),
                                 hit.evidence.joined(separator: " · ")))
            }
            Button { AnalyzeIcons.reveal(hit.path) } label: {
                Image(systemName: "magnifyingglass.circle")
                    .font(.system(size: 12)).foregroundStyle(Brand.textTertiary)
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("Reveal in Finder", comment: ""))
        }
        .padding(.horizontal, 13).padding(.vertical, 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: NSLocalizedString("%@, %@ confidence", comment: ""),
                                   hit.name, hit.confidence))
    }
}

// MARK: - Model

@MainActor
final class OrphansModel: ObservableObject {
    /// The chosen folder (absolute path). Scans re-run against this.
    @Published var folder: String?
    @Published var scanning = false
    @Published var report: OrphansReport?
    @Published var error: String?

    private let opId = UUID()
    /// Monotonic token (same pattern as DupesModel.scanGen): only the newest
    /// scan's result may land.
    private var scanGen = 0

    // MARK: Breadcrumbs (Analyze's idiom over the scanned folder)

    var crumbs: [(name: String, path: String)] {
        guard let folder else { return [] }
        let ns = folder as NSString
        var paths: [String] = []
        var current = ns as String
        while current != "/" && !current.isEmpty {
            paths.append(current)
            current = (current as NSString).deletingLastPathComponent
            if paths.count > 6 { break } // keep the bar sane on deep paths
        }
        return paths.reversed().map { p in
            let abbrev = (p as NSString).abbreviatingWithTildeInPath
            let name = abbrev == "~" ? "~" : (p as NSString).lastPathComponent
            return (name: name, path: p)
        }
    }

    var canGoUp: Bool {
        guard let folder else { return false }
        return (folder as NSString).deletingLastPathComponent != folder
            && folder != NSHomeDirectory() && folder != "/"
    }

    func goUp() {
        guard let folder, canGoUp else { return }
        scan((folder as NSString).deletingLastPathComponent)
    }

    func goToCrumb(_ idx: Int) {
        let c = crumbs
        guard idx < c.count, c[idx].path != folder else { return }
        scan(c[idx].path)
    }

    /// Re-run against the current folder (the toolbar's rescan button).
    func rescan() {
        guard let folder else { return }
        scan(folder)
    }

    /// Scan `path` via the bundled conductor, off the main thread. The
    /// envelope's `data` is the orphans report, decoded by the pure
    /// OrphansReport.parse.
    func scan(_ path: String) {
        folder = path
        scanGen += 1
        let gen = scanGen
        scanning = true
        error = nil
        report = nil
        let name = (path as NSString).lastPathComponent
        OperationCenter.shared.begin(opId, label: String(format: NSLocalizedString("Finding leftovers in %@", comment: ""), name))
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Result<OrphansReport, Error>
            do {
                let envelope = try BurrowConductor.capture("orphans", [path], timeout: 300)
                guard let data = envelope.data, let parsed = OrphansReport.parse(data) else {
                    throw BurrowConductorError.engine(
                        kind: "error",
                        message: NSLocalizedString("burrow orphans returned an unreadable report", comment: ""))
                }
                outcome = .success(parsed)
            } catch {
                outcome = .failure(error)
            }
            Task { @MainActor in
                guard gen == self.scanGen else { return }
                self.scanning = false
                switch outcome {
                case .success(let r):
                    self.report = r
                    OperationCenter.shared.end(self.opId, success: true,
                                               detail: String(format: NSLocalizedString("%d leftovers", comment: ""),
                                                              r.orphans.count))
                case .failure(let e):
                    self.error = e.localizedDescription
                    OperationCenter.shared.end(self.opId, success: false,
                                               detail: NSLocalizedString("scan failed", comment: ""))
                }
            }
        }
    }
}
