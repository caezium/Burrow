//
//  SoftwareModelTests.swift
//  BurrowTests
//
//  `SoftwareModel.previewSource` is the one safety-critical decision behind the per-app leftover
//  preview (design 2.2, post-repoint fix): whether to ask the bundled engine for a bundle id, ask
//  a real legacy `mo`/MIT-fork binary for a display name, or refuse outright. Getting this wrong
//  in the "ask the engine" direction is dangerous, not just unhelpful — see the empty-bundle-id
//  case below, verified against the real engine binary's actual argument parsing (RULEBOOK-style
//  fixture, not a guess): `burrow-engine uninstall --dry-run ""` still matches the empty string
//  as the positional bundle id and reports whole PARENT directories
//  (~/Library/Caches, ~/Library/Containers, …) as if they were one app's leftovers.
//

import XCTest
@testable import Burrow

final class SoftwareModelTests: XCTestCase {
    private func app(bundleId: String, uninstallName: String = "Display Name") -> InstalledApp {
        InstalledApp(id: "x", name: "App", bundleId: bundleId, source: "App",
                     uninstallName: uninstallName, path: "/Applications/App.app",
                     sizeStr: "1MB", sizeBytes: 1_000_000, lastUsed: nil)
    }

    func testPreviewSource_bundledEngineWithBundleId_asksTheEngineForTheBundleId() {
        let a = app(bundleId: "com.tinyspeck.slackmacgap", uninstallName: "Slack")
        XCTAssertEqual(SoftwareModel.previewSource(for: a, resolvedIsBundledEngine: true),
                       .engine(bundleId: "com.tinyspeck.slackmacgap"))
    }

    /// The dangerous case. An empty bundle id must NOT be sent to the engine — confirmed against
    /// the real binary that `args.iter().find(|a| !a.starts_with("--"))` still matches an empty
    /// string as the positional bundle id, which turns into `leftover_paths(home, "")` and
    /// reports the entire `~/Library/Caches`, `~/Library/Containers`, etc as "this app's
    /// leftovers". Refusing outright is the only safe move; a preview that confidently shows the
    /// wrong app's leftovers is worse than one that shows nothing.
    func testPreviewSource_bundledEngineWithEmptyBundleId_refusesRatherThanGuess() {
        let a = app(bundleId: "")
        XCTAssertEqual(SoftwareModel.previewSource(for: a, resolvedIsBundledEngine: true), .unavailable)
    }

    /// A real legacy `mo`/MIT-fork binary resolved instead — unchanged pre-fix behavior: send the
    /// display name, regardless of whether a bundle id also happens to be known. The engine-only
    /// special-casing must never leak into this branch.
    func testPreviewSource_legacyMo_sendsDisplayNameEvenWhenABundleIdIsKnown() {
        let a = app(bundleId: "com.tinyspeck.slackmacgap", uninstallName: "Slack")
        XCTAssertEqual(SoftwareModel.previewSource(for: a, resolvedIsBundledEngine: false),
                       .legacy(name: "Slack"))
    }

    func testPreviewSource_legacyMo_emptyBundleIdStillSendsDisplayName() {
        // The empty-bundle-id refusal is an ENGINE-ONLY guard — a real legacy mo never reads
        // bundleId at all, so its absence must not affect this branch.
        let a = app(bundleId: "", uninstallName: "Slack")
        XCTAssertEqual(SoftwareModel.previewSource(for: a, resolvedIsBundledEngine: false),
                       .legacy(name: "Slack"))
    }
}
