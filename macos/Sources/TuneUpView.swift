//
//  TuneUpView.swift
//  Burrow
//
//  The Tune-Up pane (#77): a guided "scan everything, then act in one pass"
//  surface in the Smart-Care shape — a big Scan hero on entry, an animated
//  scanning pass, then unified results across six modules:
//
//    Runnable here (reversible, one tap):
//      • Cleanable junk   — the clean dry-run total
//      • Maintenance      — the optimize task list
//    Worth your review (acted on in their own panes):
//      • Apps to uninstall — your largest installed apps
//      • App & Homebrew updates — deep-link (kept click-gated for privacy)
//      • Startup items     — new since the baseline + what's controllable
//      • Big disk users    — top space hogs under your home folder
//
//  "Run the safe set" shows a visible plan, then runs Clean → Optimize through
//  the same OperationFlow the dedicated tabs use (each elevated step prompts
//  separately — honest auth, no pooled helper yet). The scan snapshot and the
//  last-run summary persist across pane switches AND relaunch via TuneUpModel,
//  so re-entry lands straight on the last results.
//
//  NOTE (hand-test): compile-verified only. Verify: Scan runs the pass and
//  lands on results; re-entry shows last results; "Run the safe set" runs clean
//  then optimize with two auth prompts and a done summary; deep-links jump panes.
//

import SwiftUI
import AppKit

struct TuneUpView: View {
    @StateObject private var model = TuneUpModel()
    @StateObject private var flow = OperationFlow<TaskRunReport>()
    var isActive: Bool = true

    private enum Phase { case scanning, results, running, done }
    private enum SafeStep { case clean(CleanupExecutionPlan), optimize }

    @State private var phase: Phase = .scanning
    @State private var includeClean = true
    @State private var includeOptimize = true
    @State private var runSteps: [SafeStep] = []
    @State private var runIndex = 0
    @State private var stepSummaries: [String] = []
    @State private var showPlan = false
    @State private var irreversibleConsent = false
    @State private var pendingCleanupPlan: CleanupExecutionPlan?

    private var accent: Color { Tool.tuneup.accent }

    var body: some View {
        Group {
            switch phase {
            case .scanning:          scanningHero
            case .results:           resultsView
            case .running, .done:    runView
            }
        }
        .onAppear { routeOnAppear() }
        .onChange(of: isActive) { _, now in if now { routeOnAppear() } }
        // Scan finished → reveal results.
        .onChange(of: model.scanning) { _, scanning in
            if !scanning, phase == .scanning { phase = .results }
        }
        .onChange(of: flowToken) { _, _ in handleFlowChange() }
        .sheet(isPresented: $showPlan) { planSheet }
    }

    /// On entry, auto-run the read-only scans (issue #77). The scan is cached
    /// across pane switches + relaunch (TuneUpModel), so this only actually
    /// scans when there's no snapshot yet — landing on results, or the scanning
    /// animation while it runs. Never disturbs an in-flight tune-up run.
    private func routeOnAppear() {
        guard isActive else { return }
        model.scanIfNeeded()
        if phase == .scanning || phase == .results {
            phase = model.snapshot != nil ? .results : .scanning
        }
    }

    // MARK: - Scanning

    private var scanningHero: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                HeroOrb(accent: accent, size: 120)
                ProgressView().controlSize(.large).tint(.white)
            }
            VStack(spacing: 6) {
                Text(NSLocalizedString("Scanning your Mac…", comment: ""))
                    .font(Brand.serif(20, .medium)).foregroundStyle(Brand.textPrimary)
                Text(model.progress.isEmpty ? NSLocalizedString("Taking stock of the den…", comment: "") : model.progress)
                    .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Self.scanModules, id: \.0) { (label, glyph) in
                    HStack(spacing: 9) {
                        Image(systemName: glyph).font(.system(size: 11)).foregroundStyle(accent).frame(width: 16)
                        Text(NSLocalizedString(label, comment: "")).font(Brand.sans(12)).foregroundStyle(Brand.textSecondary)
                        Spacer()
                    }
                }
            }
            .frame(width: 260)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(Brand.cardFill))
            Spacer(); Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static let scanModules: [(String, String)] = [
        ("Cleanable junk", "sparkles"),
        ("Maintenance", "wand.and.stars"),
        ("Large apps", "shippingbox"),
        ("Startup items", "power"),
        ("Big disk users", "internaldrive"),
    ]

    // MARK: - Results

    private var resultsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                resultsHeader
                if let snap = model.snapshot {
                    safeSetCard(snap)
                    if !snap.bigApps.isEmpty { uninstallCard(snap.bigApps) }
                    updatesCard
                    startupCard(snap)
                    if !snap.bigDisk.isEmpty { diskCard(snap.bigDisk) }
                    if let at = snap.lastRunAt { lastRunCard(at, snap.lastRunSummary) }
                    if !snap.hasFindings { tidyNote }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    private var resultsHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(NSLocalizedString("Scan results", comment: ""))
                    .font(Brand.serif(26, .medium)).foregroundStyle(Brand.textPrimary)
                Text(scannedAgoText).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
            }
            Spacer()
            Button { startScan() } label: {
                Label(NSLocalizedString("Re-scan", comment: ""), systemImage: "arrow.clockwise")
                    .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
            }
            .buttonStyle(.plain)
        }
    }

    /// Cached — building a RelativeDateTimeFormatter per render (this is a
    /// computed property) is needlessly expensive. #240
    private static let agoFmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full; return f
    }()

    private var scannedAgoText: String {
        guard let at = model.snapshot?.scannedAt else { return NSLocalizedString("Not scanned yet", comment: "") }
        return String(format: NSLocalizedString("Scanned %@", comment: ""), Self.agoFmt.localizedString(for: at, relativeTo: Date()))
    }

    private var tidyNote: some View {
        GlassCard {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 20)).foregroundStyle(Brand.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(NSLocalizedString("Nothing pressing", comment: ""))
                        .font(Brand.sans(14, .semibold)).foregroundStyle(Brand.textPrimary)
                    Text(NSLocalizedString("No junk, stale apps, or new startup items worth a look right now.", comment: ""))
                        .font(Brand.sans(12)).foregroundStyle(Brand.textSecondary)
                }
                Spacer()
            }
        }
    }

    // MARK: Safe-set card

    private func safeSetCard(_ snap: TuneUpSnapshot) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(text: "Run the safe set", glyph: "wand.and.stars", color: accent)
                Text(NSLocalizedString("Reclaim space and refresh maintenance in a single pass. Cache cleaning permanently deletes the reviewed cache files; maintenance runs separately.", comment: ""))
                    .font(Brand.sans(12.5)).foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                planToggle(on: $includeClean, enabled: !snap.cleanableText.isEmpty,
                           title: NSLocalizedString("Clean caches & junk", comment: ""),
                           value: snap.cleanableText.isEmpty ? NSLocalizedString("nothing to clean", comment: "") : snap.cleanableText)
                planToggle(on: $includeOptimize, enabled: !snap.optimizeAreas.isEmpty,
                           title: NSLocalizedString("Run maintenance", comment: ""),
                           value: snap.optimizeAreas.isEmpty
                                ? NSLocalizedString("nothing to do", comment: "")
                                : String(format: NSLocalizedString("%d areas", comment: ""), snap.optimizeAreas.count))

                HStack(spacing: 12) {
                    PillButton(title: "Review run") { prepareRunReview() }
                        .disabled(!canRun(snap))
                        .opacity(canRun(snap) ? 1 : 0.4)
                    Text(NSLocalizedString("Each step asks for your password.", comment: ""))
                        .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                    Spacer()
                }
                .padding(.top, 2)
            }
        }
    }

    private func planToggle(on: Binding<Bool>, enabled: Bool, title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: on).labelsHidden().toggleStyle(.switch).tint(accent)
                .disabled(!enabled)
            Text(title)
                .font(Brand.sans(13, .medium))
                .foregroundStyle(enabled ? Brand.textPrimary : Brand.textTertiary)
            Spacer()
            Text(value).font(Brand.mono(12)).foregroundStyle(enabled ? Brand.textSecondary : Brand.textTertiary)
        }
    }

    private func canRun(_ snap: TuneUpSnapshot) -> Bool {
        (includeClean && !snap.cleanableText.isEmpty) || (includeOptimize && !snap.optimizeAreas.isEmpty)
    }

    // MARK: Review cards

    private func uninstallCard(_ apps: [TuneUpSnapshot.AppLite]) -> some View {
        reviewCard(title: "Apps to review", glyph: "shippingbox",
                   count: String(format: NSLocalizedString("%d large", comment: ""), apps.count),
                   actionTitle: NSLocalizedString("Review in Software", comment: ""), pane: .tool(.apps)) {
            VStack(spacing: 6) {
                ForEach(apps.prefix(4)) { app in
                    itemRow(name: app.name, value: Fmt.bytes(app.sizeBytes))
                }
            }
        }
    }

    private var updatesCard: some View {
        reviewCard(title: "App & Homebrew updates", glyph: "arrow.down.circle",
                   count: "", actionTitle: NSLocalizedString("Check in Software", comment: ""), pane: .tool(.apps)) {
            Text(NSLocalizedString("Check apps and Homebrew for newer versions. Burrow only reaches out to vendors when you ask it to here.", comment: ""))
                .font(Brand.sans(12)).foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func startupCard(_ snap: TuneUpSnapshot) -> some View {
        let countText: String = snap.newStartup.isEmpty
            ? String(format: NSLocalizedString("%d controllable", comment: ""), snap.startupControllable)
            : String(format: NSLocalizedString("%d new", comment: ""), snap.newStartup.count)
        return reviewCard(title: "Startup items", glyph: "power",
                          count: countText,
                          actionTitle: NSLocalizedString("Review in Software", comment: ""), pane: .tool(.apps)) {
            if snap.newStartup.isEmpty {
                Text(NSLocalizedString("No new login items since the last check.", comment: ""))
                    .font(Brand.sans(12)).foregroundStyle(Brand.textSecondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(snap.newStartup.prefix(4), id: \.self) { label in
                        itemRow(name: label, value: NSLocalizedString("new", comment: ""))
                    }
                }
            }
        }
    }

    private func diskCard(_ entries: [TuneUpSnapshot.DiskLite]) -> some View {
        reviewCard(title: "Big disk users", glyph: "internaldrive",
                   count: String(format: NSLocalizedString("top %d", comment: ""), entries.count),
                   actionTitle: NSLocalizedString("Open in Analyze", comment: ""), pane: .tool(.analyze)) {
            VStack(spacing: 6) {
                ForEach(entries.prefix(4)) { e in
                    itemRow(name: e.name, value: Fmt.bytes(e.size))
                }
            }
        }
    }

    private func lastRunCard(_ at: Date, _ summary: String?) -> some View {
        let f = Self.agoFmt   // cached (#240)
        return GlassCard {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 16)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: NSLocalizedString("Last tune-up %@", comment: ""),
                                f.localizedString(for: at, relativeTo: Date())))
                        .font(Brand.sans(13, .semibold)).foregroundStyle(Brand.textPrimary)
                    if let s = summary, !s.isEmpty {
                        Text(s).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                    }
                }
                Spacer()
            }
        }
    }

    /// One review card: eyebrow + count, a custom detail, and a deep-link.
    private func reviewCard<Detail: View>(
        title: String, glyph: String, count: String, actionTitle: String, pane: Pane,
        @ViewBuilder detail: () -> Detail
    ) -> some View {
        let content = detail()   // build eagerly so GlassCard's stored closure needn't escape `detail`
        return GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Eyebrow(text: title, glyph: glyph)
                    Spacer()
                    if !count.isEmpty {
                        Text(count).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                    }
                }
                content
                Button { navigate(pane) } label: {
                    HStack(spacing: 4) {
                        Text(actionTitle).font(Brand.sans(12, .semibold))
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func itemRow(name: String, value: String) -> some View {
        HStack(spacing: 10) {
            Text(name).font(Brand.sans(12)).foregroundStyle(Brand.textPrimary)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(value).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
        }
    }

    // MARK: - Run view

    private var runView: some View {
        VStack(spacing: 0) {
            runStatusBar
            Rectangle().fill(Brand.hairline).frame(height: 1)
            if phase == .done {
                DoneBanner(accent: accent,
                           title: runFailed ? "Tune-up stopped" : "Tune-up complete",
                           detail: stepSummaries.isEmpty ? nil : stepSummaries.joined(separator: " · "))
            }
            TaskReportView(groups: flow.report?.groups ?? [], accent: accent)
            ViewLogDisclosure(log: flow.rawLog)
        }
    }

    private var runStatusBar: some View {
        HStack(spacing: 10) {
            if phase == .running { ProgressView().controlSize(.small).tint(accent) }
            Text(runStatusText).font(Brand.mono(12)).foregroundStyle(Brand.textSecondary)
            Spacer()
            if phase == .done {
                Button { finishRun() } label: {
                    Label(NSLocalizedString("Done", comment: ""), systemImage: "chevron.left")
                        .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 12)
    }

    private var runStatusText: String {
        switch phase {
        case .running:
            guard runIndex < runSteps.count else { return NSLocalizedString("Working…", comment: "") }
            let pos = runIndex + 1, n = runSteps.count
            switch runSteps[runIndex] {
            case .clean(_): return String(format: NSLocalizedString("Cleaning… (%d of %d)", comment: ""), pos, n)
            case .optimize: return String(format: NSLocalizedString("Running maintenance… (%d of %d)", comment: ""), pos, n)
            }
        case .done:
            if case .finished(.failed(let m)) = flow.state {
                return String(format: NSLocalizedString("Stopped: %@", comment: ""), m)
            }
            return NSLocalizedString("Tune-up complete.", comment: "")
        default:
            return ""
        }
    }

    private var runFailed: Bool {
        if case .finished(.failed) = flow.state { return true }
        if case .finished(.cancelled) = flow.state { return true }
        return false
    }

    // MARK: - Scan + run sequencing

    private func startScan() {
        phase = .scanning
        model.rescan()
    }

    private func runSafeSet() {
        guard let snap = model.snapshot else { return }
        var steps: [SafeStep] = []
        if includeClean, !snap.cleanableText.isEmpty {
            guard let pendingCleanupPlan, pendingCleanupPlan.validateForLaunch() else { return }
            steps.append(.clean(pendingCleanupPlan))
        }
        if includeOptimize, !snap.optimizeAreas.isEmpty { steps.append(.optimize) }
        guard !steps.isEmpty else { return }
        runSteps = steps
        runIndex = 0
        stepSummaries = []
        phase = .running
        startStep(steps[0])
    }

    private func startStep(_ step: SafeStep) {
        switch step {
        case .clean(let plan):
            flow.start(ToolOperation(
                label: NSLocalizedString("Tune-Up: cleaning reviewed caches", comment: ""),
                executable: .path("/usr/bin/find"), arguments: [], elevated: true,
                cleanupPlan: plan, reduce: { parseTaskReport($0) }, notifyOnEnd: true))
        case .optimize:
            flow.start(.moleStream(["optimize"], elevated: true,
                                   label: NSLocalizedString("Tune-Up: optimizing", comment: ""),
                                   notifyOnEnd: true))
        }
    }

    /// A stable token over the flow's lifecycle; includes runIndex so two
    /// steps both finishing `.done(0)` still register as a change.
    private var flowToken: String {
        let s: String
        switch flow.state {
        case .idle:    s = "i"
        case .gated:   s = "g"
        case .running: s = "r"
        case .finished(let o):
            switch o {
            case .done(let c):   s = "d\(c)"
            case .failed(let m): s = "f\(m)"
            case .cancelled:     s = "c"
            }
        }
        return "\(runIndex):\(s)"
    }

    private func handleFlowChange() {
        guard phase == .running else { return }
        switch flow.state {
        case .finished(.done(exit: 0)):
            if let line = flow.report?.summary?.completionLine, !line.isEmpty {
                stepSummaries.append(line)
            }
            advance()
        case .finished(.done), .finished(.failed), .finished(.cancelled):
            phase = .done
        default:
            break
        }
    }

    private func advance() {
        runIndex += 1
        if runIndex < runSteps.count {
            let next = runSteps[runIndex]
            // Defer the next start out of the onChange dispatch.
            Task { @MainActor in startStep(next) }
        } else {
            phase = .done
            recordRun()
        }
    }

    private func recordRun() {
        let summary = stepSummaries.isEmpty
            ? NSLocalizedString("No changes", comment: "")
            : stepSummaries.joined(separator: " · ")
        model.recordRun(summary: summary)
    }

    /// "Done" → reset the flow and re-scan, so results reflect what the run
    /// just changed.
    private func finishRun() {
        flow.reset()
        startScan()
    }

    // MARK: - Plan sheet

    private var planSheet: some View {
        let snap = model.snapshot
        let willClean = includeClean && !(snap?.cleanableText.isEmpty ?? true)
        let willOptimize = includeOptimize && !(snap?.optimizeAreas.isEmpty ?? true)
        let policy = TuneUp.ConfirmationPolicy(includesClean: willClean)
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("Tune-up plan", comment: ""))
                    .font(Brand.serif(20, .medium)).foregroundStyle(Brand.textPrimary)
                Text(NSLocalizedString("Burrow will run, in order:", comment: ""))
                    .font(Brand.sans(12)).foregroundStyle(Brand.textSecondary)
            }
            VStack(spacing: 8) {
                if willClean {
                    planRow(glyph: "sparkles", title: NSLocalizedString("Clean caches & junk", comment: ""),
                            value: snap?.cleanableText ?? "")
                    if let plan = pendingCleanupPlan {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(plan.items.prefix(6), id: \.identity.path) { item in
                                Text(item.identity.path)
                                    .font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            if plan.items.count > 6 {
                                Text(String(format: NSLocalizedString("and %d more reviewed paths", comment: ""), plan.items.count - 6))
                                    .font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                }
                if willOptimize {
                    planRow(glyph: "wand.and.stars", title: NSLocalizedString("Run maintenance", comment: ""),
                            value: String(format: NSLocalizedString("%d areas", comment: ""), snap?.optimizeAreas.count ?? 0))
                }
            }
            Text(NSLocalizedString(policy.notice, comment: ""))
                .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if policy.requiresIrreversibleConsent {
                Toggle(isOn: $irreversibleConsent) {
                    Text(NSLocalizedString("I understand the clean step permanently deletes these cache files.", comment: ""))
                        .font(Brand.sans(12)).foregroundStyle(Brand.textSecondary)
                }
                .toggleStyle(.checkbox)
            }
            HStack(spacing: 12) {
                Spacer()
                Button(NSLocalizedString("Cancel", comment: "")) { showPlan = false }
                    .buttonStyle(.plain).foregroundStyle(Brand.textSecondary)
                PillButton(title: willClean ? "Permanently clean and run" : "Run") {
                    showPlan = false
                    runSafeSet()
                }
                .disabled(!policy.permitsRun(irreversibleConsent: irreversibleConsent))
                .opacity(policy.permitsRun(irreversibleConsent: irreversibleConsent) ? 1 : 0.4)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(Brand.nearBlack)
        .environment(\.colorScheme, .dark)
    }

    private func prepareRunReview() {
        irreversibleConsent = false
        pendingCleanupPlan = nil
        if includeClean, !(model.snapshot?.cleanableText.isEmpty ?? true) {
            do {
                guard let list = CleanList.loadLive() else {
                    throw NSError(domain: "dev.caezium.burrow.cleanup", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "The engine did not produce a valid itemized cleanup preview."])
                }
                let user = try InvokingUserIdentity.current()
                let snapshot = try CleanupSnapshot.capture(
                    list: list, approvedRootURLs: CleanupSnapshot.approvedRoots(for: user))
                let paths = snapshot.items.map(\.identity.path)
                pendingCleanupPlan = try snapshot.plan(selectedPaths: paths)
            } catch {
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("The cleanup preview can't be authorized", comment: "")
                alert.informativeText = String(format: NSLocalizedString("Nothing will run until you rescan. (%@)", comment: ""), error.localizedDescription)
                alert.alertStyle = .warning
                alert.runModalQuiet()
                return
            }
        }
        showPlan = true
    }

    private func planRow(glyph: String, title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: glyph).font(.system(size: 13)).foregroundStyle(accent).frame(width: 18)
            Text(title).font(Brand.sans(13, .medium)).foregroundStyle(Brand.textPrimary)
            Spacer()
            Text(value).font(Brand.mono(12)).foregroundStyle(Brand.textSecondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Brand.cardFill))
    }

    // MARK: - Navigation

    private func navigate(_ pane: Pane) {
        NotificationCenter.default.post(name: .burrowSelectPane, object: pane)
    }
}
