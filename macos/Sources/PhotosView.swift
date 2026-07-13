//
//  PhotosView.swift
//  Burrow
//
//  The Similar Photos tab — a conductor-tool surface copying the Duplicates
//  pane's idiom: Analyze's toolbar (up arrow + breadcrumbs + mono summary +
//  icon buttons), the same state ladder, and results as one card per
//  similar-cluster. Scanning runs `burrow photos <dir> --json` (dHash
//  perceptual hashing — slow on big folders, so the long 600 s timeout) off
//  the main thread through the pure PhotosModel parser.
//
//  READ-ONLY v1: rows reveal in Finder, nothing is deleted. Member
//  thumbnails decode OFF the main thread via ImageIO at thumbnail size
//  (a full NSImage(contentsOfFile:) of a 48 MP photo on main is a hang),
//  cached in a bounded NSCache; rendered groups cap at 100.
//
//  Degrade: dev/CI builds without the vendor/burrow-cli submodule have no
//  bundled conductor — the pane explains instead of dead-ending.
//

import SwiftUI
import AppKit
import ImageIO

struct PhotosView: View {
    @StateObject private var model = PhotosModel()

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
                    if report.groups.isEmpty { cleanState(report) } else { results(report) }
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

    /// "N similar sets · M photos" — the scan's one-line truth.
    private func summaryLine(_ report: PhotosReport) -> String {
        String(format: NSLocalizedString("%d similar sets · %d photos", comment: ""),
               report.groups.count, report.groups.reduce(0) { $0 + $1.paths.count })
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
            Text(NSLocalizedString("Similar-photo scanning runs through the bundled `burrow` CLI. This build shipped without it — a dev build without the vendor/burrow-cli submodule. Release builds include it.", comment: ""))
                .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
        }
    }

    private var idleState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 26)).foregroundStyle(Tool.photos.accent)
            Text(NSLocalizedString("Spot the shots that echo", comment: ""))
                .font(Brand.serif(17, .medium)).foregroundStyle(Brand.textPrimary)
            Text(NSLocalizedString("Choose a folder and Burrow clusters visually-similar PNG and JPEG images by perceptual hash — near-duplicate screenshots, burst shots, re-exports. Read-only: review the sets, reveal anything in Finder.", comment: ""))
                .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
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
            Text(NSLocalizedString("Comparing photos", comment: ""))
                .font(Brand.serif(18, .medium)).foregroundStyle(Brand.textPrimary)
            HStack(spacing: 8) {
                PulsingDot(color: Tool.photos.accent)
                Text((model.folder.map { ($0 as NSString).abbreviatingWithTildeInPath }) ?? "")
                    .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 380)
            }
            Text(NSLocalizedString("Hashing every image — folders with many photos can take a few minutes.", comment: ""))
                .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NSLocalizedString("Scanning for similar photos", comment: ""))
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 22)).foregroundStyle(Brand.orange)
            Text(message).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 340)
        }
    }

    private func cleanState(_ report: PhotosReport) -> some View {
        // A folder of iPhone photos scans as "empty" because the engine can't decode HEIC — say so
        // rather than claiming everything's unique, which would be an outright lie for that folder.
        let skipped = report.skippedNote
        return VStack(spacing: 8) {
            Image(systemName: skipped == nil ? "checkmark.circle" : "photo.badge.exclamationmark")
                .font(.system(size: 24)).foregroundStyle(Tool.photos.accent)
            Text(skipped == nil
                 ? NSLocalizedString("No look-alikes here", comment: "")
                 : NSLocalizedString("Nothing scannable here", comment: ""))
                .font(Brand.serif(17, .medium)).foregroundStyle(Brand.textPrimary)
            Text(skipped ?? NSLocalizedString("Every PNG and JPEG in this folder looks one of a kind.", comment: ""))
                .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
        }
    }

    // MARK: Results (one card per similar cluster, largest first)

    private func results(_ report: PhotosReport) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(NSLocalizedString("Review similar sets", comment: ""))
                        .font(Brand.serif(22, .medium)).foregroundStyle(Brand.textPrimary)
                    Text(NSLocalizedString("Images in a set look alike to a perceptual hash — not byte-identical, so judge with your eyes. Read-only: reveal anything in Finder.", comment: ""))
                        .font(Brand.sans(11)).foregroundStyle(Brand.textSecondary)
                    if let skipped = report.skippedNote {
                        Text(skipped).font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(report.groups.prefix(100)) { group in
                        groupCard(group)
                    }
                    if report.groups.count > 100 {
                        Text(String(format: NSLocalizedString("…and %d smaller sets. Narrow the folder to see them.", comment: ""),
                                    report.groups.count - 100))
                            .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                            .padding(.vertical, 8)
                    }
                    Color.clear.frame(height: 16)
                }
                .padding(.horizontal, 18).padding(.bottom, 6)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func groupCard(_ group: PhotoGroup) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 13)).foregroundStyle(Tool.photos.accent)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(String(format: NSLocalizedString("%d look-alike photos", comment: ""), group.paths.count))
                    .font(Brand.sans(13, .semibold)).foregroundStyle(Brand.textPrimary)
                Spacer()
                Text((group.paths.first.map { (($0 as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath }) ?? "")
                    .font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(13)
            Rectangle().fill(Brand.hairline).frame(height: 1).padding(.horizontal, 13)
            VStack(spacing: 0) {
                ForEach(group.paths, id: \.self) { memberRow($0) }
            }
            .padding(.vertical, 4)
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(format: NSLocalizedString("Set of %d similar photos", comment: ""), group.paths.count))
    }

    private func memberRow(_ path: String) -> some View {
        HStack(spacing: 10) {
            PhotoThumbView(path: path)
            VStack(alignment: .leading, spacing: 1) {
                Text((path as NSString).lastPathComponent)
                    .font(Brand.sans(12)).foregroundStyle(Brand.textPrimary)
                    .lineLimit(1)
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button { AnalyzeIcons.reveal(path) } label: {
                Image(systemName: "magnifyingglass.circle")
                    .font(.system(size: 12)).foregroundStyle(Brand.textTertiary)
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("Reveal in Finder", comment: ""))
        }
        .padding(.horizontal, 13).padding(.vertical, 5)
    }
}

// MARK: - Thumbnails (async, bounded cache, never a main-thread decode)

/// A small square thumbnail that decodes off-main via ImageIO's thumbnail
/// API (bounded pixel size — never a full-resolution decode) and caches the
/// result. Shows a neutral placeholder until the pixels land.
private struct PhotoThumbView: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(0.06))
            if let image {
                Image(nsImage: image)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 9)).foregroundStyle(Brand.textTertiary)
            }
        }
        .frame(width: 22, height: 22)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Brand.hairline, lineWidth: 1))
        .accessibilityHidden(true)
        .task(id: path) {
            image = await PhotoThumbs.shared.thumbnail(for: path)
        }
    }
}

/// Off-main thumbnail loader with a bounded NSCache. ImageIO's
/// CGImageSourceCreateThumbnailAtIndex decodes at most `maxPixel` pixels —
/// cheap even for 48 MP originals.
final class PhotoThumbs: @unchecked Sendable {
    static let shared = PhotoThumbs()
    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "dev.caezium.Burrow.photo-thumbs", qos: .utility)
    private let maxPixel = 64

    private init() {
        cache.countLimit = 600 // ~100 groups × a handful of members
    }

    func thumbnail(for path: String) async -> NSImage? {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        let maxPixel = self.maxPixel
        return await withCheckedContinuation { cont in
            queue.async { [cache] in
                let url = URL(fileURLWithPath: path) as CFURL
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                    kCGImageSourceShouldCache: false,
                ]
                guard let src = CGImageSourceCreateWithURL(url, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
                    cont.resume(returning: nil)
                    return
                }
                let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                cache.setObject(img, forKey: path as NSString)
                cont.resume(returning: img)
            }
        }
    }
}

// MARK: - Model

@MainActor
final class PhotosModel: ObservableObject {
    /// The chosen folder (absolute path). Scans re-run against this.
    @Published var folder: String?
    @Published var scanning = false
    @Published var report: PhotosReport?
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

    /// Scan `path` via the bundled conductor, off the main thread. Perceptual
    /// hashing is the slow part — hence the 600 s timeout (double the dupes
    /// pane's). The envelope's `data` is decoded by the pure PhotosReport.parse.
    func scan(_ path: String) {
        folder = path
        scanGen += 1
        let gen = scanGen
        scanning = true
        error = nil
        report = nil
        let name = (path as NSString).lastPathComponent
        OperationCenter.shared.begin(opId, label: String(format: NSLocalizedString("Comparing photos in %@", comment: ""), name))
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Result<PhotosReport, Error>
            do {
                let envelope = try BurrowConductor.capture("photos", [path], timeout: 600)
                guard let data = envelope.data, let parsed = PhotosReport.parse(data) else {
                    throw BurrowConductorError.engine(
                        kind: "error",
                        message: NSLocalizedString("burrow photos returned an unreadable report", comment: ""))
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
                                               detail: String(format: NSLocalizedString("%d similar sets", comment: ""),
                                                              r.groups.count))
                case .failure(let e):
                    self.error = e.localizedDescription
                    OperationCenter.shared.end(self.opId, success: false,
                                               detail: NSLocalizedString("scan failed", comment: ""))
                }
            }
        }
    }
}
