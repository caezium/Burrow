//
//  InstallerView.swift
//  Burrow
//
//  The Installers tool — pick which leftover installers to remove, with
//  MOLE doing the deletion. Mole's `installer` is an interactive selection
//  TUI (no flags/JSON for targeted removal), so Burrow runs it in a
//  pseudo-terminal, shows Mole's own list as a native checklist, and replays
//  the user's choices as keystrokes — then verifies the on-screen selection
//  before letting Mole confirm. Nothing is removed by Burrow itself.
//
//  The selection logic lives in the pure `SelectionSession` reducer; this
//  file's runner is the thin host that owns the pseudo-terminal + a tick
//  timer, pumps PTY bytes and ticks in as events, and applies the reducer's
//  effects (send keystrokes / quit). The same view drives both installer and
//  purge.
//

import SwiftUI
import AppKit

// MARK: - Runner (host over the SelectionSession reducer)

@MainActor
final class MoInteractiveRunner: ObservableObject {
    /// View-facing phase. The reducer carries finer states; they collapse to
    /// the handful the UI actually renders.
    enum Phase: Equatable { case scanning, choosing, applying, done(Int32), failed(String) }

    @Published var phase: Phase = .scanning
    @Published var items: [MoTUIItem] = []
    @Published var resultText: String = ""
    /// Total Mole reported in its "[n/total]" header. When it exceeds
    /// `items.count`, Mole capped the visible rows and the UI says so.
    @Published var totalCount: Int = 0
    /// "Show all" pulled in every row past Mole's ≈50-row viewport cap.
    @Published var fullyLoaded = false
    /// Scroll-capture in progress (drives the "Loading all N…" affordance).
    @Published var loadingAll = false

    let title: String
    private let subcommand: String
    /// The interactive PTY session. Production takes a fresh one from the
    /// MoEngine facade (MoEngine.shared.interactive(), the real PTYTask); tests
    /// inject a scripted FakePTY. Raw, escape-preserving output either way — the
    /// SelectionSession reducer parses Mole's redraw frames.
    private var pty: PTYPort
    private let tickInterval: TimeInterval
    /// Resolved `mo` path, or nil to look it up at `start()`. Injectable so a
    /// scripted FakePTY test (which ignores the path) can drive the whole
    /// flow on a runner without `mo` on PATH — production leaves it nil.
    private let executablePath: String?
    private var state = SelectionSession.State()
    private var timer: DispatchSourceTimer?

    init(subcommand: String, title: String,
         pty: PTYPort = MoEngine.shared.interactive(), tickInterval: TimeInterval = 0.06,
         executablePath: String? = nil) {
        self.subcommand = subcommand
        self.title = title
        self.pty = pty
        self.tickInterval = tickInterval
        self.executablePath = executablePath
        // Writing a keystroke to a pty whose child already exited raises SIGPIPE,
        // which would kill the app (try? can't catch a signal). Ignore it
        // process-wide; writes then fail with EPIPE, which we swallow.
        signal(SIGPIPE, SIG_IGN)
    }

    /// (Re)start the scan from a clean slate by driving `mo <subcommand>` in a
    /// pseudo-terminal. Run as the user (never elevated): for Downloads/Desktop/
    /// project folders TCC is keyed on the app, not the uid, so root wouldn't
    /// dodge the prompts anyway — Full Disk Access is the real fix, gated by the
    /// view before we get here.
    func start() {
        stopTimer()
        pty.terminate()
        state = SelectionSession.State()
        publish()
        pty.onOutput = { [weak self] s in MainActor.assumeIsolated { self?.dispatch(.output(s)) } }
        pty.onExit = { [weak self] code in MainActor.assumeIsolated { self?.dispatch(.processExited(code)) } }
        guard let mo = executablePath ?? MoleCLI.findExecutable() else {
            phase = .failed("mo not found"); return
        }
        do { try pty.launch(mo, [subcommand]) }
        catch { phase = .failed("Couldn't start `mo \(subcommand)`.") }
    }

    func rescan() { start() }   // tears down the old PTY itself
    func confirm(_ wanted: Set<Int>) { dispatch(.confirmRequested(wanted)) }
    func loadAll() { dispatch(.showAllRequested) }

    func cancel() {
        // Don't write to the child on teardown — if it already exited, a 'quit'
        // byte hits a dead pty. terminate() tears it down cleanly.
        stopTimer()
        pty.onOutput = nil
        pty.onExit = nil
        pty.terminate()
        switch state.phase { case .done, .failed: break; default: phase = .done(130) }
    }

    /// Advance the reducer's logical clock. The tick timer calls this; tests
    /// call it directly to step the machine deterministically.
    func tick() { dispatch(.tick) }

    // MARK: - Event loop

    private func dispatch(_ event: SelectionSession.Event) {
        let (next, effects) = SelectionSession.reduce(state, event)
        state = next
        for effect in effects {
            switch effect {
            case .send(let bytes): pty.send(bytes)
            case .terminate:       pty.terminate()
            }
        }
        publish()
        syncTimer()
    }

    private func publish() {
        phase = Self.viewPhase(state.phase)
        items = state.items
        totalCount = state.totalCount
        resultText = state.resultText
        fullyLoaded = state.fullyLoaded
        loadingAll = (state.phase == .loadingAll)
    }

    private static func viewPhase(_ p: SelectionSession.Phase) -> Phase {
        switch p {
        case .scanning:              return .scanning
        case .choosing, .loadingAll: return .choosing
        case .applyingViewport, .applyingFull, .awaitingConfirm, .confirming:
            return .applying
        case .done(let c):           return .done(c)
        case .failed(let m):         return .failed(m)
        }
    }

    // MARK: - Tick timer (runs only while a phase needs the logical clock)

    private func syncTimer() {
        let needsTicks: Bool
        switch state.phase {
        case .loadingAll, .applyingViewport, .applyingFull, .awaitingConfirm:
            needsTicks = true
        default:
            needsTicks = false
        }
        if needsTicks { startTimer() } else { stopTimer() }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + tickInterval, repeating: tickInterval)
        t.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }
}

// MARK: - View

/// Per-tool wording/skin for the shared interactive checklist. Mole's
/// `installer` and `purge` are the same kind of selection TUI; only the
/// nouns and accents differ.
struct MoInteractiveConfig {
    let tool: Tool
    let subcommand: String      // "installer" / "purge"
    let noun: String            // singular: "installer" / "project"
    let itemIcon: String        // SF Symbol for each row
    let scanningText: String
    let removalNote: String     // first line of the confirm alert
    let emptyText: String       // shown when nothing is found

    static let installer = MoInteractiveConfig(
        tool: .installer, subcommand: "installer", noun: "installer",
        itemIcon: "shippingbox",
        scanningText: "Scanning for installers via Mole…",
        removalNote: "Mole will remove these installer files:",
        emptyText: "No leftover installers found.")

    static let purge = MoInteractiveConfig(
        tool: .purge, subcommand: "purge", noun: "project",
        itemIcon: "folder.badge.minus",
        scanningText: "Scanning projects for build artifacts via Mole…",
        removalNote: "Mole will remove the build artifacts (node_modules, .build, …) in these projects:",
        emptyText: "No project build artifacts found.")
}

/// Drives Mole's interactive selection TUI (installer/purge) as a native
/// checklist. Generic over `MoInteractiveConfig` so both tools share one
/// implementation — Mole still does every deletion.
struct MoInteractiveView: View {
    @StateObject private var runner: MoInteractiveRunner
    private let cfg: MoInteractiveConfig
    var isActive: Bool = true
    @State private var selected: Set<Int> = []
    @State private var scanRequested = false

    init(_ cfg: MoInteractiveConfig, isActive: Bool = true) {
        self.cfg = cfg
        self.isActive = isActive
        _runner = StateObject(wrappedValue: MoInteractiveRunner(subcommand: cfg.subcommand,
                                                                title: cfg.tool.title))
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Scan on tap. The blocking FDA card is demoted to RootView's ambient
    /// AccessBanner (design 1.3): without the grant, macOS asks per folder
    /// (Downloads/Desktop/Documents have friendly one-time usage prompts);
    /// root wouldn't dodge those — TCC keys on the app, not the uid — so
    /// there is no elevated choice to gate on here.
    private func onScanTapped() { startScan() }
    private func startScan() {
        scanRequested = true
        runner.start()
    }
    /// Return to the tool's hero (same "Back" semantics as Clean/Optimize).
    private func backToHero() {
        runner.cancel()
        selected = []
        scanRequested = false
    }

    @ViewBuilder
    private var content: some View {
        if !scanRequested {
            ToolHero(tool: cfg.tool, title: cfg.tool.title, subtitle: cfg.tool.tagline) {
                PillButton(title: "Scan") { onScanTapped() }
            }
        } else {
            switch runner.phase {
            case .scanning:
                centered { ProgressView(cfg.scanningText).controlSize(.large)
                    .tint(cfg.tool.accent).font(Brand.mono(11)) }
            case .choosing:
                chooser
            case .applying:
                centered { ProgressView("Removing…").controlSize(.large)
                    .tint(cfg.tool.accent).font(Brand.mono(11)) }
            case .done(let code):
                doneView(code)
            case .failed(let m):
                messageView(icon: "exclamationmark.triangle", color: Brand.orange, text: m)
            }
        }
    }

    private var chooser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(cfg.tool.title).font(Brand.serif(18, .medium)).foregroundStyle(Brand.textPrimary)
                Text(countLabel).font(Brand.mono(11)).foregroundStyle(Brand.textTertiary)
                Spacer()
                Button { runner.rescan(); selected = [] } label: {   // rescan() tears down the old PTY itself
                    Label("Rescan", systemImage: "arrow.clockwise").font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 12)
            Rectangle().fill(Brand.hairline).frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(runner.items.enumerated()), id: \.offset) { i, item in
                        MoItemRow(item: item, icon: cfg.itemIcon, accent: cfg.tool.accent, selected: selected.contains(i)) {
                            if selected.contains(i) { selected.remove(i) } else { selected.insert(i) }
                        }
                        Rectangle().fill(Brand.hairline).frame(height: 1).padding(.leading, 48)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
            }
            .scrollIndicators(.visible)

            if runner.loadingAll {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small).tint(cfg.tool.accent)
                    Text("Loading all \(runner.totalCount)… (\(runner.items.count) so far)")
                        .font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.bottom, 4)
            } else if runner.totalCount > runner.items.count {
                HStack(spacing: 8) {
                    Text("Showing the \(runner.items.count) biggest of \(runner.totalCount).")
                        .font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                    Button { runner.loadAll() } label: {
                        Text("Show all \(runner.totalCount)")
                            .font(Brand.mono(9, .semibold)).foregroundStyle(cfg.tool.accent)
                    }.buttonStyle(.plain)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.bottom, 4)
            }

            Rectangle().fill(Brand.hairline).frame(height: 1)
            HStack {
                Text(selectionLabel).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                Spacer()
                Button { selected = (selected.count == runner.items.count) ? [] : Set(runner.items.indices) } label: {
                    // Explicit LocalizedStringKey: a `Text(cond ? "a" : "b")`
                    // ternary resolves to the verbatim String overload, which
                    // skips localization.
                    Text(selected.count == runner.items.count
                         ? LocalizedStringKey("select none") : LocalizedStringKey("select all"))
                        .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                }.buttonStyle(.plain).padding(.trailing, 8)
                Button { confirmRemoval() } label: {
                    Text(selected.isEmpty ? LocalizedStringKey("Remove") : "Remove (\(selected.count))")
                        .font(Brand.sans(12, .semibold)).foregroundStyle(selected.isEmpty ? Brand.textTertiary : .white)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(selected.isEmpty ? Color.white.opacity(0.06) : cfg.tool.accent))
                }.buttonStyle(.plain).disabled(selected.isEmpty)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
        }
    }

    private var countLabel: String {
        runner.totalCount > runner.items.count ? "\(runner.items.count) of \(runner.totalCount)" : "\(runner.items.count) found"
    }

    private var selectionLabel: String {
        selected.isEmpty ? "\(runner.items.count) \(cfg.noun)\(runner.items.count == 1 ? "" : "s")" : "\(selected.count) selected"
    }

    private func confirmRemoval() {
        let targets = selected.sorted().compactMap { runner.items.indices.contains($0) ? runner.items[$0] : nil }
        guard !targets.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(targets.count) \(cfg.noun)\(targets.count == 1 ? "" : "s")?"
        alert.informativeText = cfg.removalNote + "\n\n"
            + targets.prefix(12).map { "• \($0.name)" }.joined(separator: "\n")
            + (targets.count > 12 ? "\n… and \(targets.count - 12) more" : "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Remove", comment: "destructive confirm button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runner.confirm(selected)
    }

    private func doneView(_ code: Int32) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: code == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle")
                    .foregroundStyle(code == 0 ? cfg.tool.accent : Brand.orange)
                Text(runner.items.isEmpty && runner.resultText.isEmpty ? cfg.emptyText : "Done.")
                    .font(Brand.sans(14, .semibold)).foregroundStyle(Brand.textPrimary)
                Spacer()
                Button { backToHero() } label: {
                    Label("Back", systemImage: "chevron.left").font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            Rectangle().fill(Brand.hairline).frame(height: 1)
            if !runner.resultText.isEmpty {
                ScrollView {
                    Text(runner.resultText).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16).textSelection(.enabled)
                }
            } else { Spacer() }
        }
    }

    private func messageView(icon: String, color: Color, text: String) -> some View {
        VStack(spacing: 12) { Spacer()
            Image(systemName: icon).font(.system(size: 24)).foregroundStyle(color)
            Text(text).font(Brand.sans(13)).foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            Button { backToHero() } label: {
                Label("Back", systemImage: "chevron.left").font(Brand.mono(11)).foregroundStyle(cfg.tool.accent)
            }.buttonStyle(.plain)
            Spacer(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func centered<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack { Spacer(); c(); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A selectable row backed by a parsed Mole TUI item.
struct MoItemRow: View {
    let item: MoTUIItem
    let icon: String
    let accent: Color
    let selected: Bool
    let onToggle: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Brand.textTertiary).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(Brand.sans(13, .medium)).foregroundStyle(Brand.textPrimary).lineLimit(1)
                Text("\(item.size)\(item.location.isEmpty ? "" : " · \(item.location)")")
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
