//
//  MoleCLITests.swift
//  BurrowTests
//
//  parseVersion is the only pure piece of the Mole-engine lifecycle
//  (install/version/update); the rest spawns `mo`. It must pull a semver
//  out of whatever `mo --version` decorates it with.
//

import XCTest
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
        let s = MoleCLI.elevatedScript(executable: "/tmp/m o/mo", args: ["clean", "--dry-run"])
        XCTAssertTrue(s.hasPrefix("do shell script \""))
        XCTAssertTrue(s.hasSuffix("\" with administrator privileges"))
        XCTAssertTrue(s.contains("'/tmp/m o/mo' 'clean' '--dry-run'"))
    }

    func testElevatedScript_neutralizesShellMetacharacters() {
        let s = MoleCLI.elevatedScript(executable: "/tmp/$(reboot)/mo", args: ["a;b", "`x`"])
        XCTAssertTrue(s.contains("'/tmp/$(reboot)/mo' 'a;b' '`x`'"),
                      "metacharacters must ride inert inside single quotes")
    }

    func testElevatedScript_escapesAppleScriptLiteralBreakers() {
        // A double quote in a path must not terminate the AppleScript string.
        let s = MoleCLI.elevatedScript(executable: #"/tmp/he said "hi"/mo"#, args: [])
        XCTAssertFalse(s.contains(#"said "hi""#), "raw quote would break out of the literal")
        XCTAssertTrue(s.contains(#"said \"hi\""#))
        // A single quote goes through the shell's '\'' dance, whose
        // backslash must itself be AppleScript-escaped.
        let s2 = MoleCLI.elevatedScript(executable: "/tmp/a'b/mo", args: [])
        XCTAssertTrue(s2.contains(#"'/tmp/a'\\''b/mo'"#))
    }

    func testElevatedScript_redirectsThroughQuotedLogPath() {
        let s = MoleCLI.elevatedScript(executable: "/usr/local/bin/mo", args: ["clean"],
                                       redirectTo: "/tmp/my log.txt")
        XCTAssertTrue(s.contains("> '/tmp/my log.txt' 2>&1"))
    }

    func testTrustedExecutable_onlyEverReturnsKnownLocations() {
        if let p = MoleCLI.trustedExecutable() {
            XCTAssertTrue(["/opt/homebrew/bin/mo", "/usr/local/bin/mo", "/usr/bin/mo"].contains(p),
                          "trusted lookup must never come from PATH")
        }
        // nil (mo not installed in a trusted spot) is also a valid outcome.
    }

    func testRun_timesOutInsteadOfHanging() throws {
        let start = Date()
        let r = try MoleCLI.run(args: ["5"], executable: "/bin/sleep", timeout: 0.4)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 3.0, "the 5s sleep must be killed by the 0.4s timeout")
        XCTAssertNotEqual(r.exitCode, 0, "a terminated process is non-zero")
    }
}
