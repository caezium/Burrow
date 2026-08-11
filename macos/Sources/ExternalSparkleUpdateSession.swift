//
//  ExternalSparkleUpdateSession.swift
//  Burrow
//
//  Drives Sparkle against another installed app bundle. Sparkle remains the
//  authority for appcast selection, archive signatures, code-signing checks,
//  authorization, replacement, and relaunch; Burrow only mirrors lifecycle
//  state into the unified Updates list.
//

import Foundation
import Sparkle

@MainActor
final class ExternalSparkleUpdateSession: NSObject, SPUUpdaterDelegate {
    private var userDriver: SPUStandardUserDriver!
    private var updater: SPUUpdater!
    private let onPhase: (UpdatePhase) -> Void
    private let onMetadata: (String, URL?) -> Void
    private let onFinish: () -> Void
    private var lastPhase: UpdatePhase = .checking
    private var didFindUpdate = false
    private var finished = false

    init?(
        appPath: String,
        onPhase: @escaping (UpdatePhase) -> Void,
        onMetadata: @escaping (String, URL?) -> Void,
        onFinish: @escaping () -> Void
    ) {
        guard let bundle = Bundle(path: appPath) else { return nil }
        self.onPhase = onPhase
        self.onMetadata = onMetadata
        self.onFinish = onFinish
        super.init()
        userDriver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
        updater = SPUUpdater(
            hostBundle: bundle,
            applicationBundle: bundle,
            userDriver: userDriver,
            delegate: self
        )
    }

    /// Abandon a session the user cancelled, settling it through the SAME
    /// finishOnce path every other exit uses — so the awaiting continuation
    /// resumes exactly once and the caller's bookkeeping is cleared by the
    /// existing onFinish handler. Without this, cancelling left the
    /// continuation suspended forever: the task was cancelled but a checked
    /// continuation is not resumed by cancellation, so the session stayed
    /// registered and every `sparkleSessions.isEmpty` gate stayed shut.
    func cancelSession() {
        finishOnce()
    }

    func begin() -> UpdateFailure? {
        transition(.checking)
        do {
            try updater.start()
            updater.checkForUpdates()
            return nil
        } catch {
            let failure = UpdateFailure.unsupported(error.localizedDescription)
            transition(.failed(failure))
            finishOnce()
            return failure
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        didFindUpdate = true
        onMetadata(item.displayVersionString, item.releaseNotesURL ?? item.infoURL)
        transition(.available)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        transition(.completed)
    }

    func updater(
        _ updater: SPUUpdater,
        willDownloadUpdate item: SUAppcastItem,
        with request: NSMutableURLRequest
    ) {
        transition(.downloading(progress: nil))
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        transition(.verifying)
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        transition(.failed(Self.failure(from: error)))
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        transition(.failed(.cancelled))
    }

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        transition(.verifying)
    }

    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        // Sparkle validates the archive and replacement bundle before this
        // callback. Its native window owns the final install/relaunch choice.
        transition(.readyToInstall)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        transition(.installing)
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        transition(.waitingForRestart)
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        if let error {
            if UpdateFailurePolicy.classify(error as NSError).category == .noUpdate {
                transition(.completed)
                finishOnce()
                return
            }
            let failure = Self.failure(from: error)
            if failure != .cancelled {
                transition(.failed(failure))
            } else if !didFindUpdate {
                transition(.failed(.cancelled))
            }
        } else {
            switch lastPhase {
            case .installing, .waitingForRestart:
                transition(.completed)
            case .checking where !didFindUpdate:
                transition(.completed)
            default:
                break
            }
        }
        finishOnce()
    }

    private func transition(_ phase: UpdatePhase) {
        lastPhase = phase
        onPhase(phase)
    }

    private func finishOnce() {
        guard !finished else { return }
        finished = true
        onFinish()
    }

    private static func failure(from error: Error) -> UpdateFailure {
        let nsError = error as NSError
        let underlying = deepestUnderlyingError(in: nsError)
        let urlError = [underlying, nsError].compactMap { candidate -> URLError? in
            guard candidate.domain == NSURLErrorDomain else { return nil }
            return URLError(URLError.Code(rawValue: candidate.code))
        }.first
        if let urlError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .internationalRoamingOff, .dataNotAllowed:
                return .offline
            case .timedOut:
                return .timeout
            case .cancelled:
                return .cancelled
            default:
                return .network(code: urlError.errorCode)
            }
        }
        switch UpdateFailurePolicy.classify(nsError).category {
        case .noUpdate:
            return .cancelled
        case .cancelled:
            return .cancelled
        case .transientDownload:
            return .network(code: nsError.code)
        case .signatureValidation:
            return .verification(.invalidSignature)
        case .appTranslocation, .configuration:
            return .unsupported(nsError.localizedDescription)
        case .installation, .other:
            return .installation(nsError.localizedDescription)
        }
    }

    private static func deepestUnderlyingError(in error: NSError) -> NSError {
        var current = error
        var seen = Set<ObjectIdentifier>()
        while let next = current.userInfo[NSUnderlyingErrorKey] as? NSError,
              seen.insert(ObjectIdentifier(next)).inserted {
            current = next
        }
        return current
    }
}
