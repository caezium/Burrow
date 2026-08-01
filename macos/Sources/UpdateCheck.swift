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

@MainActor
final class AppUpdate {
    static let shared = AppUpdate()

    private let controller: SPUStandardUpdaterController
    private var started = false

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Starts Sparkle once and migrates Burrow's existing auto-check choice.
    /// Info.plist disallows background downloads entirely. A missing
    /// development key leaves local source builds usable; the tag workflow
    /// rejects that configuration before building.
    func begin() {
        guard !started, Self.hasValidPublicKey else { return }
        if let legacyChoice = Store.migrateLegacyUpdatePreferences() {
            controller.updater.automaticallyChecksForUpdates = legacyChoice
        }
        controller.startUpdater()
        started = true
    }

    func setAutomaticChecks(_ enabled: Bool) {
        begin()
        if started {
            controller.updater.automaticallyChecksForUpdates = enabled
        } else {
            // Local source builds without a configured public key still keep
            // the user's choice for the next valid build.
            Store.autoCheckForUpdates = enabled
        }
    }

    /// A manual check always uses Sparkle's native progress/result/update UI.
    func checkNow() {
        begin()
        guard started else { return }
        controller.checkForUpdates(nil)
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
