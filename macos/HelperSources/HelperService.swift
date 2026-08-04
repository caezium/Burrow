//
//  HelperService.swift
//  BurrowHelper
//
//  The root daemon. This process runs as uid 0, so every line here is written
//  on the assumption that the thing talking to it is hostile until proven
//  otherwise.
//
//  ── The gauntlet a request runs ─────────────────────────────────────────
//  Five gates, in this order, each of which fails CLOSED:
//
//    1. Connection    the peer's AUDIT TOKEN must satisfy the code
//                     requirement (Burrow, signed by our team). PIDs are
//                     never used — they can be recycled and raced.
//    2. Shape         the payload must decode as a `HelperRequest`. The
//                     operation is an enum, so an unknown verb dies here.
//    3. Freshness     the operation ID must be a UUID this daemon has never
//                     served. One authorization, one operation.
//    4. Authorization `AuthorizationCopyRights` must GRANT the right, which
//                     raises the system authentication prompt. This is the
//                     gate, not a GUI-side prompt.
//    5. Execution     argv is derived from the enum, and the executable is
//                     the signed engine inside our own bundle, verified
//                     before it is spawned.
//
//  Note what is absent: there is no path at which a caller-supplied string
//  becomes part of a command line. That is the property the whole design
//  exists to preserve.
//

import Foundation
import Security
import os

// MARK: - Logging
//
// Privileged code logs to the unified log, which is world-readable. So it
// records DECISIONS, never content: no paths, no filenames, no command
// output, no authentication material, no free-form error text. Operation IDs
// are UUIDs the daemon itself validated, and every other value logged here is
// drawn from a closed enum.

let helperLog = Logger(subsystem: "dev.caezium.Burrow.helper", category: "privileged")

// MARK: - Engine resolution

enum HelperEngine {

    /// The signed engine inside the app bundle that contains this helper,
    /// resolved RELATIVE TO OUR OWN EXECUTABLE:
    ///
    ///   …/Burrow.app/Contents/MacOS/BurrowHelper   ← us
    ///   …/Burrow.app/Contents/Resources/engine/mole ← the engine
    ///
    /// Never `PATH`, never an environment variable, never a caller-supplied
    /// path. A root process that resolves its executable through any of those
    /// hands root to whoever wins the race to shadow the name — which is the
    /// exact reason `MoleCLI.trustedExecutable()` already refuses PATH on the
    /// osascript path.
    static func bundledEnginePath() -> String? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let contents = executable            // …/Contents/MacOS/BurrowHelper
            .deletingLastPathComponent()     // …/Contents/MacOS
            .deletingLastPathComponent()     // …/Contents
        let engine = contents
            .appendingPathComponent("Resources/engine/mole")
            .standardizedFileURL

        // Belt and braces: after standardizing, the engine must still sit
        // inside our own Contents directory. A symlink pointing out of the
        // bundle would otherwise be followed as root.
        guard engine.path.hasPrefix(contents.standardizedFileURL.path + "/") else { return nil }
        guard FileManager.default.isExecutableFile(atPath: engine.path) else { return nil }
        return engine.path
    }

    /// Verify the engine carries our own signature before running it as root.
    ///
    /// The app bundle is signed as a unit, so an attacker who can rewrite the
    /// engine binary has already broken the app's seal — but they may have
    /// done so on a machine where Gatekeeper never re-evaluates the bundle
    /// after first launch. Checking here means a tampered engine is refused at
    /// the moment it would gain root, not merely at install time.
    ///
    /// On an ad-hoc (local development) build there is no team to pin, so the
    /// check is skipped and the fact is logged. Release builds always have
    /// one, and the release gate refuses to ship a helper without it.
    static func verify(path: String, teamID: String?) -> Bool {
        guard let teamID else {
            helperLog.notice("engine signature check skipped: helper is ad-hoc signed (development build)")
            return true
        }
        guard let requirement = HelperCodeRequirement.sameTeam(teamID: teamID) else { return false }

        var staticCode: SecStaticCode?
        let url = URL(fileURLWithPath: path) as CFURL
        guard SecStaticCodeCreateWithPath(url, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }

        var secRequirement: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &secRequirement) == errSecSuccess,
              let secRequirement else { return false }

        return SecStaticCodeCheckValidity(staticCode, [], secRequirement) == errSecSuccess
    }
}

// MARK: - Running one operation

/// Spawns the engine and streams its output back to the client.
///
/// The daemon owns the child directly, which is the structural gain over the
/// osascript path: there, cancelling meant killing `osascript` and orphaning
/// the root child it had spawned, so the streaming flow simply had no safe
/// cancel. Here the child is ours to signal and reap.
final class HelperOperationRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var running: [String: Process] = [:]

    /// Run `operation`'s fixed argv and block until it exits, forwarding whole
    /// lines to `emit` as they arrive.
    func run(operation: HelperOperation,
             operationID: String,
             enginePath: String,
             emit: @escaping (String) -> Void) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: enginePath)
        // Fixed argv, built from the enum. No caller input reaches this array.
        process.arguments = operation.engineArguments

        // A deliberately minimal environment. The child is root, so anything
        // inherited from the launchd context that could redirect a lookup
        // (PATH, DYLD_*, the engine's own overrides) is dropped rather than
        // passed through.
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "LC_ALL": "C",
        ]

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            helperLog.error("engine spawn failed for operation \(operationID, privacy: .public)")
            return 127
        }

        lock.lock(); running[operationID] = process; lock.unlock()
        defer { lock.lock(); running.removeValue(forKey: operationID); lock.unlock() }

        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()

        // One reader per pipe, both draining to EOF before the exit status is
        // read, so no output can be lost between the last write and the reap.
        let splitter = HelperLineSplitter()
        let group = DispatchGroup()
        for handle in [outPipe.fileHandleForReading, errPipe.fileHandleForReading] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                while case let chunk = handle.availableData, !chunk.isEmpty {
                    guard let text = String(data: chunk, encoding: .utf8) else { continue }
                    for line in splitter.ingest(text) { emit(line) }
                }
                group.leave()
            }
        }
        group.wait()
        for line in splitter.flush() { emit(line) }

        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Terminate a running operation. Returns whether anything was running.
    func cancel(operationID: String) -> Bool {
        lock.lock(); let process = running[operationID]; lock.unlock()
        guard let process, process.isRunning else { return false }
        process.terminate()
        return true
    }

    var hasWork: Bool {
        lock.lock(); defer { lock.unlock() }
        return !running.isEmpty
    }
}

/// Buffers partial reads and emits whole lines. Mirrors the GUI's splitter so
/// both elevation routes deliver output the same way.
final class HelperLineSplitter: @unchecked Sendable {
    private var buffer = ""
    private let lock = NSLock()

    func ingest(_ text: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer += text
        var parts = buffer.components(separatedBy: "\n")
        buffer = parts.removeLast()
        return parts
    }

    func flush() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let rest = buffer
        buffer = ""
        return rest.isEmpty ? [] : [rest]
    }
}

// MARK: - The XPC service

final class HelperService: NSObject, BurrowHelperProtocol {
    private let replayGuard = HelperReplayGuard()
    private let runner = HelperOperationRunner()
    private let teamID: String?

    /// The client callback for the connection currently being served. Set by
    /// the listener delegate per connection.
    weak var currentConnection: NSXPCConnection?

    init(teamID: String?) {
        self.teamID = teamID
        super.init()
    }

    var isIdle: Bool { !runner.hasWork }

    /// This helper's own build, baked into the binary's embedded Info.plist
    /// section at compile time — so it reports what it IS, not what the app
    /// bundle around it currently claims to be.
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }

    func helperBuild(withReply reply: @escaping (String) -> Void) {
        reply(Self.build)
    }

    func cancelOperation(operationID: String, withReply reply: @escaping (Bool) -> Void) {
        // Cancellation stops work; it never starts any, so it needs no
        // authorization of its own. The connection gate has already
        // established that the caller is Burrow, and an ID it doesn't know
        // simply isn't running.
        guard UUID(uuidString: operationID) != nil else { return reply(false) }
        reply(runner.cancel(operationID: operationID))
    }

    func execute(requestData: Data, authorization: Data, withReply reply: @escaping (Data) -> Void) {
        func respond(_ outcome: HelperResponse.Outcome) {
            let encoded = (try? JSONEncoder().encode(HelperResponse(outcome: outcome))) ?? Data()
            reply(encoded)
        }

        // Gate 2 — shape. An unknown operation cannot survive decoding.
        guard let request = try? JSONDecoder().decode(HelperRequest.self, from: requestData) else {
            helperLog.error("request refused: malformed payload")
            return respond(.rejected(.malformedPayload))
        }

        if let rejection = request.validate(expectedBuild: Self.build) {
            helperLog.error("request refused: \(rejection.rawValue, privacy: .public)")
            return respond(.rejected(rejection))
        }

        // Gate 3 — freshness. One authorization buys exactly one operation, so
        // a captured payload cannot be replayed for a second root run.
        guard replayGuard.admit(request.operationID) else {
            helperLog.error("request refused: replayed operation ID")
            return respond(.rejected(.replayedOperationID))
        }

        // Gate 4 — authorization. This is what raises the prompt, and it
        // happens HERE, in the privileged process, on every single operation.
        let decision = HelperAuthorization.authorize(externalForm: authorization)
        guard decision.permitsExecution else {
            helperLog.notice("""
                operation \(request.operation.rawValue, privacy: .public) not authorized
                """)
            switch decision {
            case .cancelled: return respond(.authorizationCancelled)
            default: return respond(.authorizationDenied)
            }
        }

        // Gate 5 — execution. Our own signed engine, fixed argv.
        guard let enginePath = HelperEngine.bundledEnginePath(),
              HelperEngine.verify(path: enginePath, teamID: teamID) else {
            helperLog.error("engine unavailable or failed signature verification")
            return respond(.engineUnavailable)
        }

        helperLog.notice("""
            authorized \(request.operation.rawValue, privacy: .public) \
            (mutating: \(request.operation.mutatesDisk, privacy: .public))
            """)

        let client = currentConnection?.remoteObjectProxy as? BurrowHelperClientProtocol
        let operationID = request.operationID
        let code = runner.run(operation: request.operation,
                              operationID: operationID,
                              enginePath: enginePath) { line in
            client?.helperDidEmit(line: line, operationID: operationID)
        }
        helperLog.notice("operation finished with status \(code, privacy: .public)")
        respond(.exited(code))
    }
}

// MARK: - Connection gate

/// Gate 1. By the time this delegate runs, the system has ALREADY evaluated
/// the code requirement set on the listener against the connecting peer — see
/// `HelperMain.start`. A caller that isn't Burrow, signed by our team, never
/// reaches this method at all.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: HelperService

    init(service: HelperService) {
        self.service = service
        super.init()
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = HelperInterface.daemon()
        connection.exportedObject = service
        connection.remoteObjectInterface = HelperInterface.client()
        service.currentConnection = connection
        connection.resume()
        helperLog.notice("connection accepted from a verified Burrow client")
        return true
    }
}
