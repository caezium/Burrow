//
//  AnalyzeView.swift
//  Burrow
//
//  The Analyze tab — an interactive disk-usage map. A squarified
//  treemap of a directory (via `mo analyze --json`, the existing
//  DiskScanner + Treemap engine), a left rail of the biggest children,
//  a breadcrumb, and drill-in by click. Reveal / Trash live in each
//  block's context menu.
//

import SwiftUI
import AppKit

struct AnalyzeView: View {
    @StateObject private var model = AnalyzeModel()
    var isActive: Bool = true

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 232)
            Rectangle().fill(Brand.hairline).frame(width: 1)
            mainArea
        }
        // The blocking FDA card that used to cover this pane is demoted to
        // RootView's ambient AccessBanner (issue #3 → design 1.3): the scan
        // starts right away, the banner explains what a missing grant costs.
        .onAppear { evaluateStart() }
        .onChange(of: isActive) { _, now in if now { evaluateStart() } }
    }

    private func evaluateStart() {
        guard isActive, !model.started else { return }
        model.startIfNeeded()
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 8) {
                Circle()
                    .fill(RadialGradient(colors: [Tool.analyze.accent.opacity(0.9), Tool.analyze.accent.opacity(0.15)],
                                         center: .init(x: 0.4, y: 0.35), startRadius: 2, endRadius: 60))
                    .frame(width: 78, height: 78)
                    .shadow(color: Tool.analyze.accent.opacity(0.4), radius: 22)
                Text(model.summaryLine)
                    .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 18).padding(.bottom, 16)

            ScrollView {
                VStack(spacing: 1) {
                    ForEach(model.entries.prefix(40)) { e in
                        sidebarRow(e)
                    }
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func sidebarRow(_ e: DiskScanEntry) -> some View {
        Button { model.drill(into: e) } label: {
            HStack(spacing: 8) {
                Image(nsImage: AnalyzeIcons.icon(for: e))
                    .resizable().frame(width: 17, height: 17)
                VStack(alignment: .leading, spacing: 0) {
                    Text(e.name).font(Brand.sans(12)).foregroundStyle(Brand.textPrimary).lineLimit(1)
                    Text(Fmt.bytes(e.size)).font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                }
                Spacer(minLength: 2)
                if e.isDir {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Brand.textTertiary)
                }
            }
            .padding(.vertical, 5).padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!e.isDir)
        .contextMenu {
            Button(NSLocalizedString("Reveal in Finder", comment: "")) { AnalyzeIcons.reveal(e.path) }
            Divider()
            Button(NSLocalizedString("Move to Trash", comment: ""), role: .destructive) { model.trash(e) }
        }
    }

    // MARK: Main

    private var mainArea: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 16).padding(.vertical, 11)
            Rectangle().fill(Brand.hairline).frame(height: 1)
            ZStack {
                if model.loading {
                    scanningProgress
                } else if let err = model.error {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 22)).foregroundStyle(Brand.orange)
                        Text(err).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                            .multilineTextAlignment(.center).frame(maxWidth: 340)
                    }
                } else {
                    TreemapView(entries: model.entries,
                                onOpen: { e in model.drill(into: e) },
                                onTrash: { e in model.trash(e) })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)
        }
    }

    /// Live scan progress (design 3.1): the path being measured right
    /// now, middle-truncated mono, with a true n/total — Burrow drives
    /// the per-child loop, so the counter is real, never invented.
    private var scanningProgress: some View {
        VStack(spacing: 12) {
            Text("Mapping your folders")
                .font(Brand.serif(18, .medium)).foregroundStyle(Brand.textPrimary)
            HStack(spacing: 8) {
                PulsingDot(color: Tool.analyze.accent)
                if let p = model.progress {
                    Text((p.path as NSString).abbreviatingWithTildeInPath)
                        .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 380)
                    Text(verbatim: "· \(p.done)/\(p.total)")
                        .font(Brand.mono(11)).foregroundStyle(Brand.textTertiary)
                } else {
                    Text("Measuring…").font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.progress.map {
            String(format: NSLocalizedString("Scanning %@, %d of %d", comment: ""), $0.path, $0.done, $0.total)
        } ?? NSLocalizedString("Scanning", comment: ""))
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button { model.goUp() } label: {
                Image(systemName: "arrow.up").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.canGoUp ? Brand.textSecondary : Brand.textTertiary.opacity(0.35))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!model.canGoUp)
            .help(NSLocalizedString("Go up", comment: ""))
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
            Text(model.usageLine).font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
            Button { model.scanWholeDisk() } label: {
                Image(systemName: "externaldrive").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.crumbs.first?.path == "/" ? Brand.textTertiary.opacity(0.35) : Brand.textSecondary)
            }
            .buttonStyle(.plain).disabled(model.crumbs.first?.path == "/")
            .help(NSLocalizedString("Scan the whole disk", comment: ""))
            Button { model.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Brand.textSecondary)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Treemap rendering

struct TreemapView: View {
    let entries: [DiskScanEntry]
    let onOpen: (DiskScanEntry) -> Void
    var onTrash: (DiskScanEntry) -> Void = { _ in }
    @State private var hoveredID: String?

    private static let palette: [Color] = [
        Color(hex: 0x4FA3E3), Color(hex: 0x57C2A5), Color(hex: 0xE6A93C),
        Color(hex: 0xF0884E), Color(hex: 0x8E84F0), Color(hex: 0x5AA8F0),
        Color(hex: 0xE0667E), Color(hex: 0x6FB06A),
    ]

    var body: some View {
        GeometryReader { geo in
            // Largest 120 cells; the long tail folds into one inert "Other"
            // cell so the map stays legible AND its total matches (PRD §Analyze).
            let shown: [DiskScanEntry] = {
                let sorted = entries.filter { $0.size > 0 }.sorted { $0.size > $1.size }
                guard sorted.count > 120 else { return sorted }
                let tail = sorted.dropFirst(120).reduce(Int64(0)) { $0 + $1.size }
                return Array(sorted.prefix(120)) + (tail > 0
                    ? [DiskScanEntry(id: "__other__", name: NSLocalizedString("Other", comment: ""),
                                     path: "", size: tail, isDir: false, lastAccess: nil)]
                    : [])
            }()
            let rects = Treemap.layout(weights: shown.map { Double($0.size) },
                                       in: CGRect(x: 0, y: 0, width: geo.size.width, height: geo.size.height))
            // One immediate-mode draw pass, not 120 nested SwiftUI cells. The
            // old ZStack-of-views version re-ran the layout engine over the
            // whole cell tree on every hover tick (onContinuousHover →
            // hoveredID → body re-eval), which froze the main thread ≥2 s on
            // large maps — a real, escalating app-hang on both Intel and
            // Apple Silicon (Sentry BURROW-1/2). A Canvas redraw is a single
            // cheap pass, and hit-testing already runs off the `rects` array,
            // so the cells never needed to be real views.
            Canvas { ctx, _ in
                for (i, e) in shown.enumerated() where i < rects.count {
                    drawCell(e, rects[i], color: Self.palette[i % Self.palette.count],
                             isHover: hoveredID == e.id, into: ctx)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            // One hover hit-test over the laid-out rects — per-cell `.onHover`
            // tracking areas can stick or misfire, a single region can't, and
            // `.ended` reliably clears the highlight when the mouse leaves.
            .onContinuousHover { phase in
                switch phase {
                case .active(let pt): hoveredID = zip(shown, rects).first { _, r in r.contains(pt) }?.0.id
                case .ended:          hoveredID = nil
                }
            }
            // Click-to-drill maps the tap point back to a cell via the same
            // rects; the context menu acts on whatever the cursor hovers
            // (a right-click hovers the cell first), so both behaviors survive
            // the move off per-cell views.
            .gesture(SpatialTapGesture().onEnded { v in
                if let e = zip(shown, rects).first(where: { $0.1.contains(v.location) })?.0 { onOpen(e) }
            })
            .contextMenu {
                if let id = hoveredID, let e = shown.first(where: { $0.id == id }) {
                    Button(NSLocalizedString("Reveal in Finder", comment: "")) { AnalyzeIcons.reveal(e.path) }
                    if e.isDir { Button(NSLocalizedString("Open here", comment: "")) { onOpen(e) } }
                    Divider()
                    Button(NSLocalizedString("Move to Trash", comment: ""), role: .destructive) { onTrash(e) }
                }
            }
        }
    }

    /// Draw one treemap cell into the shared Canvas context: rounded gradient
    /// fill, border, and — if the cell is large enough — an icon + name + size
    /// label clipped to the cell. Mirrors the old per-cell view 1:1.
    private func drawCell(_ e: DiskScanEntry, _ r: CGRect, color: Color, isHover: Bool, into ctx: GraphicsContext) {
        let cell = r.insetBy(dx: 1, dy: 1)   // 2px gutter between cells
        guard cell.width > 1, cell.height > 1 else { return }
        let path = Path(roundedRect: cell, cornerRadius: 4, style: .continuous)
        ctx.fill(path, with: .linearGradient(
            Gradient(colors: [color.opacity(isHover ? 0.95 : 0.8),
                              color.opacity(isHover ? 0.7 : 0.55)]),
            startPoint: CGPoint(x: cell.midX, y: cell.minY),
            endPoint: CGPoint(x: cell.midX, y: cell.maxY)))
        ctx.stroke(path, with: .color(isHover ? .white.opacity(0.6) : .black.opacity(0.25)), lineWidth: 1)

        guard cell.width > 66, cell.height > 28 else { return }
        var label = ctx
        label.clip(to: path)
        label.addFilter(.shadow(color: .black.opacity(0.4), radius: 2))

        var lines: [GraphicsContext.ResolvedText] = []
        if cell.width > 96, cell.height > 52 {
            lines.append(label.resolve(Text(Image(systemName: e.isDir ? "folder.fill" : "doc.fill"))
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.9))))
        }
        lines.append(label.resolve(Text(e.name).font(Brand.sans(11, .medium)).foregroundStyle(.white)))
        lines.append(label.resolve(Text(Fmt.bytes(e.size)).font(Brand.mono(9)).foregroundStyle(.white.opacity(0.85))))

        // Measure single-line (generous width) and stack centered; the clip
        // above trims any overflow, matching the old `.lineLimit(1)` cell.
        let probe = CGSize(width: 4000, height: cell.height)
        let sizes = lines.map { $0.measure(in: probe) }
        let gap: CGFloat = 2
        let totalH = sizes.reduce(0) { $0 + $1.height } + gap * CGFloat(max(0, lines.count - 1))
        var y = cell.midY - totalH / 2
        for (line, sz) in zip(lines, sizes) {
            label.draw(line, at: CGPoint(x: cell.midX, y: y + sz.height / 2), anchor: .center)
            y += sz.height + gap
        }
    }
}

// MARK: - Icons / Finder helpers

enum AnalyzeIcons {
    // NSCache, not a plain dict: keyed by full path it would otherwise retain an
    // NSImage for every file ever shown for the process lifetime. NSCache evicts
    // under memory pressure and honors the count cap. #236
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 512
        return c
    }()
    static func icon(for e: DiskScanEntry) -> NSImage {
        if let c = cache.object(forKey: e.path as NSString) { return c }
        let img = NSWorkspace.shared.icon(forFile: e.path)
        cache.setObject(img, forKey: e.path as NSString)
        return img
    }
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

/// Boxed walk result so the path→walk cache can be an NSCache (needs a class
/// value); lets it stay bounded and evict under memory pressure. #236
final class CachedWalk {
    let entries: [DiskScanEntry]
    let total: Int64
    init(entries: [DiskScanEntry], total: Int64) { self.entries = entries; self.total = total }
}

// MARK: - Model

/// Soft-pulsing progress dot; static under Reduce Motion.
struct PulsingDot: View {
    let color: Color
    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle().fill(color)
            .frame(width: 7, height: 7)
            .opacity(reduceMotion ? 1 : (pulsing ? 1 : 0.35))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                       value: pulsing)
            .onAppear { pulsing = true }
            .accessibilityHidden(true)
    }
}

/// A one-shot cooperative cancellation flag, set on the main actor when a scan
/// is superseded and read from the background walk. Lock-guarded because the
/// write and reads cross threads. #232
final class ScanCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

@MainActor
final class AnalyzeModel: ObservableObject {
    struct Progress: Equatable {
        let path: String
        let done: Int
        let total: Int
    }

    @Published var entries: [DiskScanEntry] = []
    @Published var crumbs: [(name: String, path: String)] = []
    @Published var loading = false
    @Published var progress: Progress?
    @Published var error: String?
    private var total: Int64 = 0
    private(set) var started = false
    private let opId = UUID()
    /// Cache scan results by path so navigating back/into already-seen
    /// folders is instant instead of re-running `mo analyze` (~4 CPU-s)
    /// each time. Refresh clears the current path to force a fresh walk.
    // NSCache (bounded, auto-evicting) rather than an ever-growing dict: browsing
    // deep trees / whole-disk analyze would otherwise retain a DiskScanEntry array
    // for every directory ever visited for the model's lifetime. #236
    private let cache: NSCache<NSString, CachedWalk> = {
        let c = NSCache<NSString, CachedWalk>()
        c.countLimit = 256
        return c
    }()

    var summaryLine: String {
        entries.isEmpty ? "—" : String(format: NSLocalizedString("%d items · %@", comment: ""), entries.count, Fmt.bytes(total))
    }
    var usageLine: String { String(format: NSLocalizedString("%@ in %d items", comment: ""), Fmt.bytes(total), entries.count) }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        crumbs = []
        scan(NSHomeDirectory(), name: NSLocalizedString("Home", comment: ""), push: true)
    }

    func drill(into e: DiskScanEntry) {
        guard e.isDir else { return }
        scan(e.path, name: e.name, push: true)
    }

    func goToCrumb(_ idx: Int) {
        guard idx < crumbs.count else { return }
        let c = crumbs[idx]
        crumbs = Array(crumbs.prefix(idx + 1))
        scan(c.path, name: c.name, push: false)
    }

    func refresh() {
        guard let last = crumbs.last else { return }
        cache.removeObject(forKey: last.path as NSString)   // drop the cached walk so we re-scan
        scan(last.path, name: last.name, push: false, force: true)
    }

    /// Re-root the scan at the whole disk (PRD §Analyze 38). Reachable by
    /// climbing Up too, but this is the one-tap "show me everything" entry.
    func scanWholeDisk() {
        guard crumbs.first?.path != "/" else { return }
        crumbs = []
        scan("/", name: "/", push: true)
    }

    /// Whether there's a parent to climb to (Home isn't the ceiling — you can
    /// go up to /Users, /, external volumes, …). False only at the filesystem root.
    var canGoUp: Bool {
        guard let p = crumbs.first?.path, !p.isEmpty else { return false }
        return p != "/"
    }

    /// Climb to the parent of the current root, making it the new breadcrumb root.
    func goUp() {
        guard let root = crumbs.first else { return }
        let parent = (root.path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != root.path else { return }
        let name = parent == "/" ? "/" : (parent as NSString).lastPathComponent
        crumbs = []
        scan(parent, name: name.isEmpty ? "/" : name, push: true)
    }

    /// Move an item to the Trash (recoverable), after an explicit confirm. The
    /// treemap is exactly where you spot a forgotten 8 GB folder, so removing it
    /// shouldn't mean leaving for Finder. Updates the view in place and drops the
    /// current folder's cached walk so a later refresh recomputes honestly.
    func trash(_ e: DiskScanEntry) {
        let alert = NSAlert()
        alert.messageText = String(format: NSLocalizedString("Move \u{201C}%@\u{201D} to Trash?", comment: ""), e.name)
        alert.informativeText = String(format: NSLocalizedString("This moves %@ (%@) to the Trash, where you can restore it.", comment: ""),
                                       e.isDir ? NSLocalizedString("this folder", comment: "") : NSLocalizedString("this file", comment: ""),
                                       Fmt.bytes(e.size))
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Move to Trash", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        guard alert.runModalQuiet() == .alertFirstButtonReturn else { return }

        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: e.path), resultingItemURL: nil)
            entries.removeAll { $0.id == e.id }
            total = max(0, total - e.size)
            if let last = crumbs.last { cache.removeObject(forKey: last.path as NSString) }
        } catch {
            let err = NSAlert()
            err.messageText = NSLocalizedString("Couldn't move to Trash", comment: "")
            err.informativeText = error.localizedDescription
            err.alertStyle = .warning
            err.runModalQuiet()
        }
    }

    /// Monotonic token: every navigation (scan start OR instant cache hit)
    /// bumps it, and a finishing background scan applies its result only if
    /// it is still the newest — a slow walk must not clobber the folder the
    /// breadcrumbs have since moved to. (Same pattern as HistoryView's
    /// `loadGen`.)
    private var scanGen = 0
    /// Cancels the in-flight background walk when a new navigation supersedes it.
    /// The `scanGen` token above only gates whether a finishing walk's result is
    /// APPLIED; this token makes a superseded walk stop SPAWNING `mo analyze`
    /// processes right away, so rapid navigation / refresh can't stack overlapping
    /// scans that each fire a fanout of engine processes. #232
    private var scanToken: ScanCancel?

    private func scan(_ path: String, name: String, push: Bool, force: Bool = false) {
        if push { crumbs.append((name, path)) }
        scanGen += 1
        let gen = scanGen
        // Any navigation supersedes the previous walk — stop it spawning at once.
        scanToken?.cancel()
        // Cache hit → show instantly; don't re-run `mo analyze` for a
        // folder we already walked (back/drill is the common navigation).
        if !force, let cached = cache.object(forKey: path as NSString) {
            entries = cached.entries; total = cached.total; loading = false; error = nil
            return
        }
        loading = true
        progress = nil
        error = nil
        let token = ScanCancel()
        scanToken = token
        OperationCenter.shared.begin(opId, label: String(format: NSLocalizedString("Analyzing %@", comment: ""), name))
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let r = try Self.scanWithProgress(path, isCancelled: { token.isCancelled }) { current, done, total in
                    Task { @MainActor in
                        guard gen == self.scanGen else { return }
                        self.progress = Progress(path: current, done: done, total: total)
                    }
                } cacheChild: { childPath, result in
                    Task { @MainActor in
                        // Pre-warm drill-down with the per-child walks.
                        self.cache.setObject(CachedWalk(entries: result.entries,
                                                 total: result.totalSize > 0 ? result.totalSize
                                                    : result.entries.reduce(0) { $0 + $1.size }),
                                             forKey: childPath as NSString)
                    }
                }
                let sum = r.totalSize > 0 ? r.totalSize : r.entries.reduce(0) { $0 + $1.size }
                Task { @MainActor in
                    self.cache.setObject(CachedWalk(entries: r.entries, total: sum), forKey: path as NSString)   // cache stays warm either way
                    guard gen == self.scanGen else { return }
                    self.entries = r.entries
                    self.total = sum
                    self.loading = false
                    self.progress = nil
                    OperationCenter.shared.end(self.opId, success: true,
                                               detail: String(format: NSLocalizedString("%d items · %@", comment: ""), r.entries.count, Fmt.bytes(sum)))
                }
            } catch {
                Task { @MainActor in
                    guard gen == self.scanGen else { return }
                    self.error = error.localizedDescription
                    self.loading = false
                    self.progress = nil
                    OperationCenter.shared.end(self.opId, success: false, detail: NSLocalizedString("scan failed", comment: ""))
                }
            }
        }
    }

    /// True progress (design 3.1): when the target has a modest number
    /// of children, Burrow walks them itself — one `mo analyze` per
    /// child directory — so "● ~/Downloads · 3/12" reflects reality and
    /// every child's walk pre-warms the drill-down cache. Bushier
    /// targets (drilling into node_modules…) fall back to mole's single
    /// aggregate call rather than spawning hundreds of processes.
    /// Stream `burrow analyze --progress <path>`: the engine's live file counters drive
    /// `onProgress`, and the terminal result parses like `analyze --json`. Synchronous (runs on the
    /// scan's background queue), reusing the TDD'd AnalyzeProgressEvent parser. Throws on cancel /
    /// spawn failure / no result so the caller can fall back to the direct walk.
    nonisolated static func scanStreaming(
        _ path: String,
        isCancelled: @escaping () -> Bool = { false },
        onProgress: @escaping (String, Int, Int) -> Void
    ) throws -> DiskScanResult {
        guard let burrow = BurrowConductor.executableURL() else { throw DiskScanError.moNotFound }
        let proc = Process()
        proc.executableURL = burrow
        proc.arguments = ["analyze", "--progress", path]
        var env = Foundation.ProcessInfo.processInfo.environment
        if let dir = BurrowConductor.engineDir() { env["BURROW_ENGINE_DIR"] = dir.path }
        proc.environment = env
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()   // discard the human-readable line on stderr
        try proc.run()

        let handle = out.fileHandleForReading
        var pending = Data()
        var resultData: Data?
        while true {
            if isCancelled() { proc.terminate(); throw DiskScanError.parseFailed("cancelled") }
            let chunk = handle.availableData
            if chunk.isEmpty { break }                       // EOF: engine closed stdout
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let lineData = pending.subdata(in: pending.startIndex..<newline)
                pending.removeSubrange(pending.startIndex...newline)
                guard let line = String(data: lineData, encoding: .utf8),
                      let event = AnalyzeProgressEvent.parse(line: line) else { continue }
                switch event {
                case .progress(let files, _, _, let scanned):
                    onProgress(scanned, files, max(files, 1))   // path + running file count
                case .result(let data):
                    resultData = data
                }
            }
        }
        proc.waitUntilExit()
        // A final result line that arrived without a trailing newline.
        if resultData == nil, let line = String(data: pending, encoding: .utf8),
           case .result(let data)? = AnalyzeProgressEvent.parse(line: line) {
            resultData = data
        }
        guard let data = resultData else {
            throw DiskScanError.parseFailed("analyze --progress produced no result")
        }
        return try DiskScanner.parse(data)
    }

    nonisolated static func scanWithProgress(
        _ path: String,
        isCancelled: @escaping () -> Bool = { false },
        onProgress: @escaping (String, Int, Int) -> Void,
        cacheChild: @escaping (String, DiskScanResult) -> Void
    ) throws -> DiskScanResult {
        // Opt-in live-filling treemap: stream `burrow analyze --progress` so the scan reports the
        // engine's file-level counters. Any miss (flag off, no conductor, stream failure) falls
        // through to the two-level per-child walk below, so behavior is unchanged by default.
        if BurrowConductor.streamingAnalyzeEnabled, BurrowConductor.isAvailable,
           let streamed = try? Self.scanStreaming(path, isCancelled: isCancelled, onProgress: onProgress) {
            return streamed
        }
        let fm = FileManager.default
        // The per-child walk is what emits "● <child> · k/N" progress, so it
        // must also run for Home (which carries dozens of entries once dotfiles
        // are counted) — the old `<= 40` cap silently fell back to mole's one
        // aggregate call there, leaving the first scan on a static line. We
        // raise the ceiling to a Home-sized bound and run the children with
        // bounded concurrency, so wall-clock stays near the aggregate scan
        // instead of N sequential `mo analyze` spawns. Pathologically bushy
        // targets (drilling into a node_modules) still fall back rather than
        // spawning hundreds of processes.
        guard let childNames = try? fm.contentsOfDirectory(atPath: path),
              childNames.count > 0, childNames.count <= 200 else {
            return try DiskScanner.scan(path)
        }

        let total = childNames.count
        let lock = NSLock()
        var entries: [DiskScanEntry] = []
        var totalSize: Int64 = 0
        var done = 0

        // 3, not 6: each child spawns a full-subtree `mo analyze` walk, so a wider
        // fanout pegs several cores at once (six were visible in #232). Three keeps
        // wall-clock near the aggregate scan without saturating the machine.
        let inFlight = DispatchSemaphore(value: 3)   // bound concurrent `mo analyze`
        let group = DispatchGroup()
        let workQ = DispatchQueue.global(qos: .userInitiated)

        for name in childNames {
            if isCancelled() { break }               // superseded → stop queuing more walks
            inFlight.wait()
            group.enter()
            workQ.async {
                defer { inFlight.signal(); group.leave() }
                if isCancelled() { return }          // don't spawn `mo analyze` for a dead scan
                let childPath = (path as NSString).appendingPathComponent(name)
                var entry: DiskScanEntry?
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: childPath, isDirectory: &isDir) {
                    if isDir.boolValue {
                        // A child mole can't read (permissions) still gets a row
                        // — size 0 — instead of sinking the whole scan.
                        let result = try? DiskScanner.scan(childPath)
                        let size = result.map { $0.totalSize > 0 ? $0.totalSize : $0.entries.reduce(0) { $0 + $1.size } } ?? 0
                        if let result { cacheChild(childPath, result) }
                        entry = DiskScanEntry(id: childPath, name: name, path: childPath,
                                              size: size, isDir: true, lastAccess: nil)
                    } else {
                        let attrs = try? fm.attributesOfItem(atPath: childPath)
                        let size = (attrs?[.size] as? Int64) ?? Int64((attrs?[.size] as? Int) ?? 0)
                        entry = DiskScanEntry(id: childPath, name: name, path: childPath,
                                              size: size, isDir: false, lastAccess: nil)
                    }
                }
                lock.lock()
                if let entry { entries.append(entry); totalSize += entry.size }
                done += 1
                let d = done
                lock.unlock()
                onProgress(childPath, d, total)
            }
        }
        group.wait()
        // A superseded walk returns a PARTIAL tree; throwing keeps the caller's
        // catch (which is scanGen-guarded) from caching it as if it were complete.
        if isCancelled() { throw CancellationError() }

        entries.sort { $0.size > $1.size }
        return DiskScanResult(path: path, totalSize: totalSize,
                              totalFiles: total, entries: entries, scannedAt: Date())
    }
}
