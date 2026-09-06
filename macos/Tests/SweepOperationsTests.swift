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

    private func fixturePlan(_ name: String) throws -> (URL, CleanupExecutionPlan, URL) {
        let rawRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: rawRoot, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: try XCTUnwrap(InvokingUserIdentity.canonicalPath(rawRoot.path)))
        let file = root.appendingPathComponent(name)
        try Data("reviewed".utf8).write(to: file)
        let list = CleanList(categories: [.init(name: "Review", items: [
            .init(path: file.path, sizeBytes: 8, sizeText: "8B", itemCount: nil)
        ])], summaryTotalText: nil, summaryItemCount: 1)
        let snapshot = try SweepOperations.captureReview(list)
        let plan = try snapshot.plan(selectedPaths: [file.path])
        // Store the plan beside the fixture root so writing it does not mutate a pinned parent.
        let planFile = try plan.writePlanFile(in: root.deletingLastPathComponent())
        return (root, plan, planFile)
    }

    func testReviewRetainsExactCandidatesAndRejectsLaterMutation() throws {
        let (root, plan, planFile) = try fixturePlan("reviewed.dmg")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: planFile) }
        XCTAssertEqual(try String(contentsOf: planFile, encoding: .utf8).split(separator: "\n").filter { !$0.hasPrefix("#") }.map(String.init),
                       [root.appendingPathComponent("reviewed.dmg").path])
        XCTAssertTrue(plan.validateForLaunch())
        try Data("later".utf8).write(to: root.appendingPathComponent("new.dmg"))
        XCTAssertTrue(plan.validateForLaunch(), "A new unlisted sibling does not expand the plan")
        try FileManager.default.moveItem(at: root.appendingPathComponent("reviewed.dmg"), to: root.appendingPathComponent("original.dmg"))
        try Data("replacement".utf8).write(to: root.appendingPathComponent("reviewed.dmg"))
        XCTAssertFalse(plan.validateForLaunch(), "Replacing a reviewed item requires a rescan")
        XCTAssertFalse(try String(contentsOf: planFile, encoding: .utf8).contains("new.dmg"))
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

        let (fixtureRoot, plan, planFile) = try fixturePlan("reviewed.dmg")
        defer { try? FileManager.default.removeItem(at: fixtureRoot); try? FileManager.default.removeItem(at: planFile) }
        let apply = OperationFlowTests.FakeProcessPort(script: [
            .line(#"{"event":"removed","path":"/Users/h/proj/node_modules","bytes":1024}"#),
            .line(#"{"event":"done","freed_bytes":0,"freed_human":"0B","moved_to_trash_bytes":1024,"moved_to_trash_human":"1.0KB","removed":1,"failed":0,"protected":0}"#),
            .exited(0),
        ])
        let real = OperationFlow<TaskRunReport>(process: apply, hasFullDiskAccess: { true },
                                                resolveEngine: { _ in "/fake/burrow" }, center: OperationCenter())
        ConductorBundleFixture.withStreamSwitch(true) {
            ConductorBundleFixture.withConductor(present: true) {
                real.start(SweepOperations.apply(.purge, plan: plan, planFile: planFile))
            }
        }
        await settle(real)
        XCTAssertEqual(apply.specs.first?.arguments, ["purge", "--plan", planFile.path, "--apply", "--stream"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: planFile.path))
        XCTAssertEqual(apply.specs.first?.cleanupPlan?.items.count, 1)
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

        let (fixtureRoot, plan, planFile) = try fixturePlan("reviewed.dmg")
        defer { try? FileManager.default.removeItem(at: fixtureRoot); try? FileManager.default.removeItem(at: planFile) }
        let apply = OperationFlowTests.FakeProcessPort(script: [
            .line(#"{"ok":true,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"installer","data":{"dry_run":false,"freed_bytes":0,"moved_to_trash_bytes":4096,"removed":[{"path":"/Users/h/Downloads/App.dmg","size_bytes":4096,"source":"Downloads"}],"errors":[],"protected":[],"text":"…"}}"#),
            .exited(0),
        ])
        let real = OperationFlow<TaskRunReport>(process: apply, hasFullDiskAccess: { true },
                                                resolveEngine: { _ in "/fake/bundled/burrow" }, center: OperationCenter())
        ConductorBundleFixture.withStreamSwitch(true) {
            ConductorBundleFixture.withConductor(present: true) {
                real.start(SweepOperations.apply(.installer, plan: plan, planFile: planFile))
            }
        }
        await settle(real)
        XCTAssertEqual(apply.specs.first?.arguments, ["installer", "--plan", planFile.path, "--apply"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: planFile.path))
        XCTAssertEqual(dry.report?.list?.categories.flatMap(\.items).map(\.path), ["/Users/h/Downloads/App.dmg"])
        XCTAssertEqual(real.report?.groups.first?.items.map(\.marker), [.ok])
        XCTAssertEqual(real.report?.summary?.completionLine, "4.00 KB moved to Trash · 1 items")
    }
}
