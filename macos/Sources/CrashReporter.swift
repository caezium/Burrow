//
//  CrashReporter.swift
//  Burrow
//
//  Crash + error reporting, via Sentry. For a tool that runs destructive
//  cleans/purges, "did it crash on someone" is at least as valuable as usage
//  analytics — a crash mid-delete is the thing we most need to hear about.
//
//  Same privacy posture as `Telemetry`:
//    * Gated on the shared `Store.telemetryEnabled` opt-in (the one Settings
//      switch covers both PostHog and Sentry).
//    * Inert without a DSN. The Sentry DSN is injected at release time
//      (Info.plist `SentryDSN`); dev builds ship it empty → no reporting.
//    * No PII: `sendDefaultPii` off, no screenshots, no network/file tracing,
//      and only fixed-name manual breadcrumbs/logs with sanitized attributes.
//
//  Runtime toggle is start/stop: Sentry has no live "mute" flag, so opting out
//  calls `SentrySDK.close()` and opting back in re-`start`s it.
//

import Foundation
import AppKit
import Sentry

struct AppHangRateLimiter {
    let minimumInterval: TimeInterval
    private(set) var lastKeptAtByGroup: [String: Date] = [:]

    init(minimumInterval: TimeInterval = 60) {
        self.minimumInterval = minimumInterval
    }

    mutating func shouldKeep(group: String, at date: Date = Date()) -> Bool {
        // Keep only fingerprints active inside the current rate-limit window,
        // so a long-running process cannot grow this map without bound.
        lastKeptAtByGroup = lastKeptAtByGroup.filter {
            let elapsed = date.timeIntervalSince($0.value)
            return elapsed >= 0 && elapsed < minimumInterval
        }
        if let lastKeptAt = lastKeptAtByGroup[group],
           date.timeIntervalSince(lastKeptAt) < minimumInterval {
            return false
        }
        lastKeptAtByGroup[group] = date
        return true
    }
}

enum StatusItemDiagnosticState: String {
    case notRequested = "not_requested"
    case compatibilityMode = "compatibility_mode"
    case scheduled
    case stabilizing
    case stable
    case disabled
}

enum LaunchTraceEndReason: Equatable {
    case completed
    case telemetryDisabled

    var shouldFinish: Bool { self == .completed }
}

final class DiagnosticSpan {
    private let span: any Span
    private let lock = NSLock()
    private var didFinish = false

    init(_ span: any Span) {
        self.span = span
    }

    func finish() {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        lock.unlock()
        span.finish()
    }
}

enum CrashReporter {

    /// Whether the SDK is currently running (started and not closed).
    private static var running = false
    private static let stateLock = NSLock()
    private static var appHangLimiter = AppHangRateLimiter()
    private static var launchPhase = LaunchPhase.launchStarted.rawValue
    private static var launchTransaction: (any Span)?

    /// Bounded updater and launch fields that may leave the Mac in a Sentry
    /// diagnostic context. Free-form descriptions and URLs remain excluded.
    static let diagnosticContextFields: Set<String> = [
        "attempt", "elapsed_bucket", "error_code", "error_domain",
        "failure_category", "phase", "reason", "recovery", "source", "state",
        "status", "target_version", "underlying_error_code",
        "underlying_error_domain", "update_found", "update_source",
    ]

    /// Run a synchronous, USER-PACED block (a modal confirm, an auth prompt)
    /// without Sentry's app-hang monitor flagging the expected main-thread
    /// block as an ANR. A person reading an NSAlert for >2 s is not a defect —
    /// the genuine render-path hangs we care about don't go through here. No-op
    /// when the SDK isn't running (dev builds / opted out).
    @discardableResult
    static func withoutAppHangTracking<T>(_ body: () -> T) -> T {
        guard running else { return body() }
        SentrySDK.pauseAppHangTracking()
        defer { SentrySDK.resumeAppHangTracking() }
        return body()
    }

    private static var dsn: String {
        (Bundle.main.infoDictionary?["SentryDSN"] as? String) ?? ""
    }

    /// Start at launch if opted in and a DSN is configured. No-op otherwise.
    static func start(enabled: Bool) {
        guard enabled, !dsn.isEmpty, !running else { return }
        startSDK()
    }

    /// Follow the shared opt-in switch: start when enabled, close when not.
    static func setEnabled(_ enabled: Bool) {
        guard !dsn.isEmpty else { return }
        if enabled, !running {
            startSDK()
        } else if !enabled, running {
            endLaunchTrace(reason: .telemetryDisabled)
            SentrySDK.close()
            running = false
        }
    }

    private static func startSDK() {
        let dsn = self.dsn
        let info = Bundle.main.infoDictionary
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.caezium.Burrow"
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "unknown"
        let build = (info?["CFBundleVersion"] as? String) ?? "unknown"
        let release = "\(bundleID)@\(version)+\(build)"
        let profilingPathIsSafe = isProfilingPathSafe(Bundle.main.bundleURL)
        stateLock.lock()
        appHangLimiter = AppHangRateLimiter()
        let phase = launchPhase
        stateLock.unlock()
        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = "production"
            options.releaseName = release
            // Sentry 9.24+ can inspect stack-adjacent memory after a crash and
            // promote discovered Objective-C/C strings into the event. Keep
            // this explicit even though the SDK now defaults it off: those
            // bytes can contain file contents, credentials, or user input and
            // never belong in Burrow diagnostics.
            options.enableMemoryIntrospection = false
            // Custom, fixed-name startup/update spans only. Automatic network,
            // file, Core Data, and UI tracing remains disabled so URLs and
            // local paths cannot enter performance events.
            options.tracesSampleRate = 0.10
            options.enableAutoPerformanceTracing = false
            options.sendDefaultPii = false   // never attach IP/user identifiers
            options.enableAutoSessionTracking = true
            options.enableLogs = true
            options.maxBreadcrumbs = 50
            if profilingPathIsSafe {
                options.configureProfiling = { profile in
                    profile.lifecycle = .trace
                    // Trace profiling is a two-stage sample: 10% of launches
                    // trace, then 10% of those traces profile, for ~1% overall.
                    profile.sessionSampleRate = 0.10
                    // Pre-main profiles can begin before Burrow can verify its
                    // current bundle path, so they stay disabled permanently.
                    profile.profileAppStarts = false
                }
            }
            // Turn off auto-instrumentation that could
            // attach request URLs, network activity, or UI breadcrumbs to an
            // event — upholds the "no PII, no URLs" promise in TELEMETRY.md.
            options.enableNetworkTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableCaptureFailedRequests = false
            options.enableAutoBreadcrumbTracking = false
            options.enableFileIOTracing = false
            options.enableDataSwizzling = false
            options.enableFileManagerSwizzling = false
            options.enableCoreDataTracing = false
            options.enableMetrics = false
            options.beforeCaptureScreenshot = { _ in false }
            options.beforeCaptureViewHierarchy = { _ in false }
            options.beforeSendLog = { log in
                isSafeLogBody(log.body) ? log : nil
            }
            // App-hang (ANR) detection stays ON (SDK default). For a
            // disk-I/O- and render-heavy app a ≥2 s main-thread freeze is a
            // real defect, not noise — it's how we caught a genuine SwiftUI
            // layout hang in the Analyze treemap (Sentry BURROW-1/2). The
            // earlier worry was that modal confirms (NSAlert.runModal, Touch
            // ID) would trip false positives, but the reported hangs were all
            // in the render path, not modals. If a specific modal ever does
            // trip one, wrap that call site in
            // SentrySDK.pauseAppHangTracking()/resumeAppHangTracking() rather
            // than disabling detection app-wide.
            // Keep the outbound event deliberately smaller than Sentry's
            // defaults. Stack symbols, debug IDs, coarse tags, and Burrow's
            // fixed contexts are sufficient to diagnose a crash or hang;
            // exception prose, source snippets, requests, arbitrary extras,
            // and path-bearing fields are removed before transmission.
            options.beforeSend = { event in
                if isAppHang(event) {
                    let phase = currentLaunchPhase()
                    let frame = topBurrowFrame(event) ?? "unknown"
                    let group = "\(phase)|\(frame)"
                    event.fingerprint = ["burrow-app-hang", phase, frame]
                    var tags = event.tags ?? [:]
                    tags["launch_phase"] = phase
                    tags["memory_pressure"] = memoryPressureBucket(event)
                    event.tags = tags
                    // Retain the first occurrence of every distinct phase/frame
                    // group, then limit only identical repeats to one per minute.
                    guard shouldKeepAppHang(group: group) else { return nil }
                }
                scrubForTransport(event)
                return event
            }
        }
        running = true

        let environment = RuntimeEnvironment.current
        SentrySDK.configureScope { scope in
            scope.setTag(value: environment.osBuild, key: "os_build")
            scope.setTag(value: environment.architecture, key: "architecture")
            scope.setTag(value: environment.isPrereleaseOS ? "true" : "false", key: "os_prerelease")
            scope.setTag(value: phase, key: "launch_phase")
            scope.setAttribute(value: environment.osBuild, key: "burrow.os_build")
            scope.setAttribute(value: environment.appVersion, key: "burrow.app_version")
            scope.setAttribute(value: environment.appBuild, key: "burrow.app_build")
            scope.setAttribute(value: phase, key: "burrow.launch_phase")
            scope.setContext(value: [
                "app_version": environment.appVersion,
                "app_build": environment.appBuild,
                "os_version": environment.osVersion,
                "os_build": environment.osBuild,
                "architecture": environment.architecture,
            ], key: "burrow_runtime")
        }
    }

    // MARK: - Privacy-safe diagnostics

    static func setLaunchPhase(_ phase: LaunchPhase) {
        stateLock.lock()
        launchPhase = phase.rawValue
        stateLock.unlock()
        if running {
            SentrySDK.configureScope { scope in
                scope.setTag(value: phase.rawValue, key: "launch_phase")
                scope.setAttribute(value: phase.rawValue, key: "burrow.launch_phase")
            }
        }
        breadcrumb("launch_phase", category: "launch", data: ["phase": phase.rawValue])
    }

    static func setStatusItemState(_ state: StatusItemDiagnosticState) {
        if running {
            SentrySDK.configureScope { scope in
                scope.setTag(value: state.rawValue, key: "status_item_state")
                scope.setAttribute(value: state.rawValue, key: "burrow.status_item_state")
            }
        }
        breadcrumb("status_item_state", category: "launch", data: ["state": state.rawValue])
    }

    static func startLaunchTrace() {
        guard running else { return }
        stateLock.lock()
        guard launchTransaction == nil else {
            stateLock.unlock()
            return
        }
        launchTransaction = SentrySDK.startTransaction(
            name: "Burrow launch",
            operation: "app.launch",
            bindToScope: true
        )
        stateLock.unlock()
    }

    static func startLaunchSpan(_ identifier: String) -> DiagnosticSpan? {
        guard running, DiagnosticPrivacy.isSafeIdentifier(identifier) else { return nil }
        stateLock.lock()
        let transaction = launchTransaction
        stateLock.unlock()
        guard let transaction else { return nil }
        return DiagnosticSpan(transaction.startChild(operation: "app.launch.\(identifier)"))
    }

    static func finishLaunchTrace() {
        endLaunchTrace(reason: .completed)
    }

    private static func endLaunchTrace(reason: LaunchTraceEndReason) {
        stateLock.lock()
        let transaction = launchTransaction
        launchTransaction = nil
        stateLock.unlock()
        if reason.shouldFinish {
            transaction?.finish()
        } else {
            // Unbind before closing the SDK. Finishing a sampled launch trace
            // here would enqueue it at the exact moment the user opts out.
            SentrySDK.configureScope { $0.span = nil }
        }
    }

    static func breadcrumb(
        _ identifier: String,
        category: String,
        data: [String: Any] = [:],
        level: SentryLevel = .info
    ) {
        guard running,
              DiagnosticPrivacy.isSafeIdentifier(identifier),
              DiagnosticPrivacy.isSafeIdentifier(category) else { return }
        let crumb = Breadcrumb(level: level, category: "burrow.\(category)")
        crumb.message = identifier
        crumb.data = DiagnosticPrivacy.sanitize(data)
        SentrySDK.addBreadcrumb(crumb)
    }

    static func logWarning(_ identifier: String, data: [String: Any] = [:]) {
        guard running, DiagnosticPrivacy.isSafeIdentifier(identifier) else { return }
        SentrySDK.logger.warn("burrow.\(identifier)", attributes: DiagnosticPrivacy.sanitize(data))
    }

    static func logError(_ identifier: String, data: [String: Any] = [:]) {
        guard running, DiagnosticPrivacy.isSafeIdentifier(identifier) else { return }
        SentrySDK.logger.error("burrow.\(identifier)", attributes: DiagnosticPrivacy.sanitize(data))
    }

    static func captureDiagnostic(
        _ identifier: String,
        error: Error? = nil,
        data: [String: Any] = [:]
    ) {
        guard running, DiagnosticPrivacy.isSafeIdentifier(identifier) else { return }
        let nsError = error as NSError?
        var context = DiagnosticPrivacy.sanitize(data)
        if let nsError {
            context["error_domain"] = DiagnosticPrivacy.redact(nsError.domain)
            context["error_code"] = nsError.code
        }
        let safeError = NSError(
            domain: "dev.caezium.Burrow.diagnostic",
            code: nsError?.code ?? 0,
            userInfo: [NSLocalizedDescriptionKey: identifier]
        )
        SentrySDK.capture(error: safeError) { scope in
            scope.setTag(value: identifier, key: "diagnostic")
            scope.setContext(value: context, key: "diagnostic")
        }
    }

    /// True for Sentry app-hang (ANR) events. The Cocoa SDK tags them with an
    /// exception mechanism whose `type` begins with "AppHang" (V1 "AppHang",
    /// V2 "AppHangFullyBlocked"/"AppHangNonFullyBlocked") and an exception
    /// `type` of "App Hanging".
    private static func isAppHang(_ event: Event) -> Bool {
        (event.exceptions ?? []).contains { ex in
            (ex.mechanism?.type.hasPrefix("AppHang") ?? false)
                || ex.type == "App Hanging"
        }
    }

    private static func shouldKeepAppHang(group: String, at date: Date = Date()) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return appHangLimiter.shouldKeep(group: group, at: date)
    }

    private static func currentLaunchPhase() -> String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return launchPhase
    }

    private static func topBurrowFrame(_ event: Event) -> String? {
        let stacktraces = (event.exceptions?.compactMap { $0.stacktrace } ?? [])
            + (event.threads?.compactMap { $0.stacktrace } ?? [])
        let frames = stacktraces.flatMap(\.frames).reversed()
        guard let rawFunction = frames.first(where: { frame in
            frame.inApp?.boolValue == true
                || frame.module?.localizedCaseInsensitiveContains("Burrow") == true
                || frame.package?.localizedCaseInsensitiveContains("Burrow.app") == true
        })?.function,
              let function = DiagnosticPrivacy.safeDiagnosticLabel(rawFunction)
        else { return nil }
        let allowed = function.unicodeScalars.filter {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.$:<>-")).contains($0)
        }
        let sanitized = String(String.UnicodeScalarView(allowed)).prefix(120).description
        return sanitized.isEmpty ? nil : sanitized
    }

    private static func memoryPressureBucket(_ event: Event) -> String {
        guard let free = (event.context?["device"]?["free_memory"] as? NSNumber)?.int64Value
        else { return "unknown" }
        switch free {
        case ..<(150 * 1024 * 1024): return "critical"
        case ..<(500 * 1024 * 1024): return "low"
        default: return "normal"
        }
    }

    private static func isSafeLogBody(_ value: String) -> Bool {
        guard value.hasPrefix("burrow.") else { return false }
        return DiagnosticPrivacy.isSafeIdentifier(String(value.dropFirst("burrow.".count)))
    }

    /// Fail closed on free-form Sentry fields. Sentry still receives debug IDs,
    /// module names, symbols, addresses, and line numbers, which are enough to
    /// symbolicate Burrow without transmitting exception prose, source text,
    /// request data, or where its bundle lived on the user's Mac.
    static func scrubForTransport(_ event: Event) {
        event.message = nil
        event.error = nil
        event.request = nil
        event.user = nil
        event.extra = nil
        event.modules = nil
        event.serverName = nil
        event.logger = nil
        event.transaction = nil
        if let fingerprint = event.fingerprint,
           fingerprint.count == 3,
           fingerprint.first == "burrow-app-hang",
           let phase = DiagnosticPrivacy.safeDiagnosticLabel(fingerprint[1]),
           let frame = DiagnosticPrivacy.safeDiagnosticLabel(fingerprint[2]),
           phase.utf8.count <= 80,
           frame.utf8.count <= 120 {
            event.fingerprint = ["burrow-app-hang", phase, frame]
        } else {
            event.fingerprint = nil
        }

        let allowedTagKeys: Set<String> = [
            "architecture", "diagnostic", "launch_phase", "memory_pressure",
            "os_build", "os_prerelease", "status_item_state",
        ]
        event.tags = event.tags?.filter { allowedTagKeys.contains($0.key) }

        let allowedContextFields: [String: Set<String>] = [
            "burrow_runtime": [
                "app_build", "app_version", "architecture", "os_build", "os_version",
            ],
            "diagnostic": diagnosticContextFields,
            // Preserve only the identifiers needed to connect a captured
            // error to Burrow's fixed-name custom launch trace.
            "trace": [
                "op", "origin", "parent_span_id", "sampled", "span_id", "status", "trace_id",
            ],
        ]
        var safeContexts: [String: [String: Any]] = [:]
        for (name, fields) in allowedContextFields {
            guard let source = event.context?[name] else { continue }
            let selected = source.filter { fields.contains($0.key) }
            let sanitized = DiagnosticPrivacy.sanitize(selected)
            if !sanitized.isEmpty {
                safeContexts[name] = sanitized
            }
        }
        event.context = safeContexts

        event.exceptions?.forEach { exception in
            // Exception values are free-form (NSError descriptions, assertion
            // text, and uncaught exception reasons). The exception type and
            // symbolicated stack retain the actionable diagnosis.
            exception.value = "<redacted>"
            exception.type = DiagnosticPrivacy.safeDiagnosticLabel(exception.type)
            exception.module = DiagnosticPrivacy.safeDiagnosticLabel(exception.module)
            exception.mechanism?.desc = nil
            exception.mechanism?.helpLink = nil
            exception.mechanism?.meta = nil
            if let mechanism = exception.mechanism {
                mechanism.type = DiagnosticPrivacy.safeDiagnosticLabel(mechanism.type) ?? "unknown"
            }
            if let data = exception.mechanism?.data {
                exception.mechanism?.data = DiagnosticPrivacy.sanitize(data)
            }
        }

        event.breadcrumbs = event.breadcrumbs?.filter { breadcrumb in
            guard breadcrumb.category.hasPrefix("burrow.") else { return false }
            let category = String(breadcrumb.category.dropFirst("burrow.".count))
            guard DiagnosticPrivacy.isSafeIdentifier(category),
                  let message = breadcrumb.message,
                  DiagnosticPrivacy.isSafeIdentifier(message) else { return false }
            breadcrumb.type = nil
            breadcrumb.origin = nil
            breadcrumb.data = DiagnosticPrivacy.sanitize(breadcrumb.data ?? [:])
            return true
        }

        event.debugMeta?.forEach { meta in
            meta.codeFile = nil
            meta.debugID = DiagnosticPrivacy.safeDebugID(meta.debugID)
            meta.type = ["apple", "macho"].contains(meta.type ?? "") ? meta.type : nil
            meta.imageAddress = DiagnosticPrivacy.safeHexAddress(meta.imageAddress)
            meta.imageVmAddress = DiagnosticPrivacy.safeHexAddress(meta.imageVmAddress)
        }
        let stacktraces = (event.exceptions?.compactMap { $0.stacktrace } ?? [])
            + (event.threads?.compactMap { $0.stacktrace } ?? [])
            + [event.stacktrace].compactMap { $0 }
        for st in stacktraces {
            // Raw register contents are unnecessary once frame instruction and
            // image addresses are retained, and can point into user memory.
            st.registers = [:]
            for frame in st.frames {
                frame.package = nil
                frame.fileName = nil
                frame.function = DiagnosticPrivacy.safeDiagnosticLabel(frame.function)
                frame.module = DiagnosticPrivacy.safeDiagnosticLabel(frame.module)
                frame.platform = ["cocoa", "native"].contains(frame.platform ?? "")
                    ? frame.platform : nil
                frame.symbolAddress = DiagnosticPrivacy.safeHexAddress(frame.symbolAddress)
                frame.imageAddress = DiagnosticPrivacy.safeHexAddress(frame.imageAddress)
                frame.instructionAddress = DiagnosticPrivacy.safeHexAddress(frame.instructionAddress)
                frame.contextLine = nil
                frame.preContext = nil
                frame.postContext = nil
                frame.vars = nil
            }
        }
        event.threads?.forEach { $0.name = nil }
    }

    /// Profiles carry their own binary-image envelope, which bypasses
    /// `beforeSend`. Restrict post-SDK profiling to canonical app installs so
    /// those image paths cannot reveal a home, Downloads, or mounted-volume
    /// location. Pre-main profiling remains disabled separately above.
    static func isProfilingPathSafe(_ bundleURL: URL) -> Bool {
        let path = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        return path == "/Applications" || path.hasPrefix("/Applications/")
    }

}

extension NSAlert {
    /// `runModal()` that pauses Sentry app-hang tracking for the duration —
    /// a user deciding at a confirm dialog blocks the main thread by design
    /// and must not be reported as an ANR (the cause of the modal-class
    /// "App Hanging" Sentry issues, e.g. the Touch ID toggle confirm).
    @discardableResult
    func runModalQuiet() -> NSApplication.ModalResponse {
        CrashReporter.withoutAppHangTracking { runModal() }
    }
}
