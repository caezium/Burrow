//
//  SettingsView.swift
//  Burrow
//
//  Settings window (opened from the HUD's gear). Same contract as before
//  — reads/writes the typed `Store`, surfaces `Maintenance` status, and
//  notes which changes need a relaunch — but reskinned into the Brand
//  glass system to match the rest of the app. Hosted in a translucent
//  utility window by AppDelegate.
//

import SwiftUI
import AppKit
import LocalAuthentication

struct SettingsView: View {
    @State private var appLanguage: String = Store.appLanguage
    @State private var sampleIntervalSeconds: Int = Store.sampleIntervalSeconds
    @State private var retentionDays: Int = Store.retentionDays
    @State private var autoVacuum: Bool = Store.autoVacuum
    @State private var queryServerEnabled: Bool = Store.queryServerEnabled
    @State private var mcpActionsEnabled: Bool = Store.mcpActionsEnabled
    @State private var showMenuBarIcon: Bool = Store.showMenuBarIcon
    @State private var aiEnabled: Bool = Store.aiEnabled
    @State private var aiProvider: String = Store.aiProvider
    @State private var aiOllamaModel: String = Store.aiOllamaModel
    @State private var aiOpenAIBaseURL: String = Store.aiOpenAIBaseURL
    @State private var aiOpenAIModel: String = Store.aiOpenAIModel
    @State private var aiOpenAIKey: String = Store.aiOpenAIKey
    @State private var dbSizeText: String = "—"
    @State private var lastMaintenanceText: String = "—"
    @State private var moleVersion: String = "—"
    @State private var moleUpdating = false
    @State private var copiedConfig = false
    @State private var touchIDStatus = "—"
    @State private var touchIDEnabled = false
    @State private var touchIDBusy = false
    @State private var touchIDAvailable = false

    /// Drop-in MCP config for Claude Code / Cursor / Codex / Cline — they
    /// all share the same `{command, args}` stdio shape, so one snippet
    /// covers every agent.
    private let mcpConfigJSON = """
    {
      "mcpServers": {
        "burrow": {
          "command": "/Applications/Burrow.app/Contents/MacOS/Burrow",
          "args": ["--mcp"]
        }
      }
    }
    """

    /// Wired by AppDelegate; the only consumer is "Run maintenance now".
    var onRunMaintenance: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                    Text("Settings").font(Brand.serif(24, .medium)).foregroundStyle(Brand.textPrimary)

                    section("Storage", "internaldrive") {
                        infoRow("Currently using", dbSizeText)
                        infoRow("Last maintenance", lastMaintenanceText)
                        HStack {
                            Spacer()
                            PillButton(title: "Run maintenance now", filled: false) {
                                onRunMaintenance?(); refreshStatusLabels()
                            }
                        }
                        footnote("History lives at ~/Library/Application Support/Burrow/burrow.db. Rows past the retention window are pruned hourly.")
                    }

                    section("Mole engine", "shippingbox") {
                        infoRow("Version", moleVersion)
                        HStack {
                            Spacer()
                            if moleUpdating { ProgressView().controlSize(.small).padding(.trailing, 4) }
                            PillButton(title: moleUpdating ? "Updating…" : "Update Mole", filled: false) { updateMole() }
                        }
                        footnote("Runs `mo update` to update the Mole CLI engine Burrow drives. This is separate from Burrow's own app updates. If it needs a password or a confirmation it can't show here, run `mo update` in a terminal instead.")
                    }

                    section("Touch ID for sudo", "touchid") {
                        infoRow("Status", touchIDStatus)
                        if touchIDAvailable {
                            HStack {
                                Spacer()
                                if touchIDBusy { ProgressView().controlSize(.small).padding(.trailing, 4) }
                                PillButton(title: touchIDEnabled ? "Disable" : "Enable", filled: false) { toggleTouchID() }
                            }
                        }
                        footnote("Lets `sudo` and admin prompts accept your fingerprint instead of a password, where macOS supports it. Configured via `mo touchid`; turning it on or off needs your password once.")
                    }

                    section("History retention", "calendar") {
                        pickerRow("Keep history for", selection: $retentionDays,
                                  options: [(1, "1 day"), (7, "7 days"), (14, "14 days"),
                                            (30, "30 days"), (90, "90 days"), (180, "180 days"), (365, "1 year")]) {
                            Store.retentionDays = $0
                        }
                        toggleRow("Vacuum DB after large prunes", isOn: $autoVacuum) { Store.autoVacuum = $0 }
                    }

                    section("Sampling", "waveform.path.ecg") {
                        pickerRow("Sample every", selection: $sampleIntervalSeconds,
                                  options: [(5, "5 sec"), (15, "15 sec"), (30, "30 sec"),
                                            (60, "60 sec"), (120, "2 min"), (300, "5 min")]) {
                            Store.sampleIntervalSeconds = $0
                        }
                        footnote("Burrow runs `mo status --json` at this cadence. 60 s is plenty for charts; tighter intervals give finer detail at the cost of more subprocess churn.")
                    }

                    section("Ask your AI about your Mac (MCP)", "sparkles") {
                        Text("Burrow exposes your Mac's recorded history to coding agents — Claude Code, Cursor, Codex, Cline — over MCP. Add the config below, then ask in plain language. The server starts on demand over stdio; there's no port and no always-on listener.")
                            .font(Brand.sans(12)).foregroundStyle(Brand.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        codeBlock(mcpConfigJSON)

                        infoRow("Read tools", "snapshot · history · top_processes · process_usage · info · analyze")
                        infoRow("Cleanup tools", "clean · optimize · uninstall · purge · installer")

                        subLabel("Try asking")
                        promptRow("What's my Mac's CPU and memory usage right now?")
                        promptRow("What's taking up space in my home folder?")
                        promptRow("Preview what a cleanup would free, then clean it up.")
                        promptRow("Uninstall Slack and remove its leftovers.")

                        Divider().padding(.vertical, 2)
                        toggleRow("Let agents run cleanups for real", isOn: $mcpActionsEnabled) {
                            Store.mcpActionsEnabled = $0
                        }
                        footnote("OFF by default. Agents can always read metrics and run dry-run previews. With this on, an agent can run a real `mo clean` / `optimize` / `uninstall` — but ONLY when it also passes an explicit confirm flag, so a deletion is never one stray sentence away. Turn it off and agents are read-only again. Data stays on this Mac.")
                    }

                    section("Language", "globe") {
                        HStack {
                            Text(NSLocalizedString("App language", comment: "")).font(Brand.sans(12)).foregroundStyle(Brand.textPrimary)
                            Spacer()
                            Picker("", selection: $appLanguage) {
                                Text(NSLocalizedString("System", comment: "")).tag("")
                                Text(verbatim: "English").tag("en")
                                Text(verbatim: "中文").tag("zh-Hans")
                            }
                            .labelsHidden().pickerStyle(.menu).tint(Brand.textSecondary).fixedSize()
                            .onChange(of: appLanguage) { _, v in
                                Store.appLanguage = v
                                promptRelaunch()
                            }
                        }
                        footnote("Burrow ships English and 中文. A language change takes effect after a relaunch.")
                    }

                    section("Menu bar", "menubar.rectangle") {
                        toggleRow("Show menu bar icon", isOn: $showMenuBarIcon) { on in
                            Store.showMenuBarIcon = on
                            AppDelegate.shared?.applyMenuBarVisibility(on)
                        }
                        footnote("Applies immediately. When off, Burrow shows a Dock icon instead so it stays reachable — a Dock click reopens the window.")
                    }

                    section("Explain (AI) — experimental", "sparkles") {
                        toggleRow("Enable the Explain lens", isOn: $aiEnabled) { Store.aiEnabled = $0 }
                        HStack {
                            Text("Backend").font(Brand.sans(12)).foregroundStyle(Brand.textPrimary)
                            Spacer()
                            Picker("", selection: $aiProvider) {
                                Text("Local · Ollama").tag("ollama")
                                Text("LM Studio / API").tag("openai")
                            }
                            .labelsHidden().pickerStyle(.segmented).frame(width: 230)
                            .onChange(of: aiProvider) { _, v in Store.aiProvider = v }
                        }
                        if aiProvider == "ollama" {
                            aiField("Ollama model", placeholder: "llama3.2", text: $aiOllamaModel) { Store.aiOllamaModel = $0 }
                            footnote("Runs against a local Ollama model — nothing leaves this Mac. Start it with `ollama run <model>`.")
                        } else {
                            aiField("Base URL", placeholder: "http://127.0.0.1:1234/v1", text: $aiOpenAIBaseURL) { Store.aiOpenAIBaseURL = $0 }
                            aiField("Model", placeholder: "local-model", text: $aiOpenAIModel) { Store.aiOpenAIModel = $0 }
                            aiField("API key (optional)", placeholder: "blank for LM Studio", text: $aiOpenAIKey) { Store.aiOpenAIKey = $0 }
                            footnote("Any OpenAI-compatible server. For LM Studio: load a model, open Developer ▸ Start Server, and leave the key blank — the default URL is already LM Studio's. A hosted endpoint (e.g. OpenAI) needs a key and sends the metrics summary off-device (never file contents).")
                        }
                        footnote("Adds an \u{201C}Explain\u{201D} button to Status that reads your latest snapshot and explains it in plain English, optionally suggesting Clean/Purge/Installers.")
                    }

                    section("Local HTTP query server", "antenna.radiowaves.left.and.right") {
                        toggleRow("Enable HTTP query server", isOn: $queryServerEnabled) { Store.queryServerEnabled = $0 }
                        infoRow("Endpoint", "127.0.0.1:\(Store.queryServerPort)")
                        footnote("Optional REST surface for dashboards or curl: /health, /info, /snapshot, /metrics over localhost. Separate from the MCP stdio server above; toggle + port changes take effect after a relaunch.")
                    }
                }
                .padding(22)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { refreshStatusLabels(); loadMoleVersion(); loadTouchIDStatus() }
    }

    // MARK: - Mole engine

    private func loadMoleVersion() {
        DispatchQueue.global(qos: .userInitiated).async {
            let v = MoleCLI.version()
            DispatchQueue.main.async { moleVersion = v.map { "v\($0)" } ?? "not found" }
        }
    }

    private func updateMole() {
        guard !moleUpdating else { return }
        moleUpdating = true
        DispatchQueue.global(qos: .userInitiated).async {
            let res = try? MoleCLI.run(args: ["update"], timeout: 600)
            let newVersion = MoleCLI.version()
            DispatchQueue.main.async {
                moleUpdating = false
                if let v = newVersion { moleVersion = "v\(v)" }
                let ok = (res?.exitCode ?? 1) == 0
                let alert = NSAlert()
                alert.messageText = ok ? "Mole is up to date" : "Update didn't complete"
                alert.informativeText = ok
                    ? "Now on \(moleVersion)."
                    : (res?.stderr.isEmpty == false ? String(res!.stderr.prefix(300))
                                                    : "`mo update` exited non-zero. Try running it in a terminal.")
                alert.runModal()
            }
        }
    }

    // MARK: - Touch ID for sudo

    /// Whether this Mac actually has a Touch ID sensor. `mo touchid status`
    /// only reports configured-vs-not (never hardware presence), so we ask
    /// LocalAuthentication directly — biometryType is .touchID only on Macs
    /// with the sensor (set after a canEvaluatePolicy probe, even if no
    /// finger is enrolled yet).
    private func touchIDHardwarePresent() -> Bool {
        let ctx = LAContext()
        var err: NSError?
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
        return ctx.biometryType == .touchID
    }

    private func loadTouchIDStatus() {
        let available = touchIDHardwarePresent()
        DispatchQueue.global(qos: .userInitiated).async {
            let res = try? MoleCLI.run(args: ["touchid", "status"], timeout: 15)
            // Strip ANSI colour codes Mole wraps the status line in before matching.
            let out = CommandRunner.stripAnsi(res?.stdout ?? "").lowercased()
            let enabled = out.contains("is enabled")
            DispatchQueue.main.async {
                touchIDAvailable = available
                touchIDEnabled = enabled
                touchIDStatus = !available ? "Not available on this Mac"
                    : (out.isEmpty ? "Unknown" : (enabled ? "Enabled" : "Disabled"))
            }
        }
    }

    private func toggleTouchID() {
        guard !touchIDBusy else { return }
        touchIDBusy = true
        let cmd = touchIDEnabled ? "disable" : "enable"
        DispatchQueue.global(qos: .userInitiated).async {
            let code = MoleCLI.runElevated(args: ["touchid", cmd])
            DispatchQueue.main.async {
                touchIDBusy = false
                loadTouchIDStatus()
                if code != 0 {
                    let alert = NSAlert()
                    alert.messageText = "Couldn't update Touch ID for sudo"
                    alert.informativeText = "`mo touchid \(cmd)` didn't complete (the password prompt may have been cancelled). You can also run it in a terminal."
                    alert.runModal()
                }
            }
        }
    }

    // MARK: - Language relaunch

    private func promptRelaunch() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Relaunch to change language?", comment: "")
        alert.informativeText = NSLocalizedString("Burrow needs to relaunch to apply the new language.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Relaunch Now", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Later", comment: ""))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }

    // MARK: - Section + row helpers

    private func section<C: View>(_ title: String, _ glyph: String, @ViewBuilder content: @escaping () -> C) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(text: title, glyph: glyph, color: Brand.textSecondary)
                content()
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(NSLocalizedString(label, comment: "")).font(Brand.sans(12)).foregroundStyle(Brand.textSecondary)
            Spacer()
            Text(value).font(Brand.mono(11)).foregroundStyle(Brand.textPrimary)
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(NSLocalizedString(text, comment: "")).font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Small all-caps section sub-heading (e.g. "TRY ASKING").
    private func subLabel(_ text: String) -> some View {
        Text(text.uppercased()).font(Brand.mono(9, .bold)).tracking(0.6)
            .foregroundStyle(Brand.textTertiary).padding(.top, 2)
    }

    /// One example prompt with a one-click copy button (the text isn't
    /// selectable, so the button is the only way to grab it).
    private func promptRow(_ text: String) -> some View { PromptRow(text: text) }

    private struct PromptRow: View {
        let text: String
        @State private var copied = false
        @State private var hovering = false

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Brand.green).accessibilityHidden(true)
                Text("\u{201C}\(text)\u{201D}").font(Brand.sans(12)).foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(copied ? Brand.green : (hovering ? Brand.textSecondary : Brand.textTertiary))
                }
                .buttonStyle(.plain)
                .help("Copy prompt")
                .accessibilityLabel("Copy prompt")
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
    }

    /// Monospace config block with a one-click copy button.
    private func codeBlock(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(Brand.mono(10)).foregroundStyle(Brand.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copiedConfig = true
                    // Reset the label so a later copy confirms again.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copiedConfig = false }
                } label: {
                    Label(copiedConfig ? "Copied" : "Copy config",
                          systemImage: copiedConfig ? "checkmark" : "doc.on.doc")
                        .font(Brand.mono(10)).foregroundStyle(Brand.green)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Brand.hairline, lineWidth: 1))
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>, onChange: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: isOn) {
            Text(NSLocalizedString(label, comment: "")).font(Brand.sans(12)).foregroundStyle(Brand.textPrimary)
        }
        .toggleStyle(.switch)
        .tint(Brand.green)
        .onChange(of: isOn.wrappedValue) { _, n in onChange(n) }
    }

    /// Trailing-aligned text-field row that persists on every keystroke, so
    /// closing Settings never loses an in-progress edit.
    private func aiField(_ label: String, placeholder: String, text: Binding<String>,
                         onChange: @escaping (String) -> Void) -> some View {
        HStack {
            Text(label).font(Brand.sans(12)).foregroundStyle(Brand.textPrimary)
            Spacer()
            TextField(placeholder, text: text)
                .textFieldStyle(.plain).font(Brand.mono(11))
                .multilineTextAlignment(.trailing).frame(width: 200)
                .onChange(of: text.wrappedValue) { _, v in onChange(v) }
        }
    }

    private func pickerRow(_ label: String, selection: Binding<Int>,
                           options: [(Int, String)], onChange: @escaping (Int) -> Void) -> some View {
        HStack {
            Text(NSLocalizedString(label, comment: "")).font(Brand.sans(12)).foregroundStyle(Brand.textPrimary)
            Spacer()
            Picker("", selection: selection) {
                ForEach(options, id: \.0) { Text(NSLocalizedString($0.1, comment: "")).tag($0.0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(Brand.textSecondary)
            .fixedSize()
            .onChange(of: selection.wrappedValue) { _, n in onChange(n) }
        }
    }

    // MARK: - Status labels

    private func refreshStatusLabels() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
            .appendingPathComponent("Burrow", isDirectory: true)
        var total: Int64 = 0
        if let enumerator = FileManager.default.enumerator(at: support,
                                                           includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in enumerator {
                if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                    total += Int64(size)
                }
            }
        }
        self.dbSizeText = Fmt.bytes(total)

        if let last = AppDelegate.shared?.maintenance?.lastRunAt {
            let delta = Int(Date().timeIntervalSince(last))
            self.lastMaintenanceText = String(format: NSLocalizedString("%ds ago · pruned %d rows", comment: ""),
                                              delta, AppDelegate.shared?.maintenance?.lastPruneDeleted ?? 0)
        } else {
            self.lastMaintenanceText = NSLocalizedString("not yet run", comment: "")
        }
    }
}
