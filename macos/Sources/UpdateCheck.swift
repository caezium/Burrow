//
//  UpdateCheck.swift
//  Burrow
//
//  Burrow's own updater is Sparkle's standard signed-update UI. The legacy
//  GitHub/Homebrew banner remains only in 0.10.5 long enough to deliver the
//  first signed release; 0.11+ installs signed ZIPs from the signed appcast.
//

import Foundation
import Sparkle

enum UpdateStartPolicy {
    /// Disabling a delayed automatic check is a persistence-only operation;
    /// enabling it is an explicit request that may initialize Sparkle now.
    static func shouldStartForAutomaticChecks(enabled: Bool) -> Bool { enabled }
}

enum UpdateRecovery {
    // Keep this stable: it is the canonical recovery endpoint when an in-app update cannot finish.
    static let manualDownloadURL = URL(string: "https://burrow.computer/install")!
}

enum UpdateFailureCategory: String, Equatable {
    case appTranslocation = "app_translocation"
    case transientDownload = "transient_download"
    case noUpdate = "no_update"
    case cancelled
    case configuration
    case signatureValidation = "signature_validation"
    case installation
    case other
}

enum UpdateFailureRecovery: String, Equatable {
    case moveToApplications = "move_to_applications"
    case sparkleScheduledRetry = "sparkle_scheduled_retry"
    case none
}

struct UpdateFailureDisposition: Equatable {
    let category: UpdateFailureCategory
    let recovery: UpdateFailureRecovery
    let shouldCaptureInSentry: Bool
}

enum UpdateFailurePolicy {
    // Sparkle 2.9.4 SUErrors.h: SURunningTranslocated. Keep this explicit so
    // the policy is testable even though Swift does not import SUError cases.
    private static let runningTranslocatedCode = 1005
    private static let runningFromDiskImageCode = 1003
    private static let noUpdateCode = 1001
    private static let downloadErrorCode = 2001
    private static let installationCancelledCodes: Set<Int> = [4007, 4008]
    private static let developerActionableURLCodes: Set<Int> = [
        NSURLErrorBadURL,
        NSURLErrorUnsupportedURL,
        NSURLErrorRedirectToNonExistentLocation,
        NSURLErrorBadServerResponse,
        NSURLErrorUserAuthenticationRequired,
        NSURLErrorZeroByteResource,
        NSURLErrorCannotDecodeRawData,
        NSURLErrorCannotDecodeContentData,
        NSURLErrorCannotParseResponse,
        NSURLErrorAppTransportSecurityRequiresSecureConnection,
        NSURLErrorFileDoesNotExist,
        NSURLErrorNoPermissionsToReadFile,
        NSURLErrorSecureConnectionFailed,
        NSURLErrorServerCertificateHasBadDate,
        NSURLErrorServerCertificateUntrusted,
        NSURLErrorServerCertificateHasUnknownRoot,
        NSURLErrorServerCertificateNotYetValid,
        NSURLErrorClientCertificateRejected,
        NSURLErrorClientCertificateRequired,
    ]

    static func classify(_ error: NSError) -> UpdateFailureDisposition {
        let underlying = deepestUnderlyingError(in: error)
        let sparkleInstallationCancelled = error.domain == SUSparkleErrorDomain
            && installationCancelledCodes.contains(error.code)
        let underlyingRequestCancelled = underlying?.domain == NSURLErrorDomain
            && underlying?.code == NSURLErrorCancelled
        if sparkleInstallationCancelled || underlyingRequestCancelled {
            return UpdateFailureDisposition(
                category: .cancelled,
                recovery: .none,
                shouldCaptureInSentry: false
            )
        }
        if error.domain == SUSparkleErrorDomain, error.code == noUpdateCode {
            return UpdateFailureDisposition(
                category: .noUpdate,
                recovery: .none,
                shouldCaptureInSentry: false
            )
        }
        if error.domain == SUSparkleErrorDomain,
           error.code == runningTranslocatedCode || error.code == runningFromDiskImageCode {
            return UpdateFailureDisposition(
                category: .appTranslocation,
                recovery: .moveToApplications,
                shouldCaptureInSentry: false
            )
        }
        if error.domain == SUSparkleErrorDomain, error.code == downloadErrorCode {
            if let underlying,
               underlying.domain == NSURLErrorDomain,
               developerActionableURLCodes.contains(underlying.code) {
                return UpdateFailureDisposition(
                    category: .configuration,
                    recovery: .none,
                    shouldCaptureInSentry: true
                )
            }
            return UpdateFailureDisposition(
                category: .transientDownload,
                recovery: .sparkleScheduledRetry,
                shouldCaptureInSentry: false
            )
        }
        if error.domain == NSURLErrorDomain {
            if developerActionableURLCodes.contains(error.code) {
                return UpdateFailureDisposition(
                    category: .configuration,
                    recovery: .none,
                    shouldCaptureInSentry: true
                )
            }
            return UpdateFailureDisposition(
                category: error.code == NSURLErrorCancelled ? .cancelled : .transientDownload,
                recovery: error.code == NSURLErrorCancelled ? .none : .sparkleScheduledRetry,
                shouldCaptureInSentry: false
            )
        }
        if error.domain == SUSparkleErrorDomain, (1...7).contains(error.code) {
            return UpdateFailureDisposition(
                category: .configuration,
                recovery: .none,
                shouldCaptureInSentry: true
            )
        }
        if error.domain == SUSparkleErrorDomain, (3001...3002).contains(error.code) {
            return UpdateFailureDisposition(
                category: .signatureValidation,
                recovery: .none,
                shouldCaptureInSentry: true
            )
        }
        if error.domain == SUSparkleErrorDomain, (4000...4012).contains(error.code) {
            return UpdateFailureDisposition(
                category: .installation,
                recovery: .none,
                shouldCaptureInSentry: true
            )
        }
        return UpdateFailureDisposition(
            category: .other,
            recovery: .none,
            shouldCaptureInSentry: true
        )
    }

    /// Sparkle wraps URLSession failures. Preserve only bounded domains/codes;
    /// descriptions and failing URLs can contain private network information.
    static func telemetryProperties(for error: NSError) -> [String: Any] {
        let disposition = classify(error)
        var properties: [String: Any] = [
            "error_domain": error.domain,
            "error_code": error.code,
            "failure_category": disposition.category.rawValue,
            "recovery": disposition.recovery.rawValue,
        ]
        if let underlying = deepestUnderlyingError(in: error),
           underlying.domain != error.domain || underlying.code != error.code {
            properties["underlying_error_domain"] = underlying.domain
            properties["underlying_error_code"] = underlying.code
        }
        return properties
    }

    private static func deepestUnderlyingError(in error: NSError) -> NSError? {
        var current = error
        var visited = Set<ObjectIdentifier>()
        while let next = current.userInfo[NSUnderlyingErrorKey] as? NSError {
            let identity = ObjectIdentifier(next)
            guard visited.insert(identity).inserted else { break }
            current = next
        }
        return current === error ? nil : current
    }
}

@MainActor
final class AppUpdate: NSObject, SPUUpdaterDelegate {
    static let shared = AppUpdate()

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )
    private var started = false
    private var updateFoundInCycle = false
    private var noUpdateInCycle = false
    private var stabilityTask: Task<Void, Never>?
    private var startSource = "automatic"

    private override init() {
        super.init()
    }

    /// Starts Sparkle once and migrates Burrow's existing auto-check choice.
    /// Info.plist disallows background downloads entirely. A missing
    /// development key leaves local source builds usable; the tag workflow
    /// rejects that configuration before building.
    @discardableResult
    func begin(source: String = "automatic") -> Bool {
        guard !started, Self.hasValidPublicKey else { return false }
        // Every start path (automatic, Settings, or manual) records the same
        // durable boundary before constructing Sparkle. A synchronous wedge
        // or an immediate AppKit callback therefore suppresses the next
        // automatic start instead of repeating it on every launch.
        LaunchJournal.live.mark(.updaterScheduled)
        CrashReporter.setLaunchPhase(.updaterScheduled)
        if let legacyChoice = Store.migrateLegacyUpdatePreferences() {
            controller.updater.automaticallyChecksForUpdates = legacyChoice
        }
        controller.startUpdater()
        started = true
        startSource = source
        Telemetry.capture("updater_started", ["source": source])
        scheduleStabilityMarker()
        return true
    }

    private func scheduleStabilityMarker() {
        stabilityTask?.cancel()
        stabilityTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.stabilityTask = nil
            LaunchJournal.live.markAutomaticUpdaterStable()
            LaunchJournal.live.mark(.updaterReady)
            CrashReporter.setLaunchPhase(.updaterReady)
            Telemetry.capture("updater_stabilized", ["source": self.startSource])
        }
    }

    func setAutomaticChecks(_ enabled: Bool) {
        // Persisting "off" must not construct/start Sparkle during Burrow's
        // guarded launch window. Turning checks on, or checking manually, is
        // an explicit action and may start it immediately.
        Store.autoCheckForUpdates = enabled
        if UpdateStartPolicy.shouldStartForAutomaticChecks(enabled: enabled) {
            begin(source: "settings")
        }
        if started {
            controller.updater.automaticallyChecksForUpdates = enabled
        }
    }

    /// A manual check always uses Sparkle's native progress/result/update UI.
    func checkNow() {
        begin(source: "manual")
        guard started else { return }
        updateFoundInCycle = false
        noUpdateInCycle = false
        Telemetry.capture("update_check_started", ["source": "manual"])
        controller.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        updateFoundInCycle = true
        noUpdateInCycle = false
        Telemetry.capture("update_found", [
            "target_version": item.displayVersionString,
        ])
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        noUpdateInCycle = true
        let nsError = error as NSError
        let userInitiated = nsError.userInfo[SPUNoUpdateFoundUserInitiatedKey] as? Bool ?? false
        Telemetry.capture("update_not_found", [
            "source": userInitiated ? "manual" : "automatic",
        ])
    }

    func updater(
        _ updater: SPUUpdater,
        willDownloadUpdate item: SUAppcastItem,
        with request: NSMutableURLRequest
    ) {
        Telemetry.capture("update_download_started", [
            "target_version": item.displayVersionString,
        ])
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        Telemetry.capture("update_download_completed", [
            "target_version": item.displayVersionString,
        ])
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        let nsError = error as NSError
        var properties = UpdateFailurePolicy.telemetryProperties(for: nsError)
        properties["target_version"] = item.displayVersionString
        Telemetry.capture("update_download_failed", properties)
        // Sentry receives only one actionable diagnostic at cycle completion.
        // Expected network/translocation failures remain PostHog-only.
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        Telemetry.capture("update_install_started", [
            "target_version": item.displayVersionString,
        ])
    }

    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        let choiceName: String
        switch choice.rawValue {
        case 0: choiceName = "skip"
        case 1: choiceName = "install"
        default: choiceName = "dismiss"
        }
        Telemetry.capture("update_choice_made", [
            "choice": choiceName,
            "stage": state.stage.rawValue,
            "target_version": updateItem.displayVersionString,
        ])
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        let source: String
        switch updateCheck.rawValue {
        case 0: source = "manual"
        case 1: source = "automatic"
        default: source = "information"
        }
        if let error, !noUpdateInCycle {
            let nsError = error as NSError
            let disposition = UpdateFailurePolicy.classify(nsError)
            if disposition.category == .cancelled {
                Telemetry.capture("update_cycle_completed", [
                    "source": source,
                    "result": "cancelled",
                ])
            } else {
                var properties = UpdateFailurePolicy.telemetryProperties(for: nsError)
                properties["source"] = source
                properties["update_found"] = updateFoundInCycle
                Telemetry.capture("update_cycle_failed", properties)
                if disposition.shouldCaptureInSentry {
                    CrashReporter.captureDiagnostic(
                        "update_cycle_failed",
                        error: error,
                        data: properties
                    )
                }
            }
        } else {
            Telemetry.capture("update_cycle_completed", [
                "source": source,
                "result": noUpdateInCycle ? "no_update" : (updateFoundInCycle ? "update_found" : "completed"),
            ])
        }
        updateFoundInCycle = false
        noUpdateInCycle = false
    }

    private static var hasValidPublicKey: Bool {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              let data = Data(base64Encoded: key) else { return false }
        return data.count == 32
    }
}

enum UpdateCheck {
    /// Numeric per-component compare used by the Updates inventory for other
    /// apps. Burrow's own update selection and verification belong to Sparkle.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            var value = s.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
            return value.split(separator: ".").map { Int($0) ?? 0 }
        }
        let remoteParts = parts(remote)
        let localParts = parts(local)
        for index in 0..<max(remoteParts.count, localParts.count) {
            let remotePart = index < remoteParts.count ? remoteParts[index] : 0
            let localPart = index < localParts.count ? localParts[index] : 0
            if remotePart != localPart { return remotePart > localPart }
        }
        return false
    }

    @MainActor
    static func checkNow() {
        AppUpdate.shared.checkNow()
    }
}
