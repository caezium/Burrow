//
//  ConductorScanModel.swift
//  Burrow
//
//  The one scan model behind the four bundled-engine discovery panes (Duplicates, Leftovers,
//  Photos, Network). Each used to carry its own copy of the same ladder — folder / scanning /
//  report / error, a monotonic scan token so only the newest scan's result lands, the
//  OperationCenter begin/end pair, the breadcrumb helpers, and a `scan` body that ran
//  `BurrowEngine.capture` off the main thread and decoded the envelope's `data` with a pure
//  parser. What differed was data: the command, its argv, its timeout, the parser, and three
//  strings. `Command` holds exactly that, and the subclasses hold only what is genuinely theirs
//  (the Duplicates review checklist, the network pane's first-activation sample).
//

import Foundation

@MainActor
class ConductorScanModel<Report>: ObservableObject {

    /// Everything that makes one pane's scan that pane's — data, so the ladder is written once.
    struct Command {
        /// The engine command (`dupes`, `orphans`, `photos`, `net`).
        let name: String
        /// The argv for a scan of `folder` (nil for a pane that scans nothing in particular).
        let arguments: (_ folder: String?) -> [String]
        let timeout: TimeInterval
        /// The pane's pure decoder over the envelope's `data`; nil means unreadable.
        let parse: (Data) -> Report?
        /// The Activity label, given the folder's last path component (nil when there is none).
        let beginLabel: (_ folderName: String?) -> String
        /// The Activity detail for a finished scan.
        let successDetail: (Report) -> String
        /// The error shown when the engine answered but `parse` could not read it.
        let unreadable: String
    }

    /// The chosen folder (absolute path). Scans re-run against this; nil for a folderless pane.
    @Published var folder: String?
    @Published var scanning = false
    @Published var report: Report?
    @Published var error: String?

    let command: Command
    let opId = UUID()
    /// Monotonic token (same pattern as AnalyzeModel.scanGen): only the newest scan's result
    /// may land.
    private var scanGen = 0

    init(command: Command) {
        self.command = command
    }

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

    // MARK: The scan

    /// Scan `path` via the bundled engine, off the main thread.
    func scan(_ path: String) {
        folder = path
        run()
    }

    /// Hook for a subclass that derives state from a freshly loaded report (the Duplicates
    /// checklist). Runs on the main actor, before `scanning` flips back to false.
    func didLoad(_ report: Report) {}

    /// The ladder. `folder` is whatever it is at this moment — set by `scan(_:)`, or nil for a
    /// pane that samples the machine rather than a folder.
    func run() {
        scanGen += 1
        let gen = scanGen
        scanning = true
        error = nil
        report = nil
        let command = self.command
        let folder = self.folder
        let name = folder.map { ($0 as NSString).lastPathComponent }
        OperationCenter.shared.begin(opId, label: command.beginLabel(name))
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Result<Report, Error>
            do {
                let envelope = try BurrowEngine.capture(command.name, command.arguments(folder),
                                                        timeout: command.timeout)
                guard let data = envelope.data, let parsed = command.parse(data) else {
                    throw BurrowEngineError.engine(kind: ErrorKind.error.rawValue,
                                                   message: command.unreadable)
                }
                outcome = .success(parsed)
            } catch {
                outcome = .failure(error)
            }
            Task { @MainActor in
                guard gen == self.scanGen else { return }
                switch outcome {
                case .success(let r):
                    self.report = r
                    self.didLoad(r)
                    OperationCenter.shared.end(self.opId, success: true,
                                               detail: command.successDetail(r))
                case .failure(let e):
                    self.error = e.localizedDescription
                    OperationCenter.shared.end(self.opId, success: false,
                                               detail: NSLocalizedString("scan failed", comment: ""))
                }
                self.scanning = false
            }
        }
    }
}
