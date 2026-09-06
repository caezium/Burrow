//
//  FeatureFlags.swift
//  Burrow
//
//  Privacy-safe, cached PostHog feature flags (issue #322). Flags gate
//  UI-only rollout choices and nothing else: they can never influence
//  cleaning/deletion behavior, permissions, security controls, signing or
//  notarization, Sparkle verification, launch recovery, or telemetry
//  consent. Every unknown key, malformed value, stale cache, and network
//  failure falls back to the baked-in conservative defaults below, so the
//  app is always fully functional — and identical to a flag-free build —
//  without PostHog.
//

import Foundation
import Darwin

enum FeatureFlags {

    /// The complete allowlist. A key that is not in this enum is ignored
    /// everywhere: it is never requested, cached, persisted, reported, or
    /// able to change any behavior, no matter what the decide endpoint
    /// returns.
    enum Key: String, CaseIterable {
        /// Settings ▸ About shows an extra "Release Notes" link. This is
        /// the deliberately harmless UI-only flag that validates the whole
        /// pipeline (fetch → cache → lookup → exposure event) before any
        /// broader use; default OFF.
        case aboutReleaseNotesLink = "about_release_notes_link"
    }

    /// Baked-in conservative defaults served before anything is fetched and
    /// whenever a fetch, cache read, or parse fails. Everything defaults to
    /// OFF so a flag that cannot be proven ON simply does not exist.
    private static let defaults: [Key: Bool] = [
        .aboutReleaseNotesLink: false,
    ]

    /// A cache older than this is stale: its values are ignored and the
    /// file is rewritten only after a later successful fetch.
    static let maxCacheAge: TimeInterval = 7 * 24 * 3_600

    /// The cache is allowlist-sized by construction (a handful of booleans);
    /// a file larger than this bound is corrupt or foreign and is discarded
    /// unread.
    static let maxCacheBytes = 16 * 1024

    static let cacheFileName = "feature-flags.json"

    private static let lock = NSLock()
    private static let timestampFormatter = ISO8601DateFormatter()
    /// Accessed under `lock`. Defaults merged with the last accepted set.
    private static var snapshot: [Key: Bool] = defaults
    /// Accessed under `lock`. Keys already reported this launch, so each
    /// flag emits at most one exposure event per session.
    private static var exposedThisLaunch: Set<Key> = []

    // MARK: - Lookup

    /// Synchronous, main-thread-safe, and never touches disk or network:
    /// it reads the in-memory snapshot only. An opted-out launch never
    /// populates the snapshot, so it sees the conservative defaults until
    /// telemetry has been enabled and a fresh cache or successful fetch
    /// has been applied at least once.
    ///
    /// The value is evaluated where it is read (typically a SwiftUI body):
    /// a flag that flips mid-session becomes visible the next time that
    /// view rebuilds — these are rollout switches, not live remotes.
    static func isEnabled(_ key: Key) -> Bool {
        guard Telemetry.isEnabled else { return defaults[key] ?? false }
        lock.lock()
        let value = snapshot[key] ?? defaults[key] ?? false
        lock.unlock()
        expose(key, value: value)
        return value
    }

    /// One PostHog-native `$feature_flag_called` exposure per flag per launch,
    /// carrying only the allowlisted key and its boolean under the property
    /// names PostHog's flag usage views read. The key is only marked reported
    /// when `Telemetry` can actually queue the event; while opted out,
    /// before `start()`, or without a release key, the lookup remains
    /// eligible so a later enabled session can emit the exposure.
    private static func expose(_ key: Key, value: Bool) {
        Telemetry.captureFeatureFlagExposure(key: key, value: value) {
            lock.lock(); defer { lock.unlock() }
            return exposedThisLaunch.insert(key).inserted
        }
    }

    // MARK: - Remote payload filter

    /// Accepts only allowlisted keys with boolean values. Strings, numbers,
    /// flag payloads, experiment metadata, and anything else PostHog adds
    /// to the decide response is ignored; only booleans are ever stored.
    static func sanitizeRemoteFlags(_ raw: [String: Any]?) -> [Key: Bool] {
        guard let raw else { return [:] }
        var accepted: [Key: Bool] = [:]
        for key in Key.allCases {
            if let value = JSONScalar.boolean(raw[key.rawValue]) {
                accepted[key] = value
            }
        }
        return accepted
    }

    // MARK: - Cache codec

    static func encodeCache(_ flags: [Key: Bool], fetchedAt: Date) -> Data? {
        var values: [String: Bool] = [:]
        for (key, value) in flags { values[key.rawValue] = value }
        let payload: [String: Any] = [
            "version": 1,
            "fetched_at": timestampFormatter.string(from: fetchedAt),
            "flags": values,
        ]
        guard JSONSerialization.isValidJSONObject(payload) else { return nil }
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    /// The envelope and known flags are strict: malformed JSON, a wrong
    /// version, an invalid known value, or a missing/stale timestamp discards
    /// the cache. Unknown keys are ignored so a cache from a newer build can
    /// still serve the valid allowlisted booleans this build understands.
    static func decodeCache(_ data: Data, now: Date) -> [Key: Bool]? {
        guard let decoded = try? JSONSerialization.jsonObject(with: data),
              let object = decoded as? [String: Any],
              (object["version"] as? Int) == 1,
              JSONScalar.boolean(object["version"]) == nil,
              let fetchedAt = (object["fetched_at"] as? String)
                  .flatMap(timestampFormatter.date(from:)),
              fetchedAt <= now,
              now.timeIntervalSince(fetchedAt) <= maxCacheAge,
              let values = object["flags"] as? [String: Any] else { return nil }

        var flags: [Key: Bool] = [:]
        for key in Key.allCases {
            guard let rawValue = values[key.rawValue] else { continue }
            guard let value = JSONScalar.boolean(rawValue) else { return nil }
            flags[key] = value
        }
        return flags
    }

    /// Reads the on-disk cache. `nil` means "no usable cache" (absent,
    /// oversized, corrupt, or stale); callers leave defaults in place.
    /// Open once and bound the read itself: replacing or growing a pathname
    /// after a size check must never turn a tiny cache into unbounded I/O.
    static func loadCached(from directory: URL, now: Date) -> [Key: Bool]? {
        let fileURL = directory.appendingPathComponent(cacheFileName)
        let descriptor = open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              (1 ... Int64(maxCacheBytes)).contains(info.st_size),
              let data = try? handle.read(upToCount: maxCacheBytes + 1),
              !data.isEmpty, data.count <= maxCacheBytes else { return nil }
        return decodeCache(data, now: now)
    }

    /// The opt-out gate for cache reads: an opted-out launch must not read
    /// the flag cache any more than it contacts PostHog, so it returns `nil`
    /// without touching the filesystem.
    static func loadCachedIfEnabled(isEnabled: Bool, directory: URL?, now: Date = Date()) -> [Key: Bool]? {
        guard isEnabled, let directory else { return nil }
        return loadCached(from: directory, now: now)
    }

    // MARK: - Applying results

    /// Merges an accepted set (remote or freshly decoded cache) over the
    /// defaults, updates the in-memory snapshot, and optionally persists
    /// the merged snapshot atomically. Runs on Telemetry's background
    /// queue; the caller owns the `Telemetry.isEnabled` gate so an
    /// opted-out launch neither reads nor writes anything here.
    static func apply(_ flags: [Key: Bool], persistTo directory: URL?) {
        lock.lock()
        var merged = defaults
        for (key, value) in flags { merged[key] = value }
        snapshot = merged
        lock.unlock()

        guard let directory,
              let data = encodeCache(merged, fetchedAt: Date()) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(cacheFileName), options: .atomic)
    }

    /// `~/Library/Application Support/Burrow` — the same directory as the
    /// telemetry id, outbox, and launch journal.
    static func defaultCacheDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Burrow", isDirectory: true)
    }

    // MARK: - Tests

    #if DEBUG
    /// Restores the pristine pre-launch state between tests. Never called
    /// by production code.
    static func resetForTesting() {
        lock.lock()
        snapshot = defaults
        exposedThisLaunch = []
        lock.unlock()
    }
    #endif
}
