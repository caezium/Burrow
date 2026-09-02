//
//  BrewClient.swift
//  Burrow
//
//  Shared Homebrew invocation seam. The Updates pane already shells `brew`
//  for outdated/upgrade; the Services + Snapshot features reuse the same
//  resolution (known Homebrew prefixes, never a PATH lookup a user-writable
//  dir could shadow) and the same EngineRunner capture path. Pure parsers live
//  alongside their callers and are unit-tested; this is just the spawn seam.
//

import Foundation

enum BrewClient {
    struct Result { let out: String; let err: String; let code: Int32 }

    /// The Homebrew binary, or nil if Homebrew isn't installed.
    static func path() -> String? {
        for p in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    /// Run `brew <args>` with a sane PATH (brew shells out to git etc.), capturing
    /// output. Returns a nonzero code rather than throwing when brew is missing.
    static func run(_ args: [String], timeout: TimeInterval = 120) -> Result {
        guard let brew = path() else { return Result(out: "", err: "brew not found", code: -1) }
        var env = Foundation.ProcessInfo.processInfo.environment
        let dir = (brew as NSString).deletingLastPathComponent
        env["PATH"] = "\(dir):/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        do {
            let r = try EngineRunner.shared.capture(
                MoCommand(target: .executable(brew), args: args, environment: env, timeout: timeout))
            return Result(out: r.stdout, err: r.stderr, code: r.exitCode)
        } catch {
            return Result(out: "", err: "\(error)", code: -1)
        }
    }

    static var isInstalled: Bool { path() != nil }
}
