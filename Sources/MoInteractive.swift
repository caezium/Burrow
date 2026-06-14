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

    /// Keystrokes to take a FRESH list (cursor at item 0, everything ○) to
    /// exactly `wanted` checked. Walks every item top-to-bottom once,
    /// pressing Space only on wanted ones — deterministic, no cursor math.
    /// `confirm` appends Enter. Does NOT confirm an empty selection.
    static func keystrokesToSelect(_ wanted: Set<Int>, count: Int, confirm: Bool) -> [UInt8] {
        let down: [UInt8] = [0x1b, 0x5b, 0x42]   // ESC [ B
        let space: UInt8 = 0x20
        let enter: UInt8 = 0x0d
        var out: [UInt8] = []
        guard count > 0 else { return out }
        for i in 0..<count {
            if wanted.contains(i) { out.append(space) }
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
    private var proc = Process()   // replaced on each launch (a Process runs once)
    private var master: FileHandle?

    var onOutput: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?

    /// Both the terminationHandler and the EOF branch can observe the same
    /// exit; the session must hear about it exactly once. Main-confined —
    /// both reporters dispatch here.
    private var reportedExit = false
    private func reportExitOnce(_ code: Int32) {
        guard !reportedExit else { return }
        reportedExit = true
        onExit?(code)
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
        proc = Process()
        // New child, new exactly-once exit report.
        reportedExit = false
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
        proc.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            DispatchQueue.main.async { self?.reportExitOnce(code) }
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
                if !self.proc.isRunning {
                    let code = self.proc.terminationStatus
                    DispatchQueue.main.async { self.reportExitOnce(code) }
                }
                return
            }
            guard let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async { self.onOutput?(s) }
        }
        master = m
        // Close the parent's slave fd whether or not the launch succeeds — on a
        // throw the child never starts, so nothing else would ever close it.
        do { try proc.run() }
        catch { close(aslave); throw error }
        close(aslave)   // parent doesn't use the slave end
    }

    /// PTY writes go through a dedicated serial queue so a blocked `write()`
    /// — the `mo` child not draining its stdin — can never park the @MainActor
    /// caller (issue #73 / Sentry BURROW-D: the 0.06 s selection-replay tick
    /// runs on the main queue). The serial queue preserves keystroke order;
    /// the captured handle keeps the fd alive for an in-flight write even if
    /// `terminate()` clears `master` underneath it. The master fd is otherwise
    /// only touched by the FileHandle read handler, and read/write on a pty are
    /// independent directions, so there's no fd race.
    private let writeQueue = DispatchQueue(label: "dev.caezium.burrow.pty-write")

    func send(_ bytes: [UInt8]) {
        guard let master else { return }
        let data = Data(bytes)
        writeQueue.async { try? master.write(contentsOf: data) }
    }
    func terminate() {
        master?.readabilityHandler = nil
        if proc.isRunning { proc.terminate() }
    }
}
