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
//    * No PII: `sendDefaultPii` off, no screenshots, no performance tracing —
//      just crash/error events.
//
//  Runtime toggle is start/stop: Sentry has no live "mute" flag, so opting out
//  calls `SentrySDK.close()` and opting back in re-`start`s it.
//

import Foundation
import Sentry

enum CrashReporter {

    /// Whether the SDK is currently running (started and not closed).
    private static var running = false

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
            SentrySDK.close()
            running = false
        }
    }

    private static func startSDK() {
        let dsn = self.dsn
        let release = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = "production"
            options.releaseName = release
            options.tracesSampleRate = 0.0   // crashes/errors only, no perf tracing
            options.sendDefaultPii = false   // never attach IP/user identifiers
            // Session tracking would add a per-launch "release health"
            // beacon — a network ping carrying a persistent install id on
            // every run with zero crashes. TELEMETRY.md promises crash/error
            // events only; keep that promise.
            options.enableAutoSessionTracking = false
            // Crashes/errors only. Turn off auto-instrumentation that could
            // attach request URLs, network activity, or UI breadcrumbs to an
            // event — upholds the "no PII, no URLs" promise in TELEMETRY.md.
            options.enableNetworkTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableCaptureFailedRequests = false
            options.enableAutoBreadcrumbTracking = false
            options.enableMetrics = false
            // Binary-image and frame paths embed /Users/<name>/… whenever
            // the app runs from Downloads or a home-dir checkout (the normal
            // case for an unsigned zip). Scrub the username; the rest of the
            // path is the diagnostic part.
            options.beforeSend = { event in
                scrubUserPaths(event)
                return event
            }
        }
        running = true
    }

    /// Replace `/Users/<name>` with a placeholder in every path-bearing
    /// field a crash event carries (loaded images + stack frames).
    private static func scrubUserPaths(_ event: Event) {
        func redact(_ s: String?) -> String? {
            s?.replacingOccurrences(of: "/Users/[^/]+", with: "/Users/REDACTED",
                                    options: .regularExpression)
        }
        event.debugMeta?.forEach { $0.codeFile = redact($0.codeFile) }
        let stacktraces = (event.exceptions?.compactMap { $0.stacktrace } ?? [])
            + (event.threads?.compactMap { $0.stacktrace } ?? [])
        for st in stacktraces {
            for frame in st.frames {
                frame.package = redact(frame.package)
                frame.fileName = redact(frame.fileName)
            }
        }
    }
}
