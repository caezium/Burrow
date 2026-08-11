//
//  TuneUp.swift
//  Burrow
//
//  Tune-Up redesign (roadmap F / #77): a persistent pane that auto-flags work
//  (apps to update/uninstall, brew cleanup, startup items, big disks), runs
//  the *safe* set, and leaves the rest for review. This is the selection
//  logic — which recommendations are auto-runnable vs review-only, and the
//  reclaimable total. Generating recommendations (querying updates/unused
//  apps/startup/disk) and the persistent pane are integration.
//

import Foundation

enum TuneUp {
    struct ConfirmationPolicy: Equatable {
        let includesClean: Bool

        var requiresIrreversibleConsent: Bool { includesClean }
        var notice: String {
            includesClean
                ? NSLocalizedString("Clean caches & junk permanently deletes the reviewed cache files. They do not go to the Trash and cannot be recovered. Each elevated step asks for your password separately.", comment: "tune-up notice")
                : NSLocalizedString("Maintenance does not run the cache-deletion step. Each elevated step asks for your password separately.", comment: "tune-up notice")
        }

        func permitsRun(irreversibleConsent: Bool) -> Bool {
            !requiresIrreversibleConsent || irreversibleConsent
        }
    }

    enum Kind: String, Equatable {
        case brewCleanup, freeCache, updateApp        // safe to auto-run
        case uninstallUnused, disableStartupItem       // destructive — review only
    }

    struct Recommendation: Equatable {
        let kind: Kind
        let title: String
        let bytes: Int64
        /// Auto-runnable without per-item confirmation. Reversible /
        /// non-destructive actions only; anything that removes an app or
        /// changes what launches at login is review-only by design.
        var safe: Bool {
            switch kind {
            case .brewCleanup, .freeCache, .updateApp: return true
            case .uninstallUnused, .disableStartupItem: return false
            }
        }
    }

    /// The set Tune-Up may run in one click.
    static func safeSet(_ recs: [Recommendation]) -> [Recommendation] { recs.filter(\.safe) }
    /// What needs the user's eyes first.
    static func reviewSet(_ recs: [Recommendation]) -> [Recommendation] { recs.filter { !$0.safe } }
    static func reclaimable(_ recs: [Recommendation]) -> Int64 { recs.reduce(0) { $0 + $1.bytes } }
}
