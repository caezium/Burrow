//
//  IMessageSidecar.swift
//  Burrow
//
//  Supervises the bundled "Burrow over iMessage" sidecar (a spectrum-ts Bun
//  program). Two jobs: a long-lived AGENT (text your Mac, it answers) kept alive
//  with restart-on-crash, and a periodic CHECK (disk / CPU / weekly digest) run
//  on a timer. Config comes from `Store` and is handed to the sidecar purely via
//  environment variables — the sidecar reads them (BURROW_ALERT_TO, PHOTON_*,
//  BURROW_LLM_*). The alert layer only formats and sends; Burrow does the
//  measuring (the sidecar calls this app's own `--mcp` server, BURROW_BIN).
//
//  Lifecycle mirrors Maintenance/SnapshotProducer: start() from
//  AppDelegate.startServices() (gated on Store.iMessageEnabled), stop() from
//  applicationWillTerminate.
//

import Foundation

/// A snapshot of the user's iMessage settings, passed to the sidecar as env.
struct SidecarConfig: Equatable {
    var ownerPhone: String
    var projectId: String
    var projectSecret: String
    var agentEnabled: Bool
    var llmProvider: String
    var llmModel: String
    var llmBaseURL: String
    var llmKey: String

    static func fromStore() -> SidecarConfig {
        SidecarConfig(
            ownerPhone: Store.iMessageOwnerPhone,
            projectId: Store.iMessageProjectId,
            projectSecret: Store.iMessageProjectSecret,
            agentEnabled: Store.iMessageAgentEnabled,
            llmProvider: Store.iMessageLLMProvider,
            llmModel: Store.iMessageLLMModel,
            llmBaseURL: Store.iMessageLLMBaseURL,
            llmKey: Store.iMessageLLMKey
        )
    }

    var hasDelivery: Bool { !ownerPhone.isEmpty && !projectId.isEmpty && !projectSecret.isEmpty }
}

/// Pure builders for launching the sidecar — no process, no I/O, fully testable.
enum SidecarLaunch {
    /// Environment the sidecar reads. `burrowBin` is this app's own executable,
    /// which the agent's tools reach as the `--mcp` server. `base` seeds from the
    /// current environment (PATH etc.) in production; empty in tests.
    static func environment(_ c: SidecarConfig, burrowBin: String, base: [String: String] = [:]) -> [String: String] {
        var env = base
        env["BURROW_ALERT_TO"] = c.ownerPhone
        if !c.projectId.isEmpty { env["PHOTON_PROJECT_ID"] = c.projectId }
        if !c.projectSecret.isEmpty { env["PHOTON_PROJECT_SECRET"] = c.projectSecret }
        env["BURROW_BIN"] = burrowBin
        // Photon egress is direct; keep any local proxy out of the sidecar.
        env["NO_PROXY"] = "*"; env["no_proxy"] = "*"
        env["LOG_LEVEL"] = "silent"
        if c.agentEnabled {
            env["BURROW_LLM_PROVIDER"] = c.llmProvider
            if !c.llmModel.isEmpty { env["BURROW_LLM_MODEL"] = c.llmModel }
            if !c.llmBaseURL.isEmpty { env["BURROW_LLM_BASEURL"] = c.llmBaseURL }
            if !c.llmKey.isEmpty { env["BURROW_LLM_KEY"] = c.llmKey }
        }
        return env
    }

    static func agentArgs(entry: String) -> [String] { ["run", entry] }
    static func checkArgs(entry: String, digest: Bool = false) -> [String] {
        digest ? ["run", entry, "--digest"] : ["run", entry]
    }
}

/// Resolved on-disk locations of the bundled sidecar.
struct SidecarPaths {
    var dir: URL
    var bun: URL
    var agentEntry: URL
    var checkEntry: URL

    /// `Contents/Resources/sidecar/` with a bundled `bin/bun`, mirroring how the
    /// `mo` engine is bundled under `Resources/engine/`.
    static func bundled(bundle: Bundle = .main) -> SidecarPaths? {
        guard let res = bundle.resourceURL else { return nil }
        let dir = res.appendingPathComponent("sidecar", isDirectory: true)
        let bun = dir.appendingPathComponent("bin/bun")
        guard FileManager.default.isExecutableFile(atPath: bun.path) else { return nil }
        return SidecarPaths(
            dir: dir,
            bun: bun,
            agentEntry: dir.appendingPathComponent("agent.ts"),
            checkEntry: dir.appendingPathComponent("check.ts")
        )
    }
}

final class IMessageSidecar {
    private let queue = DispatchQueue(label: "dev.caezium.Burrow.imessage")
    private var agent: Process?
    private var checkTimer: DispatchSourceTimer?
    private var stopped = false

    private let checkInterval: TimeInterval = 600      // 10 min
    private let restartDelay: TimeInterval = 5

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = false
            let cfg = SidecarConfig.fromStore()
            guard cfg.hasDelivery, let paths = SidecarPaths.bundled() else {
                NSLog("[iMessage] not starting: missing delivery config or bundled sidecar")
                return
            }
            self.armCheckTimer(paths: paths, cfg: cfg)
            if cfg.agentEnabled { self.spawnAgent(paths: paths, cfg: cfg) }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.checkTimer?.cancel(); self.checkTimer = nil
            self.agent?.terminationHandler = nil
            self.agent?.terminate(); self.agent = nil
        }
    }

    // MARK: - internals (on `queue`)

    private func makeProcess(_ paths: SidecarPaths, _ cfg: SidecarConfig, args: [String]) -> Process {
        let p = Process()
        p.executableURL = paths.bun
        p.arguments = args
        p.currentDirectoryURL = paths.dir
        p.environment = SidecarLaunch.environment(cfg, burrowBin: Bundle.main.executableURL?.path ?? "", base: ProcessInfo.processInfo.environment)
        return p
    }

    private func spawnAgent(paths: SidecarPaths, cfg: SidecarConfig) {
        let p = makeProcess(paths, cfg, args: SidecarLaunch.agentArgs(entry: paths.agentEntry.path))
        p.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.asyncAfter(deadline: .now() + self.restartDelay) {
                guard !self.stopped else { return }
                NSLog("[iMessage] agent exited — restarting")
                self.spawnAgent(paths: paths, cfg: cfg)   // restart-on-crash
            }
        }
        do { try p.run(); agent = p } catch { NSLog("[iMessage] agent failed to launch: \(error)") }
    }

    private func armCheckTimer(paths: SidecarPaths, cfg: SidecarConfig) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 60, repeating: checkInterval)   // first tick +60s
        t.setEventHandler { [weak self] in self?.runCheckOnce(paths: paths, cfg: cfg) }
        checkTimer = t
        t.resume()
    }

    private func runCheckOnce(paths: SidecarPaths, cfg: SidecarConfig) {
        let p = makeProcess(paths, cfg, args: SidecarLaunch.checkArgs(entry: paths.checkEntry.path))
        do { try p.run() } catch { NSLog("[iMessage] check failed to launch: \(error)") }
    }
}
