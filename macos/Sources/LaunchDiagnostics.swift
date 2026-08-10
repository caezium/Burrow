//
//  LaunchDiagnostics.swift
//  Burrow
//
//  Small, durable launch markers for failures that can outlive Burrow itself.
//  The journal stores only app/OS versions and coarse phase names; it never
//  stores paths, filenames, window contents, hardware ids, or account data.
//

import Foundation
import Darwin

struct RuntimeEnvironment: Equatable, Codable {
    let osVersion: String
    let osMajorVersion: Int
    let osBuild: String
    let architecture: String
    let appVersion: String
    let appBuild: String

    var isPrereleaseOS: Bool {
        guard osBuild != "unknown", let last = osBuild.last else { return false }
        return last.isLetter && last.isLowercase
    }

    static var current: RuntimeEnvironment {
        let info = Foundation.ProcessInfo.processInfo
        let version = info.operatingSystemVersion
        let bundleInfo = Bundle.main.infoDictionary
        return RuntimeEnvironment(
            osVersion: "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            osMajorVersion: version.majorVersion,
            osBuild: sysctlString("kern.osversion") ?? "unknown",
            architecture: sysctlString("hw.machine") ?? "unknown",
            appVersion: (bundleInfo?["CFBundleShortVersionString"] as? String) ?? "unknown",
            appBuild: (bundleInfo?["CFBundleVersion"] as? String) ?? "unknown"
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }
}

enum LaunchPhase: String, Codable, Equatable {
    case launchStarted = "launch_started"
    case telemetryStarted = "telemetry_started"
    case engineProbeStarted = "engine_probe_started"
    case engineProbeFinished = "engine_probe_finished"
    case installWindowReady = "install_window_ready"
    case databaseOpening = "database_opening"
    case databaseReady = "database_ready"
    case servicesStarted = "services_started"
    case statusItemCreating = "status_item_creating"
    case statusItemReady = "status_item_ready"
    case updaterScheduled = "updater_scheduled"
    case updaterReady = "updater_ready"
    case appReady = "app_ready"
    case terminatedNormally = "terminated_normally"
}

struct LaunchRecord: Codable, Equatable {
    let runID: String
    let environment: RuntimeEnvironment
    var phase: LaunchPhase
    let startedAt: Date
    var updatedAt: Date
    var statusItemUnsafeOSBuild: String? = nil
    var statusItemAttempted: Bool? = nil
    var statusItemStable: Bool? = nil
    /// Consecutive launches that ended without the status item proving itself.
    ///
    /// The guard used to act on the first one, which made it fire on anything
    /// that kills the app in its first 30 seconds — a force quit, an unrelated
    /// crash, a jetsam kill, or Launch at Login followed by a restart. For a
    /// menu-bar app that means losing the primary surface to an unrelated
    /// event, and the mark then persisted until the user updated macOS.
    ///
    /// A real WindowServer freeze reproduces on every launch (it did, on two
    /// Macs), so requiring two in a row still catches it on the second run
    /// while a one-off never pauses anything.
    var statusItemFailureStreak: Int? = nil
    var automaticUpdaterUnsafeEnvironment: String? = nil
    var automaticUpdaterAttempted: Bool? = nil
    var automaticUpdaterStable: Bool? = nil
}

final class LaunchJournal {
    static let live = LaunchJournal(fileURL: defaultFileURL)

    private let fileURL: URL
    private let now: () -> Date
    private let lock = NSLock()
    private var current: LaunchRecord?

    init(fileURL: URL, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
    }

    /// Starts a new durable record and returns the prior run only when it did
    /// not reach normal termination. A power loss can create the same signal,
    /// so callers treat it as a coarse diagnostic rather than proof of a crash.
    /// Consecutive suspicious launches required before the status item is
    /// paused. Two, because a genuine WindowServer freeze reproduces every
    /// time while an unrelated kill does not.
    static let statusItemFailureThreshold = 2

    @discardableResult
    func begin(environment: RuntimeEnvironment) -> LaunchRecord? {
        lock.lock()
        defer { lock.unlock() }

        let previous = readRecord()
        let timestamp = now()

        // Count consecutive launches that ended without the item proving
        // itself, and only treat the build as unsafe once there are two. A
        // launch that reached stable clears the count outright — that is
        // positive proof the item works here, and without it the mark was
        // carried forward forever and only expired on a macOS update.
        let streak: Int
        if Self.hasUnstableStatusItem(previous) {
            streak = (previous?.statusItemFailureStreak ?? 0) + 1
        } else if previous?.statusItemStable == true {
            streak = 0
        } else {
            streak = previous?.statusItemFailureStreak ?? 0
        }

        let unsafeBuild: String?
        if streak >= Self.statusItemFailureThreshold {
            unsafeBuild = previous?.environment.osBuild
        } else if streak == 0 {
            unsafeBuild = nil
        } else {
            unsafeBuild = previous?.statusItemUnsafeOSBuild
        }
        let unsafeUpdaterEnvironment: String?
        if Self.hasUnstableAutomaticUpdater(previous), let previous {
            unsafeUpdaterEnvironment = Self.updaterEnvironmentKey(previous.environment)
        } else {
            unsafeUpdaterEnvironment = previous?.automaticUpdaterUnsafeEnvironment
        }
        let currentUpdaterEnvironment = Self.updaterEnvironmentKey(environment)
        let next = LaunchRecord(
            runID: UUID().uuidString,
            environment: environment,
            phase: .launchStarted,
            startedAt: timestamp,
            updatedAt: timestamp,
            statusItemUnsafeOSBuild: unsafeBuild == environment.osBuild ? unsafeBuild : nil,
            statusItemAttempted: false,
            statusItemStable: nil,
            // The streak only means anything on the build that produced it.
            statusItemFailureStreak: previous?.environment.osBuild == environment.osBuild ? streak : 0,
            automaticUpdaterUnsafeEnvironment: unsafeUpdaterEnvironment == currentUpdaterEnvironment
                ? unsafeUpdaterEnvironment
                : nil,
            automaticUpdaterAttempted: false,
            automaticUpdaterStable: nil
        )
        current = next
        persist(next)
        guard previous?.phase != .terminatedNormally else { return nil }
        return previous
    }

    /// Writes the next coarse launch phase with an atomic replace. The marker
    /// is intentionally persisted even when telemetry is disabled; transmission
    /// remains gated by the existing opt-out and the local record has no PII.
    func mark(_ phase: LaunchPhase) {
        lock.lock()
        defer { lock.unlock() }
        guard var record = current else { return }
        record.phase = phase
        if phase == .statusItemCreating {
            record.statusItemAttempted = true
            record.statusItemStable = false
        }
        if phase == .updaterScheduled {
            record.automaticUpdaterAttempted = true
            record.automaticUpdaterStable = false
        }
        record.updatedAt = now()
        current = record
        persist(record)
    }

    /// A successfully constructed NSStatusItem is only considered safe after
    /// the main run loop has remained responsive through the startup window.
    /// This separate bit survives later phase updates such as `app_ready`.
    func markStatusItemStable() {
        lock.lock()
        defer { lock.unlock() }
        guard var record = current, record.statusItemAttempted == true else { return }
        record.statusItemStable = true
        record.updatedAt = now()
        current = record
        persist(record)
    }

    /// Clears an in-progress attempt when the user intentionally removes the
    /// menu-bar item. A later abnormal quit must not misclassify that explicit
    /// setting change as an AppKit startup failure.
    func markStatusItemDisabled() {
        lock.lock()
        defer { lock.unlock() }
        guard var record = current else { return }
        record.statusItemAttempted = false
        record.statusItemStable = nil
        record.updatedAt = now()
        current = record
        persist(record)
    }

    /// Sparkle starts only after the status item has stabilized. Keep its own
    /// durable bit for another responsive window so a later freeze is never
    /// blamed on AppKit and the same automatic start is not retried forever.
    func markAutomaticUpdaterStable() {
        lock.lock()
        defer { lock.unlock() }
        guard var record = current, record.automaticUpdaterAttempted == true else { return }
        record.automaticUpdaterStable = true
        // A successful explicit retry proves this app/OS pair safe again.
        record.automaticUpdaterUnsafeEnvironment = nil
        record.updatedAt = now()
        current = record
        persist(record)
    }

    func snapshot() -> LaunchRecord? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func lastRecord() -> LaunchRecord? {
        lock.lock()
        defer { lock.unlock() }
        return readRecord()
    }

    private func readRecord() -> LaunchRecord? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(LaunchRecord.self, from: data)
    }

    private func persist(_ record: LaunchRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    private static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
            .appendingPathComponent("Burrow", isDirectory: true)
        return support.appendingPathComponent("launch-state.json")
    }

    /// Did the previous launch end without the status item proving itself?
    ///
    /// Deliberately broad, and it stays broad: the macOS 27 Beta 4 freeze hung
    /// WindowServer *after* the item existed, so the next boot saw
    /// `.statusItemReady` or later rather than `.statusItemCreating`. Narrowing
    /// this to mid-creation would miss the very bug the guard exists for.
    ///
    /// Breadth is fine as a SUSPICION. What was wrong is that one suspicion
    /// was enough to act on — see `statusItemFailureStreak`.
    fileprivate static func hasUnstableStatusItem(_ record: LaunchRecord?) -> Bool {
        guard let record, record.phase != .terminatedNormally else { return false }
        if let attempted = record.statusItemAttempted {
            return attempted && record.statusItemStable != true
        }
        return record.phase == .statusItemCreating
            || record.phase == .statusItemReady
    }

    fileprivate static func hasUnstableAutomaticUpdater(_ record: LaunchRecord?) -> Bool {
        guard let record, record.phase != .terminatedNormally else { return false }
        if let attempted = record.automaticUpdaterAttempted {
            return attempted && record.automaticUpdaterStable != true
        }
        return record.phase == .updaterScheduled
    }

    fileprivate static func updaterEnvironmentKey(_ environment: RuntimeEnvironment) -> String {
        "\(environment.osBuild)|\(environment.appBuild)"
    }
}

enum LaunchRecoveryReason: String, Codable, Equatable {
    case macOS27Beta4 = "macos_27_beta_4"
    case previousStatusItemFailure = "previous_status_item_failure"
    case previousAutomaticUpdaterFailure = "previous_automatic_updater_failure"
}

enum AutomaticUpdateRecovery {
    static func reason(
        environment: RuntimeEnvironment,
        previous: LaunchRecord?
    ) -> LaunchRecoveryReason? {
        let currentEnvironment = LaunchJournal.updaterEnvironmentKey(environment)
        let unstableInCurrentEnvironment = LaunchJournal.hasUnstableAutomaticUpdater(previous)
            && previous.map { LaunchJournal.updaterEnvironmentKey($0.environment) }
                == currentEnvironment
        if unstableInCurrentEnvironment
            || previous?.automaticUpdaterUnsafeEnvironment
                == currentEnvironment {
            return .previousAutomaticUpdaterFailure
        }
        return nil
    }
}

enum LaunchRecovery {
    /// macOS 27 Beta 4 (26A5388g) has a reproduced MenuBarAgent/WindowServer
    /// freeze on two Macs. Skip NSStatusItem on that exact build; later betas
    /// get the normal path unless a prior launch journal proves it unsafe.
    static func reason(environment: RuntimeEnvironment, previous: LaunchRecord?) -> LaunchRecoveryReason? {
        if environment.osMajorVersion == 27, environment.osBuild == "26A5388g" {
            return .macOS27Beta4
        }
        // One bad launch is not enough. `hasUnstableStatusItem` is broad by
        // design — it has to be, to catch a freeze that happens after the item
        // exists — so it needs a second, consecutive occurrence before it
        // costs the user their menu-bar icon.
        let streakWithThisLaunch = (previous?.statusItemFailureStreak ?? 0)
            + (LaunchJournal.hasUnstableStatusItem(previous) ? 1 : 0)
        let repeatedOnCurrentOS = streakWithThisLaunch >= LaunchJournal.statusItemFailureThreshold
            && previous?.environment.osBuild == environment.osBuild
        if repeatedOnCurrentOS
            || previous?.statusItemUnsafeOSBuild == environment.osBuild {
            return .previousStatusItemFailure
        }
        return nil
    }
}

enum StatusItemStartupPolicy {
    /// `applicationDidFinishLaunching` runs before AppKit processes the first
    /// event. Leave that launch turn before asking AppKit/WindowServer to wake
    /// the status-item scene; this reduces coupling menu-bar scene creation to
    /// unrelated launch-time remote views (Sentry BURROW-9V).
    static let initialDelayNanoseconds: UInt64 = 1_000_000_000

    static func shouldScheduleInitialCreation(
        showMenuBarIcon: Bool,
        recoveryReason: LaunchRecoveryReason?
    ) -> Bool {
        showMenuBarIcon && recoveryReason == nil
    }
}

enum DiagnosticPrivacy {
    private static let blockedKeys: Set<String> = [
        "api_key", "token", "authorization", "password", "secret",
        "file_path", "path", "url", "home", "home_dir", "username",
        "user", "email", "clipboard", "file_name", "contents",
        "run_id", "distinct_id", "device_id", "account", "apikey", "argv",
        "argument", "arguments", "command", "command_line", "cookie", "headers",
        "payload", "session"
    ]

    private static let urlPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(?:https?|file)://[^\s]+"#,
        options: []
    )
    private static let emailPattern = try! NSRegularExpression(
        pattern: #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
        options: [.caseInsensitive]
    )
    static func redact(_ value: String) -> String {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let urlRedacted = urlPattern.stringByReplacingMatches(
            in: value,
            options: [],
            range: range,
            withTemplate: "<redacted-url>"
        )
        let emailRange = NSRange(urlRedacted.startIndex..<urlRedacted.endIndex, in: urlRedacted)
        let emailRedacted = emailPattern.stringByReplacingMatches(
            in: urlRedacted,
            options: [],
            range: emailRange,
            withTemplate: "<redacted-email>"
        )
        // After URLs are gone, any remaining slash/backslash is treated as a
        // path signal. Returning one placeholder for the whole value prevents
        // filenames after spaces (for example "My Documents") from leaking.
        if emailRedacted.contains("/") || emailRedacted.contains("\\") {
            return "<redacted-path>"
        }
        return emailRedacted
    }

    static func sanitize(_ properties: [String: Any]) -> [String: Any] {
        var sanitized: [String: Any] = [:]
        for (key, value) in properties {
            let normalizedKey = key.lowercased()
            let hasBlockedSuffix = blockedKeys.contains { normalizedKey.hasSuffix("_\($0)") }
            guard !blockedKeys.contains(normalizedKey), !hasBlockedSuffix else { continue }
            switch value {
            case let value as Bool:
                sanitized[key] = value
            case let value as Int:
                sanitized[key] = value
            case let value as Int64:
                sanitized[key] = value
            case let value as Double where value.isFinite:
                sanitized[key] = value
            case let value as String:
                sanitized[key] = redact(value)
            default:
                continue
            }
        }
        return sanitized
    }

    /// Preserve only bounded symbol/type labels. Path syntax, email/URL
    /// redactions, control characters, and credential-shaped text fail closed.
    static func safeDiagnosticLabel(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 240,
              redact(value) == value else { return nil }
        let lowered = value.lowercased()
        let sensitiveMarkers = [
            "api_key", "apikey", "authorization", "bearer ", "password",
            "secret", "sk-live", "token=", "token:", "x-api-key",
        ]
        guard !sensitiveMarkers.contains(where: lowered.contains) else { return nil }
        // A credential NAME followed by `:` or `=`, however it is spaced or
        // spelled. The literal markers above only catch `token=`/`token:`
        // written tight, so `access_token = abc123` and `api key=abc123` both
        // walked straight through into a diagnostic that gets uploaded.
        guard value.range(
            of: #"(?i)(api[ _-]?key|access[ _-]?token|auth[ _-]?token|refresh[ _-]?token|token|secret|password)\s*[:=]"#,
            options: .regularExpression) == nil else { return nil }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: " _.$:+<>()[]{}?!,@#&'`~-=")
        )
        guard value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return value
    }

    static func safeHexAddress(_ value: String?) -> String? {
        guard let value,
              value.range(of: #"^0x[0-9a-fA-F]{1,16}$"#, options: .regularExpression) != nil
        else { return nil }
        return value
    }

    static func safeDebugID(_ value: String?) -> String? {
        guard let value else { return nil }
        let pattern = #"^(?:[0-9a-fA-F]{32}|[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})$"#
        return value.range(of: pattern, options: .regularExpression) == nil ? nil : value
    }

    static func isSafeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 80 else { return false }
        return value.range(of: #"^[a-z0-9_.-]+$"#, options: .regularExpression) != nil
    }

    static func elapsedBucket(for record: LaunchRecord) -> String {
        switch max(0, record.updatedAt.timeIntervalSince(record.startedAt)) {
        case ..<1: return "under_1s"
        case ..<5: return "1_to_5s"
        case ..<30: return "5_to_30s"
        case ..<120: return "30_to_120s"
        default: return "over_120s"
        }
    }
}

enum LaunchDiagnosticReport {
    static func make(
        reason: LaunchRecoveryReason,
        previous: LaunchRecord?,
        current: RuntimeEnvironment,
        menuBarMode: String
    ) -> String {
        // Redact each value independently. Redacting the final joined report
        // would turn every line into one placeholder when any single field
        // looked like a path, throwing away the safe phase/build evidence the
        // report exists to provide.
        let safe = DiagnosticPrivacy.redact
        var lines = [
            "Burrow launch recovery report",
            "Recovery reason: \(safe(reason.rawValue))",
            "Current app: \(safe(current.appVersion)) (\(safe(current.appBuild)))",
            "Current system: \(safe(current.osVersion)) (\(safe(current.osBuild))), \(safe(current.architecture))",
            "Menu bar mode: \(safe(menuBarMode))"
        ]

        if let previous {
            lines.append(contentsOf: [
                "Previous phase: \(safe(previous.phase.rawValue))",
                "Previous elapsed: \(safe(DiagnosticPrivacy.elapsedBucket(for: previous)))",
                "Previous app: \(safe(previous.environment.appVersion)) (\(safe(previous.environment.appBuild)))",
                "Previous system: \(safe(previous.environment.osVersion)) (\(safe(previous.environment.osBuild))), \(safe(previous.environment.architecture))"
            ])
        }

        return lines.joined(separator: "\n")
    }
}
