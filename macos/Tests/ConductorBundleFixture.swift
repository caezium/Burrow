//
//  ConductorBundleFixture.swift
//  BurrowTests
//
//  Lets a test say which build it is exercising — one that bundled the `burrow` conductor, or
//  one that didn't — instead of inheriting whichever the test host happened to stage.
//
//  Resources/burrow is produced by the "Bundle burrow-engine (MIT)" phase, which is gated on a
//  populated vendor/burrow-engine checkout. CI never fetches submodules, so it always tested the
//  absent case; a developer who checked the submodule out (required for Network, Orphans and
//  Photos to do anything) always tested the present case and saw unrelated failures.
//

import Foundation
import XCTest

@testable import Burrow

enum ConductorBundleFixture {

    /// A valid, empty success envelope.
    static let defaultStub = #"printf '{"ok":true,"burrow_cli":"0.1.0","data":{}}'"#

    /// A success envelope whose `data.argv` is the exact argv the app spawned the engine with,
    /// space-joined — the way a test proves WHAT was sent, not merely that something was.
    static let argvEchoStub = #"printf '{"ok":true,"burrow_cli":"0.1.0","data":{"argv":"%s"}}' "$*""#

    /// A stub that records that it ran at all by creating `marker`, then answers with the empty
    /// envelope. A test asserting "nothing was spawned" checks the marker is still absent.
    static func footprintStub(marker: URL) -> String {
        "touch '\(marker.path)'\n" + defaultStub
    }

    /// Runs `body` with the `BurrowStreamViaConductor` kill-switch in a chosen state — `nil` is
    /// "unset", the shipped default — and puts everything back afterwards.
    ///
    /// The switch is read through `Store.d`, so this points `Store.d` at the shared scratch suite
    /// (the same one `StoreTests` uses) for the duration and restores the previous defaults
    /// object on exit. Nothing here touches `UserDefaults.standard`: the test bundle is hosted
    /// inside the real app, so `.standard` IS the developer's live domain, and a suite that wrote
    /// there could erase a kill-switch they had genuinely set — or, on a bare CI runner, leave a
    /// preference behind. Either way it is the opposite of hermetic.
    static func withStreamSwitch<T>(_ value: Bool?, _ body: () throws -> T) rethrows -> T {
        let saved = Store.d
        let scratch = UserDefaults(suiteName: StoreTests.scratchSuite)!
        scratch.removePersistentDomain(forName: StoreTests.scratchSuite)
        Store.d = scratch
        defer {
            scratch.removePersistentDomain(forName: StoreTests.scratchSuite)
            Store.d = saved
        }
        if let value { scratch.set(value, forKey: BurrowConductor.streamingKey) }
        return try body()
    }

    /// Runs `body` with the conductor lookup pointed at a temporary directory, then restores the
    /// real one. `present: false` leaves the directory empty; `present: true` stages an executable
    /// stub named `burrow`.
    ///
    /// The default stub is a shell script that emits a valid empty envelope, so a test that only
    /// checks resolution gets something parseable if it ever does spawn it. A test that WANTS
    /// to observe the spawn passes its own `stub` body (`sh` syntax; `$@` is the argv the app
    /// built) — the two canned ones below cover "echo the argv back" and "leave a footprint".
    static func withConductor<T>(present: Bool,
                                 stub: String = defaultStub,
                                 file: StaticString = #filePath, line: UInt = #line,
                                 _ body: () throws -> T) rethrows -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-conductor-fixture-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if present {
            let stubURL = dir.appendingPathComponent("burrow")
            FileManager.default.createFile(
                atPath: stubURL.path,
                contents: Data(("#!/bin/sh\n" + stub + "\n").utf8),
                attributes: [.posixPermissions: 0o755])
        }

        let saved = BurrowConductor.resourceDirectory
        BurrowConductor.resourceDirectory = { dir }
        defer {
            BurrowConductor.resourceDirectory = saved
            try? FileManager.default.removeItem(at: dir)
        }

        XCTAssertEqual(BurrowConductor.isAvailable, present,
                       "fixture failed to put the conductor lookup in the requested state",
                       file: file, line: line)
        return try body()
    }
}
