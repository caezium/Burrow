//
//  PrivilegedHelperClient.swift
//  Burrow
//
//  The GUI's side of the privileged helper: registration, connection, and one
//  typed operation at a time.
//
//  ── What this replaces, and what it does not ────────────────────────────
//  The existing elevation path builds a shell string and hands it to
//  `osascript … with administrator privileges` (see `MoleCLI.elevatedScript`).
//  That path is password-only by construction — the `system.privilege.admin`
//  right authenticates through SecurityAgent's classic mechanism, which never
//  offers Touch ID — and it cannot be cancelled safely, because killing
//  osascript orphans the root child it spawned.
//
//  The helper fixes both, but it can only be used once the user has approved
//  registering a launch daemon, which is its own one-time macOS prompt. Until
//  then — and if the user declines it outright — the osascript path remains,
//  unchanged, as the fallback. `PrivilegeRoute` is where that choice is made,
//  and it is a pure function so the conditions are visible and tested rather
//  than scattered through call sites.
//
//  ── The security properties this file must not weaken ──────────────────
//  * Every root operation authenticates freshly. The client never caches an
//    authorization, never reuses an operation ID, and never pre-authorizes.
//  * The client cannot describe a command. It picks a `HelperOperation`, and
//    the daemon derives argv from the enum.
//  * A helper whose build doesn't match this app is not used at all.
//

import Foundation
import Security
import ServiceManagement

// MARK: - Bridging the two elevation routes onto one taxonomy

extension HelperResponse.Outcome {
    /// Map onto the taxonomy the GUI already renders, so the helper route and
    /// the osascript route produce the same user-facing message and no call
    /// site needs to know which one ran.
    ///
    /// `authorizationDenied` folds into `.authCancelled` because from the
    /// user's side both mean "you weren't authenticated, so nothing ran".
    var elevatedOutcome: ElevatedOutcome {
        switch self {
        case .exited(let code): return .exited(code)
        case .authorizationCancelled, .authorizationDenied: return .authCancelled
        case .rejected, .engineUnavailable: return .launchFailed
        }
    }
}

// MARK: - Routing

/// Whether a given elevated operation goes through the helper or the legacy
/// osascript path. Pure → unit-tested, because "when do we use the root
/// daemon" should not be an emergent property of five call sites.
enum PrivilegeRoute: Equatable {
    /// Use the privileged helper for this typed operation.
    case helper(HelperOperation)
    /// Use the existing osascript elevation, unchanged.
    case osascript

    /// The routing rule. The helper is used only when ALL of these hold:
    ///   * the argv maps onto one of the three typed operations;
    ///   * the daemon is registered and enabled;
    ///   * its build matches this app's.
    ///
    /// Any doubt routes to osascript. That is a genuine fallback rather than a
    /// silent downgrade: the osascript path is the elevation Burrow has always
    /// shipped, it still prompts for an administrator, and it still runs the
    /// same trusted engine. What the user loses is Touch ID and safe
    /// cancellation, not the authentication itself.
    static func decide(arguments: [String],
                       registration: HelperRegistrationStatus,
                       skew: HelperVersionSkew.Skew) -> PrivilegeRoute {
        guard let operation = HelperOperation(engineArguments: arguments) else { return .osascript }
        guard registration == .enabled else { return .osascript }
        guard skew == .matched else { return .osascript }
        return .helper(operation)
    }
}

/// The daemon's registration state, mirrored off `SMAppService.Status` so call
/// sites and tests don't need ServiceManagement.
enum HelperRegistrationStatus: Equatable, Sendable {
    /// Registered and allowed to run.
    case enabled
    /// Never registered on this machine, or the registration is gone.
    case notRegistered
    /// Registered, but waiting on the user in Login Items & Extensions —
    /// either the initial approval or a switch they turned back off.
    case requiresApproval

    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notFound, .notRegistered: self = .notRegistered
        @unknown default:
            // A status this build has never heard of is not a licence to run
            // privileged work. Fail closed to the state that routes elsewhere.
            self = .notRegistered
        }
    }

    /// Whether the user still has a decision to make. Drives the Settings
    /// copy — "approve this in Login Items" is actionable, "not registered"
    /// is just the default state.
    var needsUserAction: Bool { self == .requiresApproval }
}

// MARK: - Client

/// Talks to the root daemon. One operation per call, one authentication per
/// operation.
final class PrivilegedHelperClient: @unchecked Sendable {

    static let shared = PrivilegedHelperClient()

    /// This app's build, the value the daemon compares against its own.
    static var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }

    private let service = SMAppService.daemon(plistName: HelperNames.daemonPlist)
    private let lock = NSLock()
    private var cachedSkew: HelperVersionSkew.Skew?

    // MARK: Registration

    var registrationStatus: HelperRegistrationStatus {
        HelperRegistrationStatus(service.status)
    }

    /// Register the daemon. This raises macOS's own one-time administrator
    /// approval for installing a launch daemon.
    ///
    /// Registering does NOT authorize any operation — that was an explicit
    /// product decision, and it is enforced on the daemon side by a right
    /// defined with `timeout: 0` and `shared: false`. Installing the helper
    /// buys convenience, never standing privilege.
    func register() throws {
        try service.register()
        lock.lock(); cachedSkew = nil; lock.unlock()
    }

    /// Remove the daemon. Used by Settings, and by the uninstall path so
    /// Burrow never leaves a root daemon behind.
    func unregister() throws {
        try service.unregister()
        lock.lock(); cachedSkew = nil; lock.unlock()
    }

    // MARK: Connection

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: HelperNames.machService,
                                         options: .privileged)
        connection.remoteObjectInterface = HelperInterface.daemon()
        return connection
    }

    /// The installed helper's build, or "" if it can't be reached. Blocking —
    /// call off the main thread.
    func helperBuild(timeout: TimeInterval = 5) -> String {
        let connection = makeConnection()
        connection.resume()
        defer { connection.invalidate() }

        let semaphore = DispatchSemaphore(value: 0)
        var result = ""
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in semaphore.signal() }
        (proxy as? BurrowHelperProtocol)?.helperBuild { build in
            result = build
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        return result
    }

    /// Whether the installed helper matches this app. Cached per process
    /// because it only changes across an update or a re-registration, both of
    /// which clear it.
    func versionSkew() -> HelperVersionSkew.Skew {
        lock.lock()
        if let cachedSkew { lock.unlock(); return cachedSkew }
        lock.unlock()

        let skew = HelperVersionSkew.evaluate(appBuild: Self.appBuild, helperBuild: helperBuild())
        lock.lock(); cachedSkew = skew; lock.unlock()
        return skew
    }

    /// The route for an elevated invocation described the way `OperationFlow`
    /// already describes it.
    func route(for arguments: [String]) -> PrivilegeRoute {
        let status = registrationStatus
        // Don't pay for an XPC round trip to learn the version when the daemon
        // isn't usable anyway.
        guard status == .enabled else {
            return PrivilegeRoute.decide(arguments: arguments, registration: status, skew: .mismatched)
        }
        return PrivilegeRoute.decide(arguments: arguments, registration: status, skew: versionSkew())
    }

    // MARK: Execution

    /// Run one typed operation as root, streaming output lines to `onLine`.
    ///
    /// Blocking — call off the main thread. It blocks for as long as the user
    /// takes to authenticate plus as long as the operation runs, because the
    /// authentication prompt is raised by the DAEMON during this call.
    func run(operation: HelperOperation,
             onLine: @escaping (String) -> Void) -> ElevatedOutcome {
        // A fresh, unauthenticated reference per operation. Creating it shows
        // no UI; the daemon is what demands the right, and that is what makes
        // the prompt appear.
        guard let authorization = HelperAuthorization.makeExternalForm() else {
            return .launchFailed
        }

        let request = HelperRequest(operation: operation,
                                    operationID: UUID().uuidString,
                                    clientBuild: Self.appBuild)
        guard let payload = try? JSONEncoder().encode(request) else { return .launchFailed }

        let connection = makeConnection()
        connection.exportedInterface = HelperInterface.client()
        let sink = HelperOutputSink(onLine: onLine)
        connection.exportedObject = sink
        connection.resume()
        defer { connection.invalidate() }

        let semaphore = DispatchSemaphore(value: 0)
        var outcome: ElevatedOutcome = .launchFailed

        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            // A connection error here means the daemon refused us, died, or
            // was never reachable. Nothing ran, so this is a launch failure —
            // never a silent success.
            outcome = .launchFailed
            semaphore.signal()
        }
        (proxy as? BurrowHelperProtocol)?.execute(requestData: payload,
                                                  authorization: authorization) { data in
            if let response = try? JSONDecoder().decode(HelperResponse.self, from: data) {
                outcome = response.outcome.elevatedOutcome
            }
            semaphore.signal()
        }

        // No timeout: the user may take a long time at the authentication
        // prompt, and a clean or optimize can legitimately run for minutes.
        // Cancellation is explicit (`cancel(operationID:)`), which is exactly
        // what the osascript path could never offer.
        semaphore.wait()
        return outcome
    }
}

// MARK: - The streaming seam

/// Routes elevated streaming runs to the helper when it is usable, and to the
/// existing osascript port otherwise.
///
/// This wraps `SystemProcessPort` rather than editing it, so the osascript
/// path — the elevation Burrow has shipped for every release so far — keeps
/// its exact behaviour, tests, and error taxonomy. A helper route is an
/// alternative, never a rewrite of the fallback.
struct HelperAwareProcessPort: ProcessPort {
    var fallback: SystemProcessPort = SystemProcessPort()
    var client: PrivilegedHelperClient = .shared

    func events(_ spec: ProcessSpec) -> AsyncStream<ProcessEvent> {
        // Un-elevated runs never involve the helper. Cheap check first, so the
        // common path costs nothing.
        guard spec.elevated else { return fallback.events(spec) }

        return AsyncStream { continuation in
            // Routing asks the daemon for its version, and executing blocks
            // for as long as the user takes to authenticate. Neither may
            // happen on the main thread.
            DispatchQueue.global(qos: .userInitiated).async {
                switch client.route(for: spec.arguments) {
                case .helper(let operation):
                    let outcome = client.run(operation: operation) { line in
                        continuation.yield(.line(line))
                    }
                    switch outcome {
                    case .exited(let code): continuation.yield(.exited(code))
                    case .authCancelled: continuation.yield(.authCancelled)
                    case .launchFailed: continuation.yield(.exited(127))
                    }
                    continuation.finish()

                case .osascript:
                    // Forward the legacy stream verbatim, including its
                    // cancellation behaviour.
                    let task = Task {
                        for await event in fallback.events(spec) { continuation.yield(event) }
                        continuation.finish()
                    }
                    continuation.onTermination = { @Sendable _ in task.cancel() }
                }
            }
        }
    }
}

// MARK: - Output sink

/// Receives streamed lines from the daemon. Strips ANSI on the CLIENT side, so
/// the root process carries no text-processing code it doesn't need.
private final class HelperOutputSink: NSObject, BurrowHelperClientProtocol {
    private let onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) {
        self.onLine = onLine
        super.init()
    }

    func helperDidEmit(line: String, operationID: String) {
        onLine(Ansi.strip(line))
    }
}
