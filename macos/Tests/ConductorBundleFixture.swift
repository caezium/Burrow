//
//  ConductorBundleFixture.swift
//  BurrowTests
//
//  Lets a test say which build it is exercising — one that bundled the `burrow` conductor, or
//  one that didn't — instead of inheriting whichever the test host happened to stage.
//
//  Resources/burrow is produced by the "Bundle burrow (conductor)" phase, which is gated on a
//  populated vendor/burrow-cli checkout. CI never fetches submodules, so it always tested the
//  absent case; a developer who checked the submodule out (required for Network, Orphans and
//  Photos to do anything) always tested the present case and saw unrelated failures.
//

import Foundation
import XCTest

@testable import Burrow

enum ConductorBundleFixture {

    /// Runs `body` with the conductor lookup pointed at a temporary directory, then restores the
    /// real one. `present: false` leaves the directory empty; `present: true` stages an executable
    /// stub named `burrow`.
    ///
    /// The stub is never spawned by these tests — resolution only checks the executable bit — but
    /// it is written as a shell script that emits a valid empty envelope so that a future test
    /// which does run it gets something parseable rather than a crash.
    static func withConductor<T>(present: Bool,
                                 file: StaticString = #filePath, line: UInt = #line,
                                 _ body: () throws -> T) rethrows -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-conductor-fixture-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if present {
            let stub = dir.appendingPathComponent("burrow")
            FileManager.default.createFile(
                atPath: stub.path,
                contents: Data("#!/bin/sh\nprintf '{\"ok\":true,\"data\":{}}'\n".utf8),
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
