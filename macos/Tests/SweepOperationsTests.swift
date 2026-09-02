//
//  SweepOperationsTests.swift
//  BurrowTests
//
//  Purge and Installers on OperationFlow: the argv each run spawns, streamed where the engine
//  streams (`purge --stream`) and buffered where it doesn't (`installer`), through the same
//  reducer either way.
//

import XCTest
@testable import Burrow

@MainActor
final class SweepOperationsTests: XCTestCase {

    private func settle<R>(_ flow: OperationFlow<R>) async {
        for _ in 0..<1000 {
            if case .finished = flow.state { return }
            await Task.yield()
        }
    }

    func testPurge_previewAndApplyStreamThroughTheEngine() async throws {
        let preview = OperationFlowTests.FakeProcessPort(script: [
            .line(#"{"event":"would_remove","path":"/Users/h/proj/node_modules","bytes":1024}"#),
            .line(#"{"event":"would_remove","path":"/Users/h/proj/target","bytes":2048}"#),
            .line(#"{"event":"done","dry_run":true,"would_free_bytes":3072,"would_free_human":"3.0KB","count":2}"#),
            .exited(0),
        ])
        let dry = OperationFlow<CleanDryReport>(process: preview, hasFullDiskAccess: { true },
                                                resolveEngine: { _ in "/fake/burrow" }, center: OperationCenter())
        ConductorBundleFixture.withStreamSwitch(true) {
            ConductorBundleFixture.withConductor(present: true) {
                dry.start(SweepOperations.preview(.purge))
            }
        }
        await settle(dry)
        XCTAssertEqual(preview.specs.first?.arguments, ["purge", "--stream"], "the engine's preview, streamed")
        XCTAssertEqual(preview.specs.first?.elevated, false)
        XCTAssertEqual(dry.report?.liveBytes, 3072, "bytes count up from the would_remove lines")
        XCTAssertEqual(dry.report?.groups.first?.title, "Purge")
        XCTAssertEqual(dry.report?.groups.first?.items.map(\.text),
                       ["/Users/h/proj/node_modules", "/Users/h/proj/target"])
        XCTAssertEqual(dry.report?.summary?.completionLine, "Cleaned 3.0KB · 2 items")

        let apply = OperationFlowTests.FakeProcessPort(script: [
            .line(#"{"event":"removed","path":"/Users/h/proj/node_modules","bytes":1024}"#),
            .line(#"{"event":"done","freed_bytes":0,"freed_human":"0B","moved_to_trash_bytes":1024,"moved_to_trash_human":"1.0KB","removed":1,"failed":0,"protected":0}"#),
            .exited(0),
        ])
        let real = OperationFlow<TaskRunReport>(process: apply, hasFullDiskAccess: { true },
                                                resolveEngine: { _ in "/fake/burrow" }, center: OperationCenter())
        ConductorBundleFixture.withStreamSwitch(true) {
            ConductorBundleFixture.withConductor(present: true) {
                real.start(SweepOperations.apply(.purge))
            }
        }
        await settle(real)
        XCTAssertEqual(apply.specs.first?.arguments, ["purge", "--apply", "--stream"])
        XCTAssertEqual(apply.specs.first?.elevated, false, "project trees are the user's own")
        XCTAssertEqual(real.report?.summary?.completionLine, "1.0KB moved to Trash · 1 items",
                       "the engine's default is the Trash, and the summary says so")
    }

    /// The engine has no `installer --stream`; the run is buffered and its one envelope line is
    /// reduced to the same report.
    func testInstaller_runsBufferedAndReducesTheEnvelope() async throws {
        EngineCLI.bundledExecutableOverride = "/fake/bundled/burrow"
        defer { EngineCLI.bundledExecutableOverride = nil }
        let preview = OperationFlowTests.FakeProcessPort(script: [
            .line(#"{"ok":true,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"installer","data":{"dry_run":true,"installers":[{"path":"/Users/h/Downloads/App.dmg","size_bytes":4096,"source":"Downloads"}],"count":1,"total_bytes":4096}}"#),
            .exited(0),
        ])
        let dry = OperationFlow<CleanDryReport>(process: preview, hasFullDiskAccess: { true },
                                                resolveEngine: { _ in "/fake/bundled/burrow" }, center: OperationCenter())
        ConductorBundleFixture.withStreamSwitch(true) {
            ConductorBundleFixture.withConductor(present: true) {
                dry.start(SweepOperations.preview(.installer))
            }
        }
        await settle(dry)
        XCTAssertEqual(preview.specs.first?.arguments, ["installer"], "the engine's default IS the preview; no --stream exists")
        XCTAssertEqual(dry.report?.groups.first?.items.map(\.text), ["/Users/h/Downloads/App.dmg"])
        XCTAssertEqual(dry.report?.summary?.space, "4.00 KB")
        XCTAssertEqual(dry.report?.summary?.items, "1")

        let apply = OperationFlowTests.FakeProcessPort(script: [
            .line(#"{"ok":true,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"installer","data":{"dry_run":false,"freed_bytes":0,"moved_to_trash_bytes":4096,"removed":[{"path":"/Users/h/Downloads/App.dmg","size_bytes":4096,"source":"Downloads"}],"errors":[],"protected":[],"text":"…"}}"#),
            .exited(0),
        ])
        let real = OperationFlow<TaskRunReport>(process: apply, hasFullDiskAccess: { true },
                                                resolveEngine: { _ in "/fake/bundled/burrow" }, center: OperationCenter())
        ConductorBundleFixture.withStreamSwitch(true) {
            ConductorBundleFixture.withConductor(present: true) {
                real.start(SweepOperations.apply(.installer))
            }
        }
        await settle(real)
        XCTAssertEqual(apply.specs.first?.arguments, ["installer", "--apply"])
        XCTAssertEqual(real.report?.groups.first?.items.map(\.marker), [.ok])
        XCTAssertEqual(real.report?.summary?.completionLine, "4.00 KB moved to Trash · 1 items")
    }
}
