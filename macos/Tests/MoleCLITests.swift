//
//  MoleCLITests.swift
//  BurrowTests
//
//  parseVersion is the only pure piece of the Mole-engine lifecycle
//  (install/version/update); the rest spawns `mo`. It must pull a semver
//  out of whatever `mo --version` decorates it with.
//

import XCTest
import Darwin
@testable import Burrow

final class MoleCLITests: XCTestCase {
    func testParseVersion_extractsSemverFromDecoratedOutput() {
        XCTAssertEqual(MoleCLI.parseVersion("mole 1.41.0"), "1.41.0")
        XCTAssertEqual(MoleCLI.parseVersion("v1.41.0\n"), "1.41.0")
        XCTAssertEqual(MoleCLI.parseVersion("mole version 2.0.10 (build 7)"), "2.0.10")
    }

    func testParseVersion_nilWhenNoVersion() {
        XCTAssertNil(MoleCLI.parseVersion("no version here"))
        XCTAssertNil(MoleCLI.parseVersion(""))
    }

    func testParseVersion_ignoresLoneNumbers() {
        // A bare integer isn't a version; needs at least major.minor.
        XCTAssertNil(MoleCLI.parseVersion("built for macOS 14"))
    }

    func testEngineUpdatePolicy_keepsSignedBundleImmutable() {
        let bundled = "/Applications/Burrow.app/Contents/Resources/engine/mole"
        XCTAssertEqual(
            MoleCLI.engineUpdatePolicy(executable: bundled, bundledExecutable: bundled),
            .bundledWithApp
        )
        XCTAssertEqual(
            MoleCLI.engineUpdatePolicy(executable: "/opt/homebrew/bin/mo", bundledExecutable: nil),
            .external
        )
        XCTAssertEqual(
            MoleCLI.engineUpdatePolicy(executable: nil, bundledExecutable: nil),
            .unavailable
        )
        XCTAssertEqual(
            MoleCLI.engineUpdateInstruction(for: .bundledWithApp),
            "Update Burrow to get the current bundled engine."
        )
        XCTAssertEqual(
            MoleCLI.engineUpdateInstruction(for: .external),
            "Use Settings › Engine › Update external engine, then try again."
        )
        XCTAssertEqual(
            MoleCLI.engineUpdateInstruction(for: .unavailable),
            "Reinstall Burrow to restore the bundled engine."
        )
    }

    // MARK: - Capture runner (MoleCLI.run)
    //
    // The subprocess boundary is exercised with real tiny system binaries
    // (echo / cat / false / sleep) rather than a mock — the local-substitutable
    // way to test a process runner: actual plumbing, deterministic, fast.

    func testRun_capturesStdoutAndExitZero() throws {
        let r = try MoleCLI.run(args: ["hello world"], executable: "/bin/echo")
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertEqual(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello world")
    }

    func testRun_feedsStdinToChild() throws {
        // `cat` echoes whatever it reads on stdin — proves the stdin feed lands.
        let r = try MoleCLI.run(args: [], executable: "/bin/cat", stdin: "piped input\n")
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertTrue(r.stdout.contains("piped input"))
    }

    func testRun_reportsNonZeroExit() throws {
        let r = try MoleCLI.run(args: [], executable: "/usr/bin/false")
        XCTAssertNotEqual(r.exitCode, 0)
    }

    // Audit H1: `mo analyze --json` and `uninstall --list` emit far more
    // than the ~64 KB kernel pipe buffer. The runner must keep draining
    // while the child writes — otherwise the child blocks in write(2), the
    // parent blocks in waitUntilExit, and the only way out is the timeout
    // killer plus a truncated capture.
    func testRun_capturesOutputLargerThanPipeBuffer() throws {
        let size = 512 * 1024
        let big = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-bigout-\(UUID().uuidString).txt")
        try String(repeating: "x", count: size).write(to: big, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: big) }

        let start = Date()
        let r = try MoleCLI.run(args: [big.path], executable: "/bin/cat", timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4.0,
                          "large output must stream out, not stall until the timeout killer")
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertEqual(r.stdout.count, size, "the whole output must be captured, not one pipe-buffer's worth")
    }

    // MARK: - Elevated script builder (audit M3)
    //
    // The string handed to `do shell script … with administrator privileges`
    // runs as ROOT. Two escaping layers must both hold: single-quoting for
    // the shell, then backslash/quote escaping for the AppleScript literal.

    func testElevatedScript_shellQuotesEveryArgument() {
        let s = MoleCLI.elevatedScript(command: fakeCommand("/tmp/m o/mo"),
                                       args: ["clean", "--dry-run"])
        XCTAssertTrue(s.hasPrefix("do shell script \""))
        XCTAssertTrue(s.hasSuffix("\" with administrator privileges"))
        XCTAssertTrue(s.contains("'/tmp/m o/mo' 'clean' '--dry-run'"))
    }

    func testElevatedScript_neutralizesShellMetacharacters() {
        let s = MoleCLI.elevatedScript(command: fakeCommand("/tmp/$(reboot)/mo"),
                                       args: ["a;b", "`x`"])
        XCTAssertTrue(s.contains("'/tmp/$(reboot)/mo' 'a;b' '`x`'"),
                      "metacharacters must ride inert inside single quotes")
    }

    func testElevatedScript_escapesAppleScriptLiteralBreakers() {
        // A double quote in a path must not terminate the AppleScript string.
        let s = MoleCLI.elevatedScript(command: fakeCommand(#"/tmp/he said "hi"/mo"#), args: [])
        XCTAssertFalse(s.contains(#"said "hi""#), "raw quote would break out of the literal")
        XCTAssertTrue(s.contains(#"said \"hi\""#))
        // A single quote goes through the shell's '\'' dance, whose
        // backslash must itself be AppleScript-escaped.
        let s2 = MoleCLI.elevatedScript(command: fakeCommand("/tmp/a'b/mo"), args: [])
        XCTAssertTrue(s2.contains(#"'/tmp/a'\\''b/mo'"#))
    }

    func testElevatedScript_redirectsThroughQuotedLogPath() {
        let sink = try! PrivilegedLogSink.make(token: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        let s = MoleCLI.elevatedScript(command: fakeCommand("/usr/local/bin/mo"), args: ["clean"],
                                       logSink: sink)
        XCTAssertTrue(s.contains("> '\(sink.filePath)' 2>&1"))
    }

    /// Elevation may execute only the engine sealed inside Burrow.app.
    /// Homebrew prefixes and PATH entries are mutable by the invoking user.
    func testTrustedExecutable_onlyEverReturnsKnownLocations() {
        if let p = MoleCLI.trustedExecutable() {
            XCTAssertEqual(p, MoleCLI.bundledExecutable(),
                           "elevation must never use a Homebrew/user-mutable engine")
        }
    }

    private func fakeCommand(_ path: String) -> ValidatedElevatedCommand {
        let identity = PinnedFileIdentity(path: path, device: 1, inode: 2,
                                          owner: 0, mode: UInt16(S_IFREG | 0o755))
        let user = InvokingUserIdentity(uid: 501, username: "test",
                                        canonicalHome: "/Users/test")
        return ValidatedElevatedCommand(executable: identity, components: [],
                                        invokingUser: user, signedBundlePath: nil)
    }

    func testRun_timesOutInsteadOfHanging() throws {
        let start = Date()
        let r = try MoleCLI.run(args: ["5"], executable: "/bin/sleep", timeout: 0.4)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 3.0, "the 5s sleep must be killed by the 0.4s timeout")
        XCTAssertNotEqual(r.exitCode, 0, "a terminated process is non-zero")
    }

    // MARK: - Discovery caching + revalidation (issue #48)
    //
    // GUI call sites hit findExecutable() on every sampler tick and tool
    // run; without a cache each call re-stats 3 paths and may shell out to
    // `which`. The cache must REVALIDATE (a deleted binary can't keep
    // being returned) and must not cache negatives (the user installs mo
    // mid-session and the installer view rechecks).

    private var fakeMo: URL!

    private func makeFakeMo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-disco-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let exe = dir.appendingPathComponent("mo")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: exe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        return exe
    }

    override func tearDown() {
        MoleCLI.discoveryCandidates = nil
        MoleCLI.resetDiscoveryCache()
        if let fakeMo { try? FileManager.default.removeItem(at: fakeMo.deletingLastPathComponent()) }
        super.tearDown()
    }

    func testFindExecutable_cachesAPositiveHit() throws {
        fakeMo = try makeFakeMo()
        MoleCLI.discoveryCandidates = [fakeMo.path]
        MoleCLI.resetDiscoveryCache()

        XCTAssertEqual(MoleCLI.findExecutable(), fakeMo.path)
        // Point discovery somewhere else: a cached (still-valid) hit must
        // win without re-walking the candidate list.
        MoleCLI.discoveryCandidates = ["/nonexistent/mo"]
        XCTAssertEqual(MoleCLI.findExecutable(), fakeMo.path, "valid cache hit skips re-discovery")
    }

    func testFindExecutable_revalidatesAndDropsAStaleHit() throws {
        fakeMo = try makeFakeMo()
        MoleCLI.discoveryCandidates = [fakeMo.path]
        MoleCLI.resetDiscoveryCache()
        XCTAssertEqual(MoleCLI.findExecutable(), fakeMo.path)

        try FileManager.default.removeItem(at: fakeMo)
        XCTAssertNil(MoleCLI.findExecutable(),
                     "a vanished binary must not keep being served from the cache")
    }

    func testFindExecutable_neverCachesAMiss() throws {
        MoleCLI.discoveryCandidates = ["/nonexistent/mo"]
        MoleCLI.resetDiscoveryCache()
        XCTAssertNil(MoleCLI.findExecutable())

        // mo gets installed mid-session → the next lookup must see it.
        fakeMo = try makeFakeMo()
        MoleCLI.discoveryCandidates = [fakeMo.path]
        XCTAssertEqual(MoleCLI.findExecutable(), fakeMo.path)
    }
}
