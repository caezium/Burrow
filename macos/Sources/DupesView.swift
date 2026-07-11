//
//  DupesView.swift
//  Burrow
//
//  The Duplicates tab (Phase 6.2) — the first conductor-tool surface. Pick a
//  folder, run `burrow dupes <dir> --json` off the main thread, and read the
//  fclones group report through the pure DupesModel parser: a summary line
//  ("N groups · X reclaimable") over a list of groups, each showing every
//  identical copy. READ-ONLY v1 — no delete/dedupe from the GUI yet; the
//  footnote points at the CLI command that acts.
//
//  Degrade: dev/CI builds without the vendor/burrow-cli submodule have no
//  bundled conductor (`BurrowConductor.isAvailable == false`) — the pane
//  shows an explanatory empty state instead of a dead Scan button.
//

import SwiftUI
import AppKit

struct DupesView: View {
    @StateObject private var model = DupesModel()

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
                    if report.groups.isEmpty { cleanState } else { results(report) }
                } else {
                    idleState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { pickFolder() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 11, weight: .semibold))
                    Text(model.folder.map { ($0 as NSString).abbreviatingWithTildeInPath }
                         ?? NSLocalizedString("Choose a folder…", comment: ""))
                        .font(Brand.mono(11)).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 340, alignment: .leading)
                }
                .foregroundStyle(Brand.textSecondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Color.black.opacity(0.22)))
                .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!BurrowConductor.isAvailable)
            .help(NSLocalizedString("Choose the folder to scan for duplicates", comment: ""))

            Button { model.rescan() } label: {
                Text(NSLocalizedString("Scan", comment: ""))
                    .font(Brand.sans(12, .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(.white))
            }
            .buttonStyle(.plain)
            .disabled(!BurrowConductor.isAvailable || model.folder == nil || model.scanning)

            // Act: clone-dedupe the scanned folder. Explain-before-act — this runs the
            // conductor's PREVIEW first and confirms with fclones' own plan; only the
            // confirm dialog triggers --apply. Enabled only when a scan found waste.
            if let report = model.report, !report.groups.isEmpty {
                Button { startDedupe(report) } label: {
                    Text(String(format: NSLocalizedString("Reclaim %@…", comment: ""),
                                Fmt.bytes(report.redundantBytes)))
                        .font(Brand.sans(12, .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(Tool.dupes.accent))
                }
                .buttonStyle(.plain)
                .disabled(model.scanning || model.deduping)
                .help(NSLocalizedString("Deduplicate with APFS clones — every path stays, the copies share storage. Nothing is deleted.", comment: ""))
            }

            if model.scanning || model.deduping { ProgressView().controlSize(.small) }
            Spacer()
            if let report = model.report {
                Text(summaryLine(report))
                    .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
            }
        }
    }

    /// Preview -> confirm -> apply. The dialog shows fclones' own dry-run plan (the exact
    /// `cp -c` clones --apply will make) so consent is informed, and repeats the safety
    /// property: paths stay, bytes get shared, nothing is deleted.
    private func startDedupe(_ report: DupesReport) {
        model.dedupePreview { preview in
            guard let preview else { return } // model.error carries the reason
            let alert = NSAlert()
            if preview.skipped || preview.plan.isEmpty {
                alert.messageText = NSLocalizedString("Nothing to deduplicate", comment: "")
                alert.informativeText = NSLocalizedString("Every duplicate here is protected, cross-volume, or already a clone — there is nothing safe to reclaim.", comment: "")
                alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
                alert.runModalQuiet()
                return
            }
            alert.messageText = String(
                format: NSLocalizedString("Reclaim %@ by clone-deduplicating?", comment: ""),
                Fmt.bytes(report.redundantBytes))
            let shown = preview.plan.prefix(6).map { "  " + $0 }.joined(separator: "\n")
            let more = preview.plan.count > 6
                ? "\n" + String(format: NSLocalizedString("  …and %d more", comment: ""), preview.plan.count - 6)
                : ""
            alert.informativeText = String(
                format: NSLocalizedString("%d groups become APFS clones — every file keeps its path and contents; the copies share storage. Nothing is deleted, and edits to one copy no longer affect the others.\n\nPlanned clones:\n%@%@", comment: ""),
                preview.groups, shown, more)
            alert.alertStyle = .warning
            alert.addButton(withTitle: NSLocalizedString("Reclaim", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            guard alert.runModalQuiet() == .alertFirstButtonReturn else { return }
            model.dedupeApply()
        }
    }

    /// "N groups · X reclaimable" — the one number this pane exists for.
    private func summaryLine(_ report: DupesReport) -> String {
        String(format: NSLocalizedString("%d groups · %@ reclaimable", comment: ""),
               report.groups.count, Fmt.bytes(report.redundantBytes))
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

    /// Dev/CI build without the bundled conductor — explain rather than dead-end.
    private var conductorMissing: some View {
        VStack(spacing: 10) {
            Image(systemName: "shippingbox").font(.system(size: 26)).foregroundStyle(Brand.textTertiary)
            Text(NSLocalizedString("The bundled burrow conductor is missing", comment: ""))
                .font(Brand.serif(17, .medium)).foregroundStyle(Brand.textPrimary)
            Text(NSLocalizedString("Duplicate scanning runs through the bundled `burrow` CLI. This build shipped without it — a dev build without the vendor/burrow-cli submodule. Release builds include it.", comment: ""))
                .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
        }
    }

    private var idleState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.on.doc").font(.system(size: 26)).foregroundStyle(Tool.dupes.accent)
            Text(NSLocalizedString("Find what you've stashed twice", comment: ""))
                .font(Brand.serif(17, .medium)).foregroundStyle(Brand.textPrimary)
            Text(NSLocalizedString("Choose a folder and Burrow finds byte-identical copies — downloads saved twice, exports duplicated across projects — and totals what one-of-each would reclaim.", comment: ""))
                .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            Button { pickFolder() } label: {
                Text(NSLocalizedString("Choose a folder…", comment: ""))
                    .font(Brand.sans(12, .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(.white))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
    }

    private var scanningProgress: some View {
        VStack(spacing: 12) {
            Text(NSLocalizedString("Hunting duplicates", comment: ""))
                .font(Brand.serif(18, .medium)).foregroundStyle(Brand.textPrimary)
            HStack(spacing: 8) {
                PulsingDot(color: Tool.dupes.accent)
                Text((model.folder.map { ($0 as NSString).abbreviatingWithTildeInPath }) ?? "")
                    .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 380)
            }
            Text(NSLocalizedString("Hashing candidate files — large folders can take a minute.", comment: ""))
                .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NSLocalizedString("Scanning for duplicates", comment: ""))
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
            Image(systemName: "checkmark.circle").font(.system(size: 24)).foregroundStyle(Tool.dupes.accent)
            Text(NSLocalizedString("No duplicates here", comment: ""))
                .font(Brand.serif(17, .medium)).foregroundStyle(Brand.textPrimary)
            Text(NSLocalizedString("Every file in this folder is one of a kind.", comment: ""))
                .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
        }
    }

    // MARK: Results

    private func results(_ report: DupesReport) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 10) {
                    // Cap the rendered groups; a pathological folder can carry
                    // thousands and the biggest wins are already sorted first.
                    ForEach(report.groups.prefix(200)) { groupCard($0) }
                    if report.groups.count > 200 {
                        Text(String(format: NSLocalizedString("…and %d smaller groups. Narrow the folder to see them.", comment: ""),
                                    report.groups.count - 200))
                            .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
            }
            .scrollIndicators(.hidden)
            Rectangle().fill(Brand.hairline).frame(height: 1)
            footnote
        }
    }

    private func groupCard(_ group: DupeGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(Fmt.bytes(group.fileLen))
                    .font(Brand.mono(12, .bold)).foregroundStyle(Brand.textPrimary)
                Text(String(format: NSLocalizedString("× %d copies", comment: ""), group.files.count))
                    .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                Spacer()
                Text(String(format: NSLocalizedString("%@ reclaimable", comment: ""), Fmt.bytes(group.redundantBytes)))
                    .font(Brand.mono(10, .semibold)).foregroundStyle(Tool.dupes.accent)
            }
            ForEach(group.files, id: \.self) { path in
                HStack(spacing: 6) {
                    Image(systemName: "doc").font(.system(size: 9)).foregroundStyle(Brand.textTertiary)
                    Text((path as NSString).abbreviatingWithTildeInPath)
                        .font(Brand.mono(10)).foregroundStyle(Brand.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contextMenu {
                    Button(NSLocalizedString("Reveal in Finder", comment: "")) { AnalyzeIcons.reveal(path) }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.hairline, lineWidth: 1))
    }

    /// Reclaim clones in place (non-destructive); DELETING extra copies stays CLI-only,
    /// where reference folders can be protected explicitly.
    private var footnote: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(Brand.textTertiary)
            (Text(NSLocalizedString("Reclaim uses APFS clones — nothing is deleted. To delete extra copies instead (keep-one, preview-first): ", comment: ""))
                + Text(verbatim: "burrow dupes remove <dir> --keep <ref> --apply").bold())
                .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
            Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
    }
}

// MARK: - Model

@MainActor
final class DupesModel: ObservableObject {
    /// The chosen folder (absolute path). Scans re-run against this.
    @Published var folder: String?
    @Published var scanning = false
    @Published var deduping = false
    @Published var report: DupesReport?
    @Published var error: String?

    private let opId = UUID()
    /// Monotonic token (same pattern as AnalyzeModel.scanGen): only the
    /// newest scan's result may land — a slow walk of a huge folder must
    /// not clobber a scan the user has since restarted elsewhere.
    private var scanGen = 0

    /// Re-run against the current folder (the toolbar's Scan button).
    func rescan() {
        guard let folder else { return }
        scan(folder)
    }

    /// Scan `path` via the bundled conductor, off the main thread. The
    /// envelope's `data` is fclones' group report, decoded by the pure
    /// DupesReport.parse.
    func scan(_ path: String) {
        folder = path
        scanGen += 1
        let gen = scanGen
        scanning = true
        error = nil
        report = nil
        let name = (path as NSString).lastPathComponent
        OperationCenter.shared.begin(opId, label: String(format: NSLocalizedString("Finding duplicates in %@", comment: ""), name))
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Result<DupesReport, Error>
            do {
                let envelope = try BurrowConductor.capture("dupes", [path], timeout: 300)
                guard let data = envelope.data, let parsed = DupesReport.parse(data) else {
                    throw BurrowConductorError.engine(
                        kind: "error",
                        message: NSLocalizedString("burrow dupes returned an unreadable report", comment: ""))
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
                                               detail: String(format: NSLocalizedString("%d groups · %@", comment: ""),
                                                              r.groups.count, Fmt.bytes(r.redundantBytes)))
                case .failure(let e):
                    self.error = e.localizedDescription
                    OperationCenter.shared.end(self.opId, success: false,
                                               detail: NSLocalizedString("scan failed", comment: ""))
                }
            }
        }
    }

    // MARK: Dedupe (act)

    /// Run the conductor's dedupe PREVIEW (`dupes dedupe <dir>`, no --apply) and hand the
    /// parsed plan to the caller on the main actor. nil = the preview itself failed
    /// (self.error carries the reason).
    func dedupePreview(_ completion: @escaping @MainActor (DedupePreview?) -> Void) {
        guard let folder, !deduping else { return }
        deduping = true
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let preview: DedupePreview?
            var failure: String?
            do {
                let envelope = try BurrowConductor.capture("dupes", ["dedupe", folder], timeout: 300)
                preview = envelope.data.flatMap { DedupePreview.parse($0) }
                if preview == nil {
                    failure = NSLocalizedString("burrow returned an unreadable dedupe preview", comment: "")
                }
            } catch {
                preview = nil
                failure = error.localizedDescription
            }
            Task { @MainActor in
                self.deduping = false
                if let failure { self.error = failure }
                completion(preview)
            }
        }
    }

    /// The confirmed action: `dupes dedupe <dir> --apply` — APFS clones, nothing deleted.
    /// On success the folder is re-scanned so the pane shows the post-reclaim truth.
    func dedupeApply() {
        guard let folder, !deduping else { return }
        deduping = true
        error = nil
        let name = (folder as NSString).lastPathComponent
        let actId = UUID()
        OperationCenter.shared.begin(actId, label: String(format: NSLocalizedString("Deduplicating %@", comment: ""), name),
                                     notifiesOnEnd: true)
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do {
                _ = try BurrowConductor.capture("dupes", ["dedupe", folder, "--apply"], timeout: 600)
            } catch {
                failure = error.localizedDescription
            }
            Task { @MainActor in
                self.deduping = false
                if let failure {
                    self.error = failure
                    OperationCenter.shared.end(actId, success: false,
                                               detail: NSLocalizedString("dedupe failed", comment: ""))
                    return
                }
                OperationCenter.shared.end(actId, success: true,
                                           detail: NSLocalizedString("duplicates now share storage", comment: ""))
                self.rescan()
            }
        }
    }
}
