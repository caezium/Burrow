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
            Telemetry.capture("updater_stabilized")
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
        Telemetry.capture("update_not_found")
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
        let properties: [String: Any] = [
            "target_version": item.displayVersionString,
            "error_domain": nsError.domain,
            "error_code": nsError.code,
        ]
        Telemetry.capture("update_download_failed", properties)
        CrashReporter.logError("update_download_failed", data: properties)
        CrashReporter.captureDiagnostic("update_download_failed", error: error, data: [
            "target_version": item.displayVersionString,
        ])
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
            let properties: [String: Any] = [
                "source": source,
                "update_found": updateFoundInCycle,
                "error_domain": nsError.domain,
                "error_code": nsError.code,
            ]
            Telemetry.capture("update_cycle_failed", properties)
            CrashReporter.logError("update_cycle_failed", data: properties)
            CrashReporter.captureDiagnostic("update_cycle_failed", error: error, data: [
                "source": source,
                "update_found": updateFoundInCycle,
            ])
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
