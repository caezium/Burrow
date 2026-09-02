//
//  LocationAccess.swift
//  Burrow
//
//  Location Services authorization for the Get Online pane (#416).
//
//  Since macOS 14, CoreWLAN hides Wi-Fi identity behind Location Services:
//  `scanForNetworks` returns networks with nil SSIDs and `interface().ssid()`
//  returns nil unless the app holds a Location grant. macOS only ever prompts
//  for that grant when the app *asks* through CoreLocation — CoreWLAN alone
//  never triggers the dialog, and an app that never asks never appears under
//  Privacy & Security ▸ Location Services, so there is nothing for the user
//  to switch on. Burrow never asked, which is why the nearby-Wi-Fi card told
//  people to grant a permission they could not find.
//
//  The ask is tied to the Scan button: the prompt appears the first time the
//  user asks for something that needs it, and never on launch.
//

import Foundation
import CoreLocation

enum LocationAccess {
    /// What the pane should do given the current authorization status. Pure,
    /// so the mapping is unit-testable without CoreLocation.
    enum Verdict: Equatable {
        /// The grant is live — scan.
        case ready
        /// Never asked — request, then decide on the answer.
        case ask
        /// Refused, or managed away — explain and point at Settings.
        case denied
    }

    static func verdict(for status: CLAuthorizationStatus) -> Verdict {
        switch status {
        // macOS has no when-in-use tier: a grant is `.authorizedAlways`
        // (`.authorized` is its deprecated spelling, same value).
        case .authorizedAlways: return .ready
        case .notDetermined: return .ask
        case .denied, .restricted: return .denied
        default: return .denied
        }
    }

    /// Privacy & Security ▸ Location Services, the pane the grant lives in.
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!
}

/// Owns the one `CLLocationManager` Burrow needs. The manager must be created
/// on a thread with a run loop and kept alive until the user answers the
/// prompt, or the dialog never appears — hence a main-actor singleton rather
/// than a local inside the scan.
@MainActor
final class LocationAuthorizer: NSObject, CLLocationManagerDelegate {
    static let shared = LocationAuthorizer()

    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<CLAuthorizationStatus, Never>] = []

    private override init() {
        super.init()
        manager.delegate = self
    }

    /// The grant as it stands, without prompting.
    var status: CLAuthorizationStatus { manager.authorizationStatus }

    /// Prompts if the user has never been asked, and resolves with the status
    /// once they answer. Returns immediately when the answer is already known.
    func requestAuthorization() async -> CLAuthorizationStatus {
        let current = manager.authorizationStatus
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.settle(status) }
    }

    private func settle(_ status: CLAuthorizationStatus) {
        // CoreLocation also calls the delegate right after it is set, while
        // the status is still undecided; only an answer settles the waiters.
        guard status != .notDetermined, !waiting.isEmpty else { return }
        let continuations = waiting
        waiting = []
        continuations.forEach { $0.resume(returning: status) }
    }
}
