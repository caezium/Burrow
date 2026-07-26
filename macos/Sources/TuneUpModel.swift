//
//  TuneUpModel.swift
//  Burrow
//
//  The Tune-Up pane's brain (#77). On entry it runs the read-only/preview
//  scans across the six review sources and flags what's worth a look; the
//  result is one Codable snapshot persisted to Store so the pane shows
//  instantly on re-entry and survives relaunch. Nothing here spawns a new
//  process path — every scan reuses an existing engine:
//
//    • Cleanable junk  → `mo clean --dry-run`     (the engine's JSON envelope,
//                                                   read via cleanableSpace(fromCaptureStdout:))
//    • Maintenance     → `mo optimize --dry-run`  (envelope again, via optimizeAreas(fromCaptureStdout:))
//    • Apps to remove  → `mo uninstall --list`    (MoleClient.listApps, by size)
//    • Startup items   → StartupInventory.scanLive vs the persisted baseline
//    • Big disk users  → `mo analyze` on ~          (DiskScanner.scan)
//
//  NOTE on clean/optimize: the bundled engine ALWAYS answers in its JSON envelope — there is
//  no human-text mode (confirmed against burrow-engine's own main.rs/cli.rs). `parseTaskReport`
//  (TaskReport.swift) is a text-marker parser built for legacy mo/streamed output; feeding it a
//  one-line JSON blob used to silently match nothing, so this pane always reported "nothing to
//  clean" / "nothing to optimize" whenever the bundled engine is what actually ran — which in a
//  shipped app is always. Read the envelope's structured fields instead — see the two helpers
//  below, which fall back to `parseTaskReport` only when the capture ISN'T envelope-shaped at
//  all (the bundled engine is missing and a legacy `mo`/MIT-fork binary answered instead).
//
//  App updates are deliberately NOT auto-scanned here — that contacts Apple /
//  vendor appcasts, which the pre-scan-on-open feedback says must stay
//  click-gated. The updates section is a review deep-link instead.
//
//  NOTE (hand-test): compile-verified only. Verify the scan populates each
//  section against a real machine and that re-entry reads the cached snapshot.
//

import SwiftUI
import AppKit

// MARK: - Persisted snapshot

/// The last Tune-Up scan plus the last safe-set run. Encoded to
/// `Store.tuneUpStateJSON`. Display strings are baked in at scan time
/// (sizes already humanized) so the dashboard renders with zero work.
struct TuneUpSnapshot: Codable {
    var scannedAt: Date

    // Safe set — reversible, one-tap runnable.
    var cleanableText: String       // "383.8MB" from the clean dry-run, "" if none
    var optimizeAreas: [String]     // optimize dry-run task descriptions (only .isEmpty/.count are shown)

    // Review-only — flagged here, acted on in their own panes.
    var bigApps: [AppLite]
    var newStartup: [String]        // login items new since the baseline
    var startupControllable: Int    // total user-controllable login items
    var bigDisk: [DiskLite]

    // Last safe-set run.
    var lastRunAt: Date?
    var lastRunSummary: String?

    struct AppLite: Codable, Identifiable, Hashable {
        var id: String
        var name: String
        var sizeBytes: Int64
        var uninstallName: String
    }
    struct DiskLite: Codable, Identifiable, Hashable {
        var id: String
        var name: String
        var path: String
        var size: Int64
    }

    /// Whether any section has something worth surfacing — drives the
    /// "you're already tidy" empty state.
    var hasFindings: Bool {
        !cleanableText.isEmpty || !optimizeAreas.isEmpty || !bigApps.isEmpty
            || !newStartup.isEmpty || !bigDisk.isEmpty
    }
}

// MARK: - Model

@MainActor
final class TuneUpModel: ObservableObject {
    @Published private(set) var snapshot: TuneUpSnapshot?
    @Published private(set) var scanning = false
    /// What the scan is doing right now — shown next to the spinner.
    @Published private(set) var progress = ""

    init() { snapshot = Self.load() }

    /// First-ever entry (no cached snapshot) kicks off a scan; later entries
    /// read the cache instantly. Re-scan is always explicit after that.
    func scanIfNeeded() {
        if snapshot == nil, !scanning { rescan() }
    }

    func rescan() {
        guard !scanning else { return }
        scanning = true
        progress = NSLocalizedString("Looking around the den…", comment: "")
        // Carry the last-run record across a re-scan — re-scanning doesn't undo
        // a tune-up that already happened.
        let prevRunAt = snapshot?.lastRunAt
        let prevRunSummary = snapshot?.lastRunSummary

        Task {
            async let cleanable = Self.scanCleanable()
            async let optimize = Self.scanOptimize()
            async let apps = Self.scanBigApps()
            async let startup = Self.scanStartup()
            async let disk = Self.scanBigDisk()

            let cleanText = await cleanable
            let optAreas = await optimize
            let bigApps = await apps
            let (newStartup, controllable) = await startup
            let bigDisk = await disk

            let snap = TuneUpSnapshot(
                scannedAt: Date(),
                cleanableText: cleanText,
                optimizeAreas: optAreas,
                bigApps: bigApps,
                newStartup: newStartup,
                startupControllable: controllable,
                bigDisk: bigDisk,
                lastRunAt: prevRunAt,
                lastRunSummary: prevRunSummary)
            self.snapshot = snap
            Self.save(snap)
            self.scanning = false
            self.progress = ""
        }
    }

    /// Record the outcome of a safe-set run onto the current snapshot.
    func recordRun(summary: String) {
        guard var snap = snapshot else { return }
        snap.lastRunAt = Date()
        snap.lastRunSummary = summary
        snapshot = snap
        Self.save(snap)
    }

    // MARK: Scans (each reuses an existing engine, off the main thread)

    private static func scanCleanable() async -> String {
        await Task.detached(priority: .utility) { () -> String in
            guard let res = try? MoEngine.shared.capture(
                    MoCommand(target: .mo, args: ["clean", "--dry-run"], timeout: 120)),
                  res.exitCode == 0 else { return "" }
            return Self.cleanableSpace(fromCaptureStdout: res.stdout)
        }.value
    }

    private static func scanOptimize() async -> [String] {
        await Task.detached(priority: .utility) { () -> [String] in
            guard let res = try? MoEngine.shared.capture(
                    MoCommand(target: .mo, args: ["optimize", "--dry-run"], timeout: 120)),
                  res.exitCode == 0 else { return [] }
            return Self.optimizeAreas(fromCaptureStdout: res.stdout)
        }.value
    }

    /// Pull the would-free size out of a buffered `clean --dry-run` capture. The bundled engine's
    /// envelope carries structured fields (`total_bytes`/`total_human`) alongside a `text`
    /// rendering kept for other consumers (e.g. the streaming reducer) — read the structured
    /// field directly rather than re-parsing that text with the marker-based `parseTaskReport`.
    ///
    /// Whether the capture decodes as an envelope AT ALL is the fork, not the value inside it:
    /// if it does, that's the bundled engine and its structured fields are authoritative (even a
    /// genuine `total_bytes: 0` means nothing to clean — it does not fall through). If it
    /// doesn't, `.mo` resolved to a legacy `mo`/MIT-fork binary instead (the bundled engine is
    /// missing — a dev build, or a broken install) and THAT still speaks the marker text
    /// `parseTaskReport` was built for, so fall back to it rather than going blank in that
    /// narrower case too.
    ///
    /// `nonisolated`: this is pure and touches no actor state, and it MUST stay callable from a
    /// nonisolated context — `scanCleanable()` below calls it from inside a `Task.detached`
    /// closure (deliberately off the main actor), and `TuneUpModelEnvelopeParsingTests` calls it
    /// directly from plain (non-`@MainActor`) test methods. Without this, both call sites are a
    /// hard `main actor-isolated static method cannot be called from outside of the actor`
    /// compile error — confirmed with `swiftc -typecheck` reproducing this file's exact shape;
    /// `swiftc -parse` alone does not catch it, which is how it shipped in the first place.
    nonisolated static func cleanableSpace(fromCaptureStdout stdout: String) -> String {
        guard let envelope = try? BurrowEnvelope.parse(stdout) else {
            let (_, summary) = parseTaskReport(stdout.components(separatedBy: "\n"))
            let space = summary?.space ?? ""
            // "0B" / "0 B" reads as nothing to do.
            return space.replacingOccurrences(of: " ", with: "").hasPrefix("0") ? "" : space
        }
        guard envelope.ok, let data = envelope.data,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }
        let totalBytes = (payload["total_bytes"] as? Int64) ?? Int64(payload["total_bytes"] as? Int ?? 0)
        guard totalBytes > 0 else { return "" }
        return (payload["total_human"] as? String) ?? ""
    }

    /// One entry per maintenance task a buffered `optimize --dry-run` capture lists under
    /// `data.tasks` — same envelope-vs-text fork as `cleanableSpace` above (an envelope that
    /// decodes fine is authoritative; one that doesn't fork to the legacy marker parser).
    /// TuneUpView only ever checks `optimizeAreas.isEmpty` and `.count` (never the strings
    /// themselves), so the exact wording doesn't matter — it just needs to be non-empty and one
    /// entry per task (or per legacy group, on the fallback path).
    ///
    /// `nonisolated` for the same reason as `cleanableSpace` above — `scanOptimize()`'s
    /// `Task.detached` closure and the plain-XCTestCase tests both call this from outside the
    /// main actor.
    nonisolated static func optimizeAreas(fromCaptureStdout stdout: String) -> [String] {
        guard let envelope = try? BurrowEnvelope.parse(stdout) else {
            let (groups, _) = parseTaskReport(stdout.components(separatedBy: "\n"))
            return groups.map { TaskReportText.title($0.title) }
        }
        guard envelope.ok, let data = envelope.data,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tasks = payload["tasks"] as? [[String: Any]]
        else { return [] }
        return tasks.compactMap { $0["description"] as? String }
    }

    private static func scanBigApps() async -> [TuneUpSnapshot.AppLite] {
        await Task.detached(priority: .utility) { () -> [TuneUpSnapshot.AppLite] in
            MoleClient.listApps()
                .filter { $0.sizeBytes > 100_000_000 }       // only apps worth reviewing
                .sorted { $0.sizeBytes > $1.sizeBytes }
                .prefix(8)
                .map { TuneUpSnapshot.AppLite(id: $0.id, name: $0.name,
                                              sizeBytes: $0.sizeBytes,
                                              uninstallName: $0.uninstallName) }
        }.value
    }

    private static func scanStartup() async -> ([String], Int) {
        await Task.detached(priority: .utility) { () -> ([String], Int) in
            let live = StartupInventory.scanLive()
            let baseline = Set(Store.startupBaselineJSON.data(using: .utf8)
                .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
            // "New" only means something once a baseline exists (the watcher
            // writes it hourly); before then, surface nothing as new.
            let new = baseline.isEmpty ? [] : live.filter { !baseline.contains($0.id) }
            let controllable = live.filter { $0.controllable }.count
            return (new.map(\.label), controllable)
        }.value
    }

    private static func scanBigDisk() async -> [TuneUpSnapshot.DiskLite] {
        await Task.detached(priority: .utility) { () -> [TuneUpSnapshot.DiskLite] in
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            guard let result = try? DiskScanner.scan(home) else { return [] }
            return result.entries
                .sorted { $0.size > $1.size }
                .prefix(6)
                .map { TuneUpSnapshot.DiskLite(id: $0.id, name: $0.name,
                                               path: $0.path, size: $0.size) }
        }.value
    }

    // MARK: Persistence

    private static func load() -> TuneUpSnapshot? {
        Store.tuneUpStateJSON.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode(TuneUpSnapshot.self, from: $0) }
    }

    private static func save(_ s: TuneUpSnapshot) {
        Store.tuneUpStateJSON = (try? JSONEncoder().encode(s))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
