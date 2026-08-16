//
//  Store.swift
//  Burrow
//
//  Typed access to UserDefaults for Burrow's settings. Each property
//  has a single key, an explicit default, and a clamp on read so a
//  malformed/old value can't blow up the consumer.
//
//  Defaults are conservative: 60 s sample interval, 30 day retention,
//  port 9277 (one above Stats's MCP so they coexist). Changes are
//  picked up at the next maintenance / sampler tick — there's no
//  notification fan-out yet because the only writer is the Settings
//  UI, and the affected components poll the Store on their own
//  schedule.
//

import Foundation

/// How the real clean removes caches (see `Store.cacheRemovalMode`).
enum CacheRemovalMode: String {
    case permanent, trash
}

/// What the menu-bar status item renders (see `Store.menuBarDisplayMode`).
///   * `.icon`    — the Burrow mark.
///   * `.metrics` — the configured `menuBarItems` widget row.
///   * `.runner`  — the animated runner icon (speed tracks a metric).
enum MenuBarDisplayMode: String {
    case icon, metrics, runner
}

/// Text size for the menu-bar metric row (issue #245 — the value read too
/// small next to other menu-bar meters). `.medium` is the historical size, so
/// existing users see no change until they pick a larger one. Drives the
/// `MenuBarRenderer` fonts.
enum MenuBarTextSize: String, Codable, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }

    var title: String {
        switch self {
        case .small:  return NSLocalizedString("Small", comment: "")
        case .medium: return NSLocalizedString("Medium", comment: "")
        case .large:  return NSLocalizedString("Large", comment: "")
        }
    }

    /// Primary value font (value/labeled/bar/sparkline/battery styles).
    /// `.medium` == the historical 11 pt.
    var valueSize: CGFloat {
        switch self {
        case .small:  return 10
        case .medium: return 11
        case .large:  return 14
        }
    }

    /// Short uppercase tag ("CPU", "NET"). `.medium` == the historical 8 pt.
    var labelSize: CGFloat {
        switch self {
        case .small:  return 7
        case .medium: return 8
        case .large:  return 10
        }
    }

    /// The two-line `speed` (↓↑) style — capped smaller than the value font so
    /// both rows still fit the menu-bar height at the large setting.
    var speedSize: CGFloat {
        switch self {
        case .small:  return 7
        case .medium: return 8
        case .large:  return 9
        }
    }
}

/// A section of the menu-bar popover (`PopupView`) the user can show/hide
/// (issue #82 — the popup is the surface they actually wanted to customize).
enum PopupSection: String, Codable, CaseIterable, Identifiable {
    case header, chips, activity, metrics, battery, processes, utility, footer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .header:    return NSLocalizedString("Health header", comment: "")
        case .chips:     return NSLocalizedString("Hardware chips", comment: "")
        case .activity:  return NSLocalizedString("Activity (running jobs)", comment: "")
        case .metrics:   return NSLocalizedString("Metric tiles", comment: "")
        case .battery:   return NSLocalizedString("Battery card", comment: "")
        case .processes: return NSLocalizedString("Top processes", comment: "")
        case .utility:   return NSLocalizedString("Utility strip", comment: "")
        case .footer:    return NSLocalizedString("Clean Watch footer", comment: "")
        }
    }
}

enum Store {
    /// Backing defaults. A `var` so the test suite can swap in a scratch
    /// suite: the test bundle is hosted inside the real app (TEST_HOST), so
    /// `.standard` IS the developer's live dev.caezium.Burrow domain and
    /// must never absorb test writes.
    static var d: UserDefaults = .standard

    /// Persist a value AND flush it to disk immediately. UserDefaults writes
    /// are normally batched by cfprefsd, so a setting changed seconds before
    /// the app is replaced/killed by an updater could be lost — which is what
    /// "my menu-bar / retention setting resets after an update" looks like.
    /// Flushing on write closes that window for the user-facing toggles.
    private static func write(_ value: Any?, _ key: String) {
        d.set(value, forKey: key)
        d.synchronize()
    }

    // MARK: - Sampling

    /// Seconds between `mo status --json` invocations. Clamp to [5, 3600]
    /// because below 5 the subprocess overhead dominates, and above an
    /// hour the History view stops being useful at typical ranges.
    static var sampleIntervalSeconds: Int {
        get {
            let raw = d.integer(forKey: "sample_interval_seconds")
            return raw == 0 ? 60 : max(5, min(raw, 3600))
        }
        set {
            write(max(5, min(newValue, 3600)), "sample_interval_seconds")
        }
    }

    // MARK: - Retention

    /// History TTL in days. Older `samples` rows are pruned on the
    /// hourly maintenance tick. 0 / negative would delete everything
    /// immediately, so we clamp to ≥1.
    static var retentionDays: Int {
        get {
            let raw = d.integer(forKey: "retention_days")
            return raw == 0 ? 30 : max(1, raw)
        }
        set {
            write(max(1, newValue), "retention_days")
        }
    }

    /// Whether the maintenance scheduler should run VACUUM after a
    /// prune that deleted a non-trivial number of rows. Off by default
    /// — VACUUM rewrites the whole file and at typical churn (~1
    /// snapshot/minute) the freelist reclaim isn't worth the I/O.
    static var autoVacuum: Bool {
        get { d.object(forKey: "auto_vacuum") as? Bool ?? false }
        set { write(newValue, "auto_vacuum") }
    }

    /// Keep Screen On also prevents system sleep (survives a closed lid). Off by
    /// default — it changes power behaviour (PRD §Everyday).
    static var keepAwakeLidClosed: Bool {
        get { d.object(forKey: "keep_awake_lid_closed") as? Bool ?? false }
        set { write(newValue, "keep_awake_lid_closed") }
    }

    // MARK: - Process watchdog (PRD §α)

    /// Auto-act on a process that stays over a CPU threshold. Off by default —
    /// it can quit/suspend processes, so it's strictly opt-in.
    static var processWatchdogEnabled: Bool {
        get { d.object(forKey: "proc_watchdog_enabled") as? Bool ?? false }
        set { write(newValue, "proc_watchdog_enabled") }
    }
    /// Sustained-CPU threshold, percent.
    static var processWatchdogCPU: Double {
        get { d.object(forKey: "proc_watchdog_cpu") as? Double ?? 90 }
        set { write(newValue, "proc_watchdog_cpu") }
    }
    /// How long it must stay over threshold before the rule fires, seconds.
    static var processWatchdogSeconds: Int {
        get { d.object(forKey: "proc_watchdog_seconds") as? Int ?? 30 }
        set { write(newValue, "proc_watchdog_seconds") }
    }
    /// "notify" | "suspend" | "quit" (ProcessRule.Action raw value).
    static var processWatchdogAction: String {
        get { d.string(forKey: "proc_watchdog_action") ?? "notify" }
        set { write(newValue, "proc_watchdog_action") }
    }

    // MARK: - Menu bar

    /// Whether to install the menu-bar status item (issue #4). On by
    /// default. When off, Burrow has no menu-bar entry point, so it runs
    /// as a regular Dock app instead (window opens on launch, Dock click
    /// reopens it) — read once at launch, so a change needs a relaunch.
    static var showMenuBarIcon: Bool {
        get { d.object(forKey: "show_menu_bar_icon") as? Bool ?? true }
        set { write(newValue, "show_menu_bar_icon") }
    }

    // MARK: - Language

    /// In-app language override. "" follows the system; otherwise a bundle
    /// language code we ship ("en" / "zh-Hans" / "zh-Hant" / "ru"). Writing it also sets the
    /// system `AppleLanguages` key the bundle loader reads at launch, so the
    /// choice takes effect on the next relaunch.
    static var appLanguage: String {
        get { d.string(forKey: "app_language") ?? "" }
        set {
            d.set(newValue, forKey: "app_language")
            if newValue.isEmpty {
                d.removeObject(forKey: "AppleLanguages")   // follow the system
            } else {
                d.set([newValue], forKey: "AppleLanguages")
            }
            d.synchronize()
        }
    }

    // MARK: - AI (Explain lens)

    /// Whether the optional "Explain" AI lens is enabled. Off by default —
    /// it's opt-in, and when on it defaults to a local model so nothing
    /// leaves the Mac.
    static var aiEnabled: Bool {
        get { d.object(forKey: "ai_enabled") as? Bool ?? false }
        set { write(newValue, "ai_enabled") }
    }

    /// Which Explain backend to use: "ollama" (local, default) or "openai"
    /// (any OpenAI-compatible server — LM Studio, llama.cpp, OpenAI, …).
    static var aiProvider: String {
        get {
            let v = (d.string(forKey: "ai_provider") ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            return v == "openai" ? "openai" : "ollama"
        }
        set { d.set(newValue, forKey: "ai_provider") }
    }

    /// The local Ollama model the Explain lens talks to. Small + fast by
    /// default; the user can point it at any model they've pulled.
    static var aiOllamaModel: String {
        get {
            let v = (d.string(forKey: "ai_ollama_model") ?? "").trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? "llama3.2" : v
        }
        set { d.set(newValue, forKey: "ai_ollama_model") }
    }

    /// Base URL for the OpenAI-compatible endpoint — must end in `/v1`.
    /// Defaults to LM Studio's local server (Developer ▸ Start Server).
    static var aiOpenAIBaseURL: String {
        get {
            let v = (d.string(forKey: "ai_openai_base_url") ?? "").trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? "http://127.0.0.1:1234/v1" : v
        }
        set { d.set(newValue, forKey: "ai_openai_base_url") }
    }

    /// Model id for the OpenAI-compatible endpoint. LM Studio accepts the
    /// loaded model's id (or the alias most servers map to it).
    static var aiOpenAIModel: String {
        get {
            let v = (d.string(forKey: "ai_openai_model") ?? "").trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? "local-model" : v
        }
        set { d.set(newValue, forKey: "ai_openai_model") }
    }

    /// Optional Bearer API key for the OpenAI-compatible endpoint. Leave
    /// blank for LM Studio / local servers that don't check it; required
    /// for hosted APIs (e.g. OpenAI). Lives in the KEYCHAIN — defaults
    /// would store a cloud credential world-readable in a plist. Reads
    /// migrate any legacy defaults-stored key over once, then delete it.
    static var aiOpenAIKey: String {
        get {
            if let k = KeychainStore.string(for: "ai_openai_key") { return k }
            // One-time migration: versions ≤0.6.5 kept the key in defaults.
            let legacy = d.string(forKey: "ai_openai_key") ?? ""
            if !legacy.isEmpty {
                KeychainStore.set(legacy, for: "ai_openai_key")
                d.removeObject(forKey: "ai_openai_key")
            }
            return legacy
        }
        set {
            KeychainStore.set(newValue, for: "ai_openai_key")
            d.removeObject(forKey: "ai_openai_key")   // never reintroduce the plist copy
        }
    }

    // MARK: - MCP / QueryServer

    /// Localhost port for the JSON HTTP server. 9277 by default
    /// (Stats's MCP uses 9276, so they don't collide if both are
    /// installed). Restart required to change.
    static var queryServerPort: Int {
        get {
            let raw = d.integer(forKey: "query_server_port")
            return raw == 0 ? Int(QueryServer.defaultPort) : raw
        }
        set { d.set(newValue, forKey: "query_server_port") }
    }

    /// Whether the QueryServer should bind at launch. Off-switch for
    /// users who only want the popup + cleanup features and don't want
    /// a localhost listener.
    static var queryServerEnabled: Bool {
        get { d.object(forKey: "query_server_enabled") as? Bool ?? true }
        set { write(newValue, "query_server_enabled") }
    }

    /// Key for the destructive-MCP opt-in. Shared so the MCP process can
    /// read it with a fresh, cross-process read (see `mcpActionsEnabled`).
    static let mcpActionsEnabledKey = "mcp_actions_enabled"

    /// Whether AI agents may run *destructive* cleanups (real `mo clean`,
    /// `optimize`, `uninstall`) through the MCP server. OFF by default:
    /// agents can always read metrics and run dry-run previews, but a real
    /// deletion needs BOTH this switch AND an explicit `confirm:true` on the
    /// tool call. The MCP server is a separate, possibly long-lived process,
    /// so the getter reads straight from cfprefsd (not the cached
    /// UserDefaults snapshot) to see a toggle the GUI just flipped.
    static var mcpActionsEnabled: Bool {
        get {
            // The cross-process cfprefsd read only makes sense against the
            // real domain; an injected scratch suite (tests) reads directly.
            guard d === UserDefaults.standard else {
                return d.object(forKey: mcpActionsEnabledKey) as? Bool ?? false
            }
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
            if let v = CFPreferencesCopyAppValue(mcpActionsEnabledKey as CFString,
                                                 kCFPreferencesCurrentApplication) as? Bool {
                return v
            }
            return false
        }
        set {
            d.set(newValue, forKey: mcpActionsEnabledKey)
            d.synchronize()
        }
    }

    /// Key for the irreversible-action opt-in (see `mcpIrreversibleEnabled`).
    static let mcpIrreversibleEnabledKey = "mcp_irreversible_enabled"

    /// Second key for IRREVERSIBLE agent actions: `uninstall` (and its
    /// `permanent: true`, which bypasses the Trash). `mcpActionsEnabled`
    /// covers cleanups a user can recover from; these they can't, so they
    /// need their own explicit switch. OFF by default. Cross-process read
    /// like its sibling — the MCP subprocess must see a toggle the GUI
    /// just flipped.
    static var mcpIrreversibleEnabled: Bool {
        get {
            guard d === UserDefaults.standard else {
                return d.object(forKey: mcpIrreversibleEnabledKey) as? Bool ?? false
            }
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
            if let v = CFPreferencesCopyAppValue(mcpIrreversibleEnabledKey as CFString,
                                                 kCFPreferencesCurrentApplication) as? Bool {
                return v
            }
            return false
        }
        set {
            d.set(newValue, forKey: mcpIrreversibleEnabledKey)
            d.synchronize()
        }
    }

    // MARK: - Privacy

    /// Whether the user has dismissed the Full Disk Access notice that
    /// Burrow shows before scans which walk TCC-protected directories
    /// (issue #3). Defaults to false so first-run users see it once;
    /// sticks once dismissed so we never nag.
    static var fullDiskAccessNoticeDismissed: Bool {
        get { d.object(forKey: "fda_notice_dismissed") as? Bool ?? false }
        set { d.set(newValue, forKey: "fda_notice_dismissed") }
    }

    /// Whether the user has dismissed the banner offering the privileged
    /// helper (Touch ID for admin operations). Unlike the FDA notice — which
    /// re-asks each launch because without it scans genuinely can't read
    /// protected caches — the helper is a convenience, so one dismiss is
    /// final. Installing it hides the banner on its own.
    static var helperNoticeDismissed: Bool {
        get { d.object(forKey: "helper_notice_dismissed") as? Bool ?? false }
        set { write(newValue, "helper_notice_dismissed") }
    }

    /// Whether the popover shows a camera/microphone in-use indicator.
    /// Opt-in (off by default): detection is honest (system "in use" flag,
    /// like Control Center) but lights for Siri/dictation/Continuity too, so
    /// the user chooses to surface it.
    static var cameraMicIndicatorEnabled: Bool {
        get { d.object(forKey: "camera_mic_indicator_enabled") as? Bool ?? false }
        set { write(newValue, "camera_mic_indicator_enabled") }
    }

    // MARK: - Telemetry

    /// Anonymous usage + diagnostics opt-in (product events, crash/hang reports,
    /// release health, and sampled fixed-name performance spans). ON by default
    /// and opt-out — flipping it off in Settings sends one final opt-out event,
    /// then mutes the PostHog transport and closes Sentry. Their local random
    /// ids and any Sentry cache stay on disk, but nothing further is sent. No
    /// account, no PII, no file contents; see `Telemetry.swift`.
    static var telemetryEnabled: Bool {
        get { d.object(forKey: "telemetry_enabled") as? Bool ?? true }
        set { write(newValue, "telemetry_enabled") }
    }

    // MARK: - Behavior toggles (Settings ▸ General / Maintenance / Menu Bar)

    /// Skip the tools' idle hero screens and onboarding re-entry — open
    /// straight to the working views. Off by default; the heroes are the
    /// product's voice, power users can mute them.
    static var skipIntro: Bool {
        get { d.object(forKey: "skip_intro") as? Bool ?? false }
        set { write(newValue, "skip_intro") }
    }

    /// How the real clean removes caches. `.permanent` is the engine's
    /// behavior and the default (freed bytes are real, immediately).
    /// `.trash` routes the reviewed, ticked paths through the Finder
    /// Trash instead — recoverable, but space frees only when Trash
    /// empties and the run won't appear in `mo history`.
    static var cacheRemovalMode: CacheRemovalMode {
        get { CacheRemovalMode(rawValue: d.string(forKey: "cache_removal_mode") ?? "") ?? .permanent }
        set { write(newValue.rawValue, "cache_removal_mode") }
    }

    /// What the status item shows: the Burrow mark, or live metrics.
    static var menuBarDisplayMode: MenuBarDisplayMode {
        get { MenuBarDisplayMode(rawValue: d.string(forKey: "menu_bar_display_mode") ?? "") ?? .icon }
        set { write(newValue.rawValue, "menu_bar_display_mode") }
    }

    /// The ordered set of metric widgets the status item renders in
    /// `.metrics` mode (see `MenuBarItem` / `MenuBarWidgets.swift`). Persisted
    /// as JSON so the shape can grow without new keys. Falls back to the
    /// historical CPU + memory pair, so users who already chose "metrics" see
    /// no change until they customize.
    static var menuBarItems: [MenuBarItem] {
        get {
            guard let data = d.data(forKey: "menu_bar_items"),
                  let items = try? JSONDecoder().decode([MenuBarItem].self, from: data),
                  !items.isEmpty
            else { return MenuBarItem.defaults }
            return items
        }
        set { write(try? JSONEncoder().encode(newValue), "menu_bar_items") }
    }

    /// Which popover sections the user wants visible. Default = all (the
    /// historical full layout), so existing users see no change until they
    /// customize. Stored as a JSON array of raw values.
    static var popupSections: Set<PopupSection> {
        get {
            guard let data = d.data(forKey: "popup_sections"),
                  let raw = try? JSONDecoder().decode([String].self, from: data)
            else { return Set(PopupSection.allCases) }
            return Set(raw.compactMap(PopupSection.init(rawValue:)))
        }
        set { write(try? JSONEncoder().encode(newValue.map(\.rawValue)), "popup_sections") }
    }

    /// Which metric tiles the popover's grid shows. Default = all six.
    static var popupTiles: Set<MenuBarMetric> {
        get {
            guard let data = d.data(forKey: "popup_tiles"),
                  let raw = try? JSONDecoder().decode([String].self, from: data)
            else { return Set(MenuBarMetric.popupGrid) }
            return Set(raw.compactMap(MenuBarMetric.init(rawValue:)))
        }
        set { write(try? JSONEncoder().encode(newValue.map(\.rawValue)), "popup_tiles") }
    }

    /// The animated menu-bar runner (RunCat-style): an icon whose playback
    /// speed tracks a chosen metric. Off by default. See `MenuBarRunner.swift`.
    static var runnerConfig: RunnerConfig {
        get {
            guard let data = d.data(forKey: "runner_config"),
                  let cfg = try? JSONDecoder().decode(RunnerConfig.self, from: data)
            else { return RunnerConfig() }
            return cfg
        }
        set { write(try? JSONEncoder().encode(newValue), "runner_config") }
    }

    /// Whether closing the last window drops the Dock icon (the classic
    /// menu-bar-agent behavior, on by default). Off keeps Burrow in the
    /// Dock permanently. The safety inversion stays: with the menu-bar
    /// icon hidden, the Dock icon can't also be hidden.
    static var hideDockIcon: Bool {
        get { d.object(forKey: "hide_dock_icon") as? Bool ?? true }
        set { write(newValue, "hide_dock_icon") }
    }

    /// Whether Clean Screen also swallows key presses while wiping
    /// (except Esc). Opt-in: it needs the Accessibility permission for a
    /// CGEventTap; without it Clean Screen still works, keys just pass.
    static var cleanScreenInputLock: Bool {
        get { d.object(forKey: "clean_screen_input_lock") as? Bool ?? false }
        set { write(newValue, "clean_screen_input_lock") }
    }

    /// Global open/toggle-Burrow shortcut. nil = none recorded.
    static var globalShortcut: HotKey? {
        get { shortcut(for: .openBurrow) }
        set { setShortcut(newValue, for: .openBurrow) }
    }

    /// Recorded shortcut for one of the menu-bar tool actions.
    static func shortcut(for action: HotKeyAction) -> HotKey? {
        d.string(forKey: action.storeKey).flatMap(HotKey.init(storageValue:))
    }

    static func setShortcut(_ hotKey: HotKey?, for action: HotKeyAction) {
        if let hk = hotKey { write(hk.storageValue, action.storeKey) }
        else { d.removeObject(forKey: action.storeKey); d.synchronize() }
    }

    // MARK: - Notifications

    /// Completion notices for long operations (real clean / optimize /
    /// uninstall), posted only when Burrow isn't frontmost. ON by
    /// default — "tell me when the thing I started finishes" is the
    /// quiet, useful default.
    static var notifyOnCompletion: Bool {
        get { d.object(forKey: "notify_on_completion") as? Bool ?? true }
        set { write(newValue, "notify_on_completion") }
    }

    /// Smart reminders (clean cadence / low disk / full Trash). Opt-in:
    /// nudges are a taste thing and the default must stay quiet.
    static var smartRemindersEnabled: Bool {
        get { d.object(forKey: "smart_reminders_enabled") as? Bool ?? false }
        set { write(newValue, "smart_reminders_enabled") }
    }

    /// New-LaunchAgent / login-item watcher (D.12). On by default — a
    /// persistence item appearing is a lightweight security signal most
    /// utilities miss, so this is one of the few default-on notices.
    static var watchStartupItems: Bool {
        get { d.object(forKey: "watch_startup_items") as? Bool ?? true }
        set { write(newValue, "watch_startup_items") }
    }

    /// Persisted baseline for the startup watcher — a JSON `[String]` of item
    /// ids. Not user-facing; it's the watcher's diff anchor.
    static var startupBaselineJSON: String {
        get { d.string(forKey: "startup_baseline_json") ?? "" }
        set { write(newValue, "startup_baseline_json") }
    }

    /// The Tune-Up pane's last scan + last run, as a JSON `TuneUpSnapshot`.
    /// Persisted so the pane shows instantly on entry and survives relaunch
    /// (#77's "persisted status across pane switches AND relaunch"). Not
    /// user-facing — the pane owns the encode/decode.
    static var tuneUpStateJSON: String {
        get { d.string(forKey: "tune_up_state_json") ?? "" }
        set { write(newValue, "tune_up_state_json") }
    }

    /// Threshold alerts (CPU pegged / memory pressure high). Off by default —
    /// a taste thing, like the smart reminders.
    static var thresholdAlertsEnabled: Bool {
        get { d.object(forKey: "threshold_alerts_enabled") as? Bool ?? false }
        set { write(newValue, "threshold_alerts_enabled") }
    }

    /// The CPU-usage % at which a sustained-high alert fires (the rule's `high`
    /// edge; `low` hysteresis is derived). Default 90, clamped to a sane band so
    /// a stepper can't set a useless 0% / 100% trigger.
    static var cpuAlertThreshold: Int {
        get { let v = d.object(forKey: "cpu_alert_threshold") as? Int ?? 90; return min(100, max(50, v)) }
        set { write(min(100, max(50, newValue)), "cpu_alert_threshold") }
    }

    /// The memory-used % at which a sustained-high alert fires. Default 90.
    static var memAlertThreshold: Int {
        get { let v = d.object(forKey: "mem_alert_threshold") as? Int ?? 90; return min(100, max(50, v)) }
        set { write(min(100, max(50, newValue)), "mem_alert_threshold") }
    }

    /// Per-install bearer credential for every HTTP query-server route,
    /// including SSE. Two UUIDv4 payloads provide more than 256 random bits;
    /// strip punctuation so the value is safe to paste into an HTTP header.
    /// URLs are never accepted as credential transport because they leak into
    /// browser history, shell history, and diagnostics.
    static var queryAuthToken: String {
        if let t = d.string(forKey: "query_auth_token"),
           t.utf8.count >= 43,
           t.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }) {
            return t
        }
        let t = (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
        write(t, "query_auth_token")
        return t
    }

    // Reminder throttle state (not user-facing): hysteresis flags so a
    // metric hovering at its threshold can't flap, timestamps for the
    // weekly cooldowns. See ReminderRules (Notifications.swift).

    static var diskLowNoticeActive: Bool {
        get { d.object(forKey: "disk_low_notice_active") as? Bool ?? false }
        set { write(newValue, "disk_low_notice_active") }
    }

    static var trashNoticeActive: Bool {
        get { d.object(forKey: "trash_notice_active") as? Bool ?? false }
        set { write(newValue, "trash_notice_active") }
    }

    static var lastCleanReminderAt: Date? {
        get { d.object(forKey: "last_clean_reminder_at") as? Date }
        set { write(newValue, "last_clean_reminder_at") }
    }

    static var lastTrashReminderAt: Date? {
        get { d.object(forKey: "last_trash_reminder_at") as? Date }
        set { write(newValue, "last_trash_reminder_at") }
    }

    static var lastBackupReminderAt: Date? {
        get { d.object(forKey: "last_backup_reminder_at") as? Date }
        set { write(newValue, "last_backup_reminder_at") }
    }

    static var lastSmartReminderAt: Date? {
        get { d.object(forKey: "last_smart_reminder_at") as? Date }
        set { write(newValue, "last_smart_reminder_at") }
    }

    // MARK: - Onboarding

    /// Whether the user has finished (or skipped past) the first-run
    /// onboarding slides. False on a fresh install so they show exactly
    /// once, after the mo-missing gate; sticky forever after.
    static var onboardingCompleted: Bool {
        get { d.object(forKey: "onboarding_completed") as? Bool ?? false }
        set { write(newValue, "onboarding_completed") }
    }

    /// Whether the user has seen the first-run telemetry disclosure (the
    /// onboarding card that names the toggle inline). False on a fresh
    /// install so onboarding surfaces it once; sticky after.
    static var telemetryNoticeAcknowledged: Bool {
        get { d.object(forKey: "telemetry_notice_acknowledged") as? Bool ?? false }
        set { write(newValue, "telemetry_notice_acknowledged") }
    }

    /// The component/app/OS recovery key for which the explanation was shown.
    /// A changed build can have a different AppKit or updater result, so it
    /// gets its own notice while repeat launches on one build stay quiet.
    static var lastCompatibilityNoticeBuild: String {
        get { d.string(forKey: "last_compatibility_notice_build") ?? "" }
        set { write(newValue, "last_compatibility_notice_build") }
    }

    // MARK: - App updates (Burrow's own self-update)

    private static let legacyAutoCheckKey = "auto_check_for_updates"
    private static let legacyLastCheckKey = "last_update_check_at"
    private static let sparkleAutoCheckKey = "SUEnableAutomaticChecks"
    private static let sparkleLastCheckKey = "SULastCheckTime"

    /// Sparkle's own persisted preference is the source of truth. Until the
    /// one-time migration runs, the getter still reflects Burrow's legacy key
    /// so an existing opt-out never flashes back on in Settings.
    static var autoCheckForUpdates: Bool {
        get {
            if let value = d.object(forKey: sparkleAutoCheckKey) as? Bool {
                return value
            }
            return d.object(forKey: legacyAutoCheckKey) as? Bool ?? true
        }
        set {
            write(newValue, sparkleAutoCheckKey)
            if d.object(forKey: legacyAutoCheckKey) != nil {
                d.removeObject(forKey: legacyAutoCheckKey)
                d.synchronize()
            }
        }
    }

    /// Move 0.10.5's update preferences into Sparkle once. Preserving the
    /// last-check date avoids treating every upgrade as immediately overdue;
    /// existing Sparkle values always win if it has already run.
    ///
    /// Returning the migrated automatic-check choice lets AppUpdate apply it
    /// before starting the updater. Later launches leave Sparkle entirely in
    /// charge of both values.
    static func migrateLegacyUpdatePreferences() -> Bool? {
        let legacyChoice = d.object(forKey: legacyAutoCheckKey) as? Bool
        let legacyLastCheck = d.object(forKey: legacyLastCheckKey) as? Date
        var migratedChoice: Bool?

        if d.object(forKey: sparkleAutoCheckKey) == nil, let legacyChoice {
            d.set(legacyChoice, forKey: sparkleAutoCheckKey)
            migratedChoice = legacyChoice
        }
        if d.object(forKey: sparkleLastCheckKey) == nil, let legacyLastCheck {
            d.set(legacyLastCheck, forKey: sparkleLastCheckKey)
        }

        let hasLegacyValues = d.object(forKey: legacyAutoCheckKey) != nil
            || d.object(forKey: legacyLastCheckKey) != nil
        if hasLegacyValues {
            d.removeObject(forKey: legacyAutoCheckKey)
            d.removeObject(forKey: legacyLastCheckKey)
            d.synchronize()
        }
        return migratedChoice
    }

    // MARK: - History view

    /// Last-selected History view range, in minutes. Persisting it
    /// across launches matches the muscle-memory of the Stats fork:
    /// users converge on one range and want it sticky.
    static var lastHistoryRangeMinutes: Int {
        get {
            let raw = d.integer(forKey: "last_history_range_minutes")
            return raw == 0 ? 60 : raw  // default 1h
        }
        set { d.set(newValue, forKey: "last_history_range_minutes") }
    }
}
