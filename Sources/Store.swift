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

enum Store {
    private static let d = UserDefaults.standard

    /// Persist a value AND flush it to disk immediately. UserDefaults writes
    /// are normally batched by cfprefsd, so a setting changed seconds before
    /// the app is replaced/killed by an updater could be lost — which is what
    /// "my menu-bar / retention setting resets after an update" looks like.
    /// Flushing on write closes that window for the user-facing toggles.
    private static func write(_ value: Any?, _ key: String) {
        d.set(value, forKey: key)
        d.synchronize()
    }

    // MARK: - Sampler

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
    /// language code we ship ("en" / "zh-Hans"). Writing it also sets the
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
    /// for hosted APIs (e.g. OpenAI). Stored in UserDefaults — fine for a
    /// localhost key; move to Keychain before shipping cloud keys.
    static var aiOpenAIKey: String {
        get { d.string(forKey: "ai_openai_key") ?? "" }
        set { d.set(newValue, forKey: "ai_openai_key") }
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

    // MARK: - Privacy

    /// Whether the user has dismissed the Full Disk Access notice that
    /// Burrow shows before scans which walk TCC-protected directories
    /// (issue #3). Defaults to false so first-run users see it once;
    /// sticks once dismissed so we never nag.
    static var fullDiskAccessNoticeDismissed: Bool {
        get { d.object(forKey: "fda_notice_dismissed") as? Bool ?? false }
        set { d.set(newValue, forKey: "fda_notice_dismissed") }
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
