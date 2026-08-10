//
//  GitSweep.swift
//  Burrow
//
//  Purge-safety git runner (roadmap C.11): find the repo containing a purge
//  candidate and ask `git status` whether deleting it would lose work. The
//  parse + verdict live in GitRepoStatus (tested); this is the filesystem
//  walk-up (testable) and the bounded subprocess. Badging the purge checklist
//  is the GUI integration.
//

import Foundation
import os

enum GitSweep {
    /// Walk up from `path` to the nearest directory containing a `.git`.
    static func repoRoot(for path: String) -> String? {
        var url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        for _ in 0..<64 {
            if fm.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return nil
    }

    /// `git -C <repo> status --porcelain=v1 -b`, bounded by `timeout`, parsed
    /// into a verdict. nil when git is unavailable, times out, or errors.
    ///
    /// Both halves of "wait for the child" here used to be able to never come
    /// back, and on this path a nil is not a neutral outcome: it means "no
    /// warning", so a wait that doesn't return is a purge-safety check failing
    /// open on a repo that may hold uncommitted work.
    ///
    /// THE EXIT STATUS no longer goes through `waitUntilExit()`. That call used
    /// to run here on a global-queue worker with the caller parked on a
    /// semaphore, and measured on macOS 26.5 it never returned in 22 of 300
    /// runs — against a child that had already exited and been reaped
    /// (`isRunning == false` at the deadline), which is the same Foundation
    /// wedge that hung a CI job for 29 minutes (see the long note on
    /// `SystemProcessPort`). It is taken instead where Foundation hands it over,
    /// in a terminationHandler installed BEFORE run() — one installed after
    /// races the exit it wants to hear about — and the deadline waits on that.
    /// The old worker also leaked: every wedged wait parked a global-queue
    /// thread that never came back.
    ///
    /// THE OUTPUT is drained concurrently rather than after the wait. `git
    /// status --porcelain` on a repo with a few thousand dirty or untracked
    /// entries runs well past the ~64KB pipe buffer, and a child blocked
    /// writing into a pipe nobody is reading never exits at all: 67 of 67 runs
    /// against a 160KB child hit the deadline with the child still alive, so
    /// the badge was guaranteed to stay silent on exactly the messiest repos.
    static func status(repo: String, timeout: TimeInterval = 3) -> GitRepoStatus.Status? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", repo, "status", "--porcelain=v1", "-b"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()

        let exited = DispatchSemaphore(value: 0)
        let status = OSAllocatedUnfairLock<Int32?>(initialState: nil)
        p.terminationHandler = { proc in
            status.withLock { $0 = proc.terminationStatus }
            exited.signal()
        }
        do { try p.run() } catch { return nil }

        // Started only after a successful spawn, so a failed launch can't leave
        // a reader parked on a pipe that will never see a writer.
        var data = Data()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue(label: "dev.caezium.burrow.gitsweep").async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }

        // One deadline for the whole run, so `timeout` still means what it says.
        let deadline = DispatchTime.now() + timeout
        guard exited.wait(timeout: deadline) == .success else { p.terminate(); return nil }
        guard status.withLock({ $0 }) == 0 else { return nil }
        // `data` belongs to the reader until it leaves the group, so a drain
        // that hasn't finished must not be read at all rather than parsed
        // half-written. The child has exited by here, so this is EOF away.
        // No terminate() on this branch, unlike the one above: the child has
        // already been reaped, and its pid could belong to someone else by now.
        guard drained.wait(timeout: deadline) == .success else { return nil }
        return GitRepoStatus.parse(String(decoding: data, as: UTF8.self))
    }
}
