//
//  MoInteractive.swift
//  Burrow
//
//  Drives Mole's INTERACTIVE selection TUIs (`mo installer`, `mo purge`)
//  from the GUI so the user can pick WHICH items to remove — and Mole
//  itself does the deletion. Mole exposes no flags/JSON for targeted
//  removal; its only selection is the on-screen checklist. So Burrow runs
//  `mo` in a pseudo-terminal, parses that checklist into a native list,
//  and replays the user's choices as keystrokes (↓ / Space / Enter).
//
//  The pure parts here — parsing a screen and planning keystrokes — are
//  unit-tested. The PTY plumbing (PTYTask / MoInteractiveRunner) is the
//  thin impure seam. Crucially, after sending the toggles we RE-READ the
//  screen and verify the selection matches before pressing Enter, so a
//  parsing/cursor bug can never make Mole delete the wrong thing.
//

import Foundation
import Darwin   // openpty, winsize

// MARK: - Parsed TUI model

struct MoTUIItem: Equatable {
    let name: String
    let size: String        // as Mole prints it, e.g. "1.26GB"
    let location: String    // e.g. "Desktop"
    let selected: Bool      // ● vs ○
}

struct MoTUIScreen: Equatable {
    let items: [MoTUIItem]
    let cursor: Int          // index with the ➤ marker
    let selectedCount: Int?  // from the "N selected" header, if present
}

enum MoTUI {
    // Glyphs Mole's TUI uses.
    private static let unchecked: Character = "\u{25CB}"  // ○
    private static let checked: Character = "\u{25CF}"    // ●
    private static let cursorMark: Character = "\u{27A4}" // ➤

    /// Parse the LAST rendered frame of a Mole selection TUI. The TUI
    /// redraws the whole list each keystroke; each frame begins with a
    /// "… N selected" header, so resetting on every header leaves us with
    /// the most recent frame's state.
    static func parse(_ raw: String) -> MoTUIScreen {
        let text = stripANSI(raw)
        var items: [MoTUIItem] = []
        var cursor = 0
        var selectedCount: Int?

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\r", with: "")
            if let n = selectedCountIn(line) {       // header → start a fresh frame
                selectedCount = n
                items = []
                cursor = 0
                continue
            }
            guard let (item, isCursor) = parseItem(line) else { continue }
            if isCursor { cursor = items.count }
            items.append(item)
        }
        return MoTUIScreen(items: items, cursor: cursor, selectedCount: selectedCount)
    }

    /// The indices currently checked (●) in a screen.
    static func selectedIndices(_ screen: MoTUIScreen) -> Set<Int> {
        Set(screen.items.enumerated().filter { $0.element.selected }.map { $0.offset })
    }

    /// Keystrokes to drive the list from its CURRENT checked state to exactly
    /// `wanted` checked. Walks every item top-to-bottom once (cursor starts at
    /// row 0), pressing Space only on rows whose current state differs from
    /// what's wanted — deterministic, no cursor math. `current` is the set of
    /// rows already checked (●); pass [] for a fresh all-unchecked list.
    ///
    /// Toggling the *difference* (not blindly Space-ing `wanted`) is what makes
    /// this work for `mo purge`, whose list renders with most rows PRE-SELECTED
    /// by default — the old "everything starts ○" assumption left those defaults
    /// checked, so the on-screen selection never matched what the user picked and
    /// the safety guard aborted every purge ("Couldn't confirm the selection
    /// safely"). `installer` starts all-○, so `current: []` reproduces the old
    /// behavior there. `confirm` appends Enter. Does NOT confirm an empty selection.
    static func keystrokesToSelect(_ wanted: Set<Int>, count: Int, currentlySelected current: Set<Int> = [], confirm: Bool) -> [UInt8] {
        let down: [UInt8] = [0x1b, 0x5b, 0x42]   // ESC [ B
        let space: UInt8 = 0x20
        let enter: UInt8 = 0x0d
        var out: [UInt8] = []
        guard count > 0 else { return out }
        for i in 0..<count {
            if wanted.contains(i) != current.contains(i) { out.append(space) }  // toggle only where state must change
            if i < count - 1 { out.append(contentsOf: down) }
        }
        if confirm && !wanted.isEmpty { out.append(enter) }
        return out
    }

    static let quit: [UInt8] = [0x71]  // 'q'
    static let down: [UInt8] = [0x1b, 0x5b, 0x42]  // ESC [ B
    static let up: [UInt8] = [0x1b, 0x5b, 0x41]    // ESC [ A

    /// Merge a freshly-parsed viewport into the running ordered list, appending
    /// only rows we haven't seen yet (identity = name+size+location). Mole's
    /// selection TUI renders a fixed-height scrolling window (≈50 rows max), so
    /// reaching every item on a long list means scrolling and stitching the
    /// overlapping frames back into one ordered list. Pure → unit-tested.
    static func mergeItems(_ acc: [MoTUIItem], _ viewport: [MoTUIItem]) -> [MoTUIItem] {
        var out = acc
        var seen = Set(acc.map(identity))
        for item in viewport where seen.insert(identity(item)).inserted {
            out.append(item)
        }
        return out
    }

    private static func identity(_ i: MoTUIItem) -> String {
        "\(i.name)\u{1}\(i.size)\u{1}\(i.location)"
    }

    /// Total item count from a "[current/total]" header. Mole caps how many
    /// rows it renders (≈50), so on a long list the header total exceeds the
    /// number we can parse — the UI uses this to say "showing N of M".
    static func totalCount(_ raw: String) -> Int? {
        let text = stripANSI(raw)
        guard let r = text.range(of: #"\[\d+/(\d+)\]"#, options: .regularExpression) else { return nil }
        let inside = text[r].dropFirst().dropLast()      // "1/53"
        return Int(inside.split(separator: "/").last.map(String.init) ?? "")
    }

    /// The N from Mole's final confirm screen. Mole's wording varies by tool
    /// and version: `purge` says "Remove 3 artifacts, 1.2GB", `installer` says
    /// "Delete 1 installers, 771KB". Matching only "Remove" silently broke the
    /// installer flow (the count never parsed, so we timed out at the confirm
    /// screen — "didn't reach its confirm screen in time"). Accept any of the
    /// verbs Mole uses, taking the integer that immediately follows.
    static func removalCount(_ raw: String) -> Int? {
        let text = stripANSI(raw)
        guard let r = text.range(of: #"(?:Remove|Delete|Clean|Trash|Free)\s+(\d+)"#,
                                 options: .regularExpression) else { return nil }
        return Int(text[r].filter(\.isNumber))
    }

    // MARK: - Parsing helpers

    private static func selectedCountIn(_ line: String) -> Int? {
        guard let r = line.range(of: #"(\d+)\s+selected"#, options: .regularExpression) else { return nil }
        return Int(line[r].split(separator: " ").first ?? "")
    }

    /// Parse one item row → (item, isCursorLine). Returns nil for non-item
    /// lines (header, footer, blanks).
    private static func parseItem(_ line: String) -> (MoTUIItem, Bool)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let markerIdx = trimmed.firstIndex(where: { $0 == checked || $0 == unchecked }) else { return nil }
        let isCursor = trimmed.first == cursorMark
        let selected = trimmed[markerIdx] == checked
        let rest = trimmed[trimmed.index(after: markerIdx)...].trimmingCharacters(in: .whitespaces)
        // rest: "Inkling-0.0.1.dmg                 771KB | Desktop"
        let pipeParts = rest.components(separatedBy: "|")
        let location = pipeParts.count > 1 ? pipeParts[1].trimmingCharacters(in: .whitespaces) : ""
        let left = pipeParts[0].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard left.count >= 2 else { return nil }
        let size = left.last!
        let name = left.dropLast().joined(separator: " ")
        guard !name.isEmpty else { return nil }
        return (MoTUIItem(name: name, size: size, location: location, selected: selected), isCursor)
    }

    /// Strip CSI escape sequences so the TUI's redraw control codes don't
    /// pollute parsing. Delegates to the one `Ansi.strip`.
    static func stripANSI(_ s: String) -> String { Ansi.strip(s) }
}

// MARK: - Pseudo-terminal task

/// A child process attached to a pseudo-terminal, so a TUI program (Mole's
/// selection screen) believes it's interactive. The production `PTYPort`: it
/// owns its read loop and delivers output/exit on the main thread so the host
/// reducer stays single-threaded. The only impure seam — kept tiny.
final class PTYTask: PTYPort {
    /// One launch's private state. Both callbacks close over their own instance,
    /// so a handler still armed from an earlier child can never read the CURRENT
    /// child's process, launch flag, or exit code.
    ///
    /// A rescan makes that concrete: it's only reachable from the chooser, where
    /// the old `mo` is still sitting at the selection screen, so `terminate()`
    /// SIGTERMs a live child and its terminationHandler fires on a background
    /// thread *after* `launch()` has already reset the exactly-once flag for the
    /// new one. Reported untagged, that stale exit lands on the fresh scan, and
    /// `SelectionSession.exited` turns an exit-before-any-list into `.done` — so
    /// the rescan finished instantly with the previous child's SIGTERM status.
    private final class Generation {
        let id: UInt64
        let child: Process
        /// `isRunning` is `false` for BOTH a finished process and a never-launched
        /// one, so it can't distinguish "already reaped" from "run() threw". Only a
        /// process that actually launched may report `terminationStatus`; reading it
        /// from a never-launched child raises `NSInvalidArgumentException` ("task not
        /// launched"), which Swift cannot catch — Sentry BURROW-A5, issue #374. Track
        /// the launch state so the EOF branch never asks a never-spawned child for
        /// its exit code.
        var didLaunch = false
        init(id: UInt64, child: Process) { self.id = id; self.child = child }
    }

    /// The launch entitled to speak for this task. Main-confined: `launch()`
    /// replaces it, and every callback's captured id is compared against it on
    /// main, so the check never races the swap.
    private var current: Generation?
    private var launchCount: UInt64 = 0
    private var master: FileHandle?

    var onOutput: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?

    /// Both the terminationHandler and the EOF branch can observe the same
    /// exit; the session must hear about it exactly once. Main-confined —
    /// both reporters dispatch here.
    private var reportedExit = false

    /// Report only for the live launch. A callback carrying a retired id belongs
    /// to a child the host has already torn down and moved past.
    private func reportExitOnce(_ code: Int32, from id: UInt64) {
        guard id == current?.id, !reportedExit else { return }
        reportedExit = true
        onExit?(code)
    }

    /// Same gate for output: bytes a dead child wrote must never be parsed as
    /// the new scan's screen.
    private func deliverOutput(_ text: String, from id: UInt64) {
        guard id == current?.id else { return }
        onOutput?(text)
    }

    private let cols: UInt16
    private let rows: UInt16
    /// `rows` controls how many list rows Mole's TUI renders in one frame (it
    /// caps the viewport ≈50); 60 covers the common case, with scroll-capture
    /// handling longer lists.
    init(cols: UInt16 = 120, rows: UInt16 = 60) { self.cols = cols; self.rows = rows }

    func launch(_ executable: String, _ args: [String]) throws {
        // A Process can only be run ONCE; a rescan calls launch again, so start
        // from a fresh instance each time. (Reusing the old one left the second
        // scan with a dead, never-spawning child — the UI hung on "Scanning…".)
        let proc = Process()
        launchCount &+= 1
        let gen = Generation(id: launchCount, child: proc)
        // Don't depend on the caller having terminated first. A relaunch over a
        // live `master` would otherwise leave its read handler armed, and the
        // dispatch source holding that handler keeps the FileHandle alive — so
        // its fd would never close. Generation tagging already makes a late
        // delivery harmless; this is about the descriptor, not correctness.
        master?.readabilityHandler = nil
        var amaster: Int32 = 0
        var aslave: Int32 = 0
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&amaster, &aslave, nil, nil, &ws) == 0 else {
            throw NSError(domain: "burrow.pty", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "openpty failed"])
        }
        let slave = FileHandle(fileDescriptor: aslave, closeOnDealloc: false)
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        proc.standardInput = slave
        proc.standardOutput = slave
        proc.standardError = slave
        var env = Foundation.ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        proc.environment = env
        // Capture the id, not `gen` — a Process retains its terminationHandler,
        // so closing over the Generation (which holds the Process) would be a
        // retain cycle that outlives the child.
        let id = gen.id
        proc.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            DispatchQueue.main.async { self?.reportExitOnce(code, from: id) }
        }
        let m = FileHandle(fileDescriptor: amaster, closeOnDealloc: true)
        m.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let d = h.availableData
            if d.isEmpty {
                // EOF: the child closed the pty (it exited). Stop reading — left
                // armed, an empty-data handler spins in a tight loop and starves
                // the process's terminationHandler, so the exit would never be
                // reported and the UI would hang (e.g. when Mole finds nothing and
                // exits before the chooser). If the process is already reaped,
                // report the exit ourselves; otherwise the now-unstarved
                // terminationHandler will.
                h.readabilityHandler = nil
                // This launch's own child and flag — never `current`'s, which
                // after a rescan is a different process whose status says nothing
                // about this EOF. Only a launched process has a valid exit code:
                // if run() threw, didLaunch is false and reading terminationStatus
                // would raise "task not launched" (#374).
                if gen.didLaunch && !gen.child.isRunning {
                    let code = gen.child.terminationStatus
                    DispatchQueue.main.async { self.reportExitOnce(code, from: gen.id) }
                }
                return
            }
            guard let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async { self.deliverOutput(s, from: gen.id) }
        }
        master = m
        // Close the parent's slave fd whether or not the launch succeeds — on a
        // throw the child never starts, so nothing else would ever close it.
        do { try proc.run() }
        catch {
            // The child never started, so it can never report an exit. Disarm the
            // read handler and drop the master fd BEFORE closing the slave: that
            // close is what makes the master see EOF, and a handler firing then
            // would ask a never-launched child for terminationStatus (#374).
            m.readabilityHandler = nil
            master = nil
            close(aslave)
            throw error
        }
        // Also set before the slave closes, for the same reason in reverse: a
        // child that exits instantly would otherwise reach the EOF branch while
        // this launch still looked unlaunched, and its exit would go unreported.
        gen.didLaunch = true
        // Retire the previous generation only once this one is actually running:
        // a launch that threw must leave the old child still able to report its
        // exit, rather than installing a never-started generation that silently
        // outranks it. Safe to defer — launch() runs on main and every callback
        // compares ids on main, so this assignment always lands first.
        current = gen
        // New child, new exactly-once exit report.
        reportedExit = false
        close(aslave)   // parent doesn't use the slave end
    }

    /// PTY writes go through a dedicated serial queue so a blocked `write()`
    /// — the `mo` child not draining its stdin — can never park the @MainActor
    /// caller (issue #73 / Sentry BURROW-D: the 0.06 s selection-replay tick
    /// runs on the main queue). The serial queue preserves keystroke order;
    /// the captured handle keeps the fd alive for an in-flight write even if
    /// `master` is swapped out underneath it — by a relaunch, or dropped by a
    /// failed one. (`terminate()` only disarms the read handler; it leaves the
    /// handle itself in place.) The master fd is otherwise
    /// only touched by the FileHandle read handler, and read/write on a pty are
    /// independent directions, so there's no fd race.
    private let writeQueue = DispatchQueue(label: "dev.caezium.burrow.pty-write")

    func send(_ bytes: [UInt8]) {
        guard let master else { return }
        let data = Data(bytes)
        writeQueue.async { try? master.write(contentsOf: data) }
    }
    /// Deliberately does NOT retire the current generation: a terminate with no
    /// relaunch behind it (the reducer's `.terminate` effect, `cancel()`) still
    /// wants to hear the child's exit. Only `launch()` retires a generation,
    /// because only a relaunch means the host has moved on to another child.
    func terminate() {
        master?.readabilityHandler = nil
        if let child = current?.child, child.isRunning { child.terminate() }
    }
}
