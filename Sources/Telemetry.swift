//
//  Telemetry.swift
//  Burrow
//
//  Product analytics, via PostHog. Answers "how many installs stay active,
//  on which versions, and which features do people actually use" — so we can
//  see adoption/retention and where to invest, without an account or anything
//  that identifies a person.
//
//  Privacy rules (enforced here, not just promised):
//    * OPT-OUT, on by default. `Store.telemetryEnabled` gates everything; the
//      Settings toggle calls `setEnabled`. When off, the SDK is hard-muted
//      (`config.optOut`) and `capture` is a no-op.
//    * No PII. `sanitize()` drops sensitive keys and only lets through
//      primitives. Sizes/counts/durations are BUCKETED (`bytesBucket` etc.),
//      never raw values — coarse enough to identify nobody.
//    * Inert without a key. The PostHog project key is injected at release
//      time (Info.plist `PHPostHogApiKey`, from a build setting). A dev build
//      ships it empty, so `start()` returns before any network setup.
//    * Identity is PostHog's own random distinct id — not derived from the
//      serial, MAC, hardware, or account.
//
//  Crash reporting (Sentry) is a separate concern in `CrashReporter.swift`,
//  but it follows the same opt-in flag and is started/stopped from here so
//  there's one switch for "share anonymous data."
//

import Foundation
import PostHog

enum Telemetry {

    /// One-time guard so a stray second `start()` can't re-init the SDK.
    private static var started = false

    /// True once `PostHogSDK.setup` actually ran — i.e. a release key was
    /// present. `started` alone is set even in keyless dev builds, where
    /// calling into the never-configured SDK would only produce console
    /// warnings; every PostHog call below is gated on BOTH.
    private static var configured = false

    /// Whether this build carries release-injected telemetry keys at all.
    /// Used by the first-launch consent notice: a source/dev build can't
    /// send anything, so it shouldn't ask.
    static var hasReleaseKeys: Bool {
        let info = Bundle.main.infoDictionary
        let key = (info?["PHPostHogApiKey"] as? String) ?? ""
        let dsn = (info?["SentryDSN"] as? String) ?? ""
        return !key.isEmpty || !dsn.isEmpty
    }

    /// The single opt-in switch, persisted in `Store`. Reused as the gate for
    /// both PostHog and Sentry.
    static var isEnabled: Bool {
        get { Store.telemetryEnabled }
        set { Store.telemetryEnabled = newValue }
    }

    // MARK: - Lifecycle

    /// Call once, at launch. Reads the release-injected key; with no key (dev
    /// builds) it starts crash reporting's no-op path and returns — nothing
    /// networked. With a key and opt-in, it configures PostHog, registers the
    /// non-identifying super properties, and emits `app_opened`.
    static func start() {
        guard !started else { return }
        started = true

        let info = Bundle.main.infoDictionary
        let apiKey = (info?["PHPostHogApiKey"] as? String) ?? ""
        let host = (info?["PHPostHogHost"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "https://us.i.posthog.com"

        // Crash reporting shares the opt-in flag; safe no-op if no DSN is set.
        CrashReporter.start(enabled: isEnabled)

        guard !apiKey.isEmpty else { return }  // unconfigured / dev build → no analytics

        let config = PostHogConfig(projectToken: apiKey, host: host)
        config.captureApplicationLifecycleEvents = false  // we emit our own lifecycle events
        config.captureScreenViews = false                 // AppKit; no autocapture
        config.optOut = !isEnabled                         // hard-mute the network when opted out
        // Burrow uses no feature flags; preloading them would add an extra
        // network call at every launch that TELEMETRY.md doesn't list.
        config.preloadFeatureFlags = false
        PostHogSDK.shared.setup(config)
        configured = true

        guard isEnabled else { return }
        registerSuperProperties()
        capture("app_opened", ["cold_start": true])
    }

    /// Best-effort flush on quit so the final session's events aren't lost.
    static func flush() {
        guard configured, isEnabled else { return }
        PostHogSDK.shared.flush()
    }

    // MARK: - Capture

    /// Record an event. No-op unless started AND opted in. Props are sanitized;
    /// pass already-bucketed values (see the `*Bucket` helpers) for anything
    /// derived from sizes, counts, or durations.
    static func capture(_ event: String, _ props: [String: Any] = [:]) {
        guard configured, isEnabled else { return }
        PostHogSDK.shared.capture(event, properties: sanitize(props))
    }

    // MARK: - Opt-in toggle

    /// Flip the shared "share anonymous data" switch. Symmetric for PostHog and
    /// Sentry. On opt-out we send one final explicit signal, flush, then mute.
    static func setEnabled(_ enabled: Bool) {
        let previous = isEnabled
        isEnabled = enabled
        CrashReporter.setEnabled(enabled)

        guard configured else { return }
        if enabled {
            PostHogSDK.shared.optIn()
            // start() only registers these when launched enabled — an
            // opt-in mid-session must add them too, or every event until
            // relaunch goes out missing the promised app/OS/arch context.
            registerSuperProperties()
            if previous != enabled { capture("telemetry_opt_in_changed", ["enabled": true]) }
        } else {
            if previous != enabled {
                // Bypass the (now-false) `isEnabled` gate for this one event so
                // the opt-out itself is recorded, then flush before muting.
                PostHogSDK.shared.capture("telemetry_opt_in_changed", properties: ["enabled": false])
                PostHogSDK.shared.flush()
            }
            PostHogSDK.shared.optOut()
        }
    }

    // MARK: - Bucketing (never send raw sizes/counts/durations)

    /// Reclaimable/used bytes → a coarse magnitude bucket.
    static func bytesBucket(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        switch mb {
        case ..<1:      return "<1MB"
        case ..<10:     return "1-10MB"
        case ..<100:    return "10-100MB"
        case ..<1_000:  return "100MB-1GB"
        case ..<10_000: return "1-10GB"
        default:        return ">10GB"
        }
    }

    /// Item/file counts → a coarse bucket.
    static func countBucket(_ n: Int) -> String {
        switch n {
        case ..<1:    return "0"
        case ..<10:   return "1-9"
        case ..<100:  return "10-99"
        case ..<1000: return "100-999"
        default:      return "1000+"
        }
    }

    /// Seconds → a coarse duration bucket.
    static func secondsBucket(_ s: Double) -> String {
        switch s {
        case ..<1:   return "<1s"
        case ..<5:   return "1-5s"
        case ..<30:  return "5-30s"
        case ..<120: return "30-120s"
        default:     return ">2m"
        }
    }

    // MARK: - Internals

    private static func registerSuperProperties() {
        let info = Bundle.main.infoDictionary
        // Fully qualified: Burrow has its own `ProcessInfo` model that would
        // otherwise shadow Foundation's here.
        let v = Foundation.ProcessInfo.processInfo.operatingSystemVersion
        PostHogSDK.shared.register([
            // Keep events anonymous: PostHog uses this in place of the
            // connection IP, so no real IP is stored and GeoIP is skipped.
            // Belt-and-suspenders with "Discard client IP data" in the project.
            "$ip":          "0",
            "app_version":  (info?["CFBundleShortVersionString"] as? String) ?? "?",
            "build_number": (info?["CFBundleVersion"] as? String) ?? "?",
            "os_version":   "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            "arch":         cpuArch(),
            "locale":       Locale.current.identifier,
        ])
    }

    /// Defense in depth: even if a caller fat-fingers a sensitive value into an
    /// event, drop known-sensitive keys and anything non-primitive.
    private static func sanitize(_ props: [String: Any]) -> [String: Any] {
        let blocked: Set<String> = [
            "api_key", "token", "authorization", "password", "secret",
            "file_path", "path", "url", "home", "home_dir", "username",
            "user", "email", "clipboard", "file_name", "contents",
        ]
        var out: [String: Any] = [:]
        for (k, v) in props {
            if blocked.contains(k) { continue }
            if v is Int || v is Int64 || v is Double || v is Bool {
                out[k] = v
            } else {
                // Strings (and coerced enum labels) get a value-level check
                // too: a path smuggled under a non-blocked key must still
                // never leave the Mac.
                let s = (v as? String) ?? String(describing: v)
                out[k] = s.contains("/Users/") ? "<redacted>" : s
            }
        }
        return out
    }

    /// "arm64" (Apple Silicon) vs "x86_64" (Intel) — a useful product split,
    /// and coarse enough to identify nobody.
    private static func cpuArch() -> String {
        var sys = utsname()
        uname(&sys)
        let machine = withUnsafeBytes(of: &sys.machine) { raw -> String in
            let ptr = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
            return String(cString: ptr)
        }
        return machine.isEmpty ? "?" : machine
    }
}
