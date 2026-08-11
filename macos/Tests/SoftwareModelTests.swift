//
//  SoftwareModelTests.swift
//  BurrowTests
//
//  Two classes, two subjects. `SoftwareModelTests` covers the model's load/refresh
//  concurrency — which inventory wins when two loads overlap. `SoftwareUninstallModelTests`
//  covers the uninstall surface: which identifier reaches the engine's argv, and what the
//  confirmation sheet promises about it.
//

import XCTest
@testable import Burrow

@MainActor
final class SoftwareModelTests: XCTestCase {
    func testNewestLoadWinsWhenAnOlderLoadFinishesLast() async {
        let firstStarted = expectation(description: "first load started")
        let releaseFirst = DispatchSemaphore(value: 0)
        let calls = LockedCounter()
        let older = app(id: "same", name: "Older", path: "/Applications/Older.app")
        let newer = app(id: "same", name: "Newer", path: "/Applications/Newer.app")
        let model = SoftwareModel(loadApps: {
            if calls.next() == 1 {
                firstStarted.fulfill()
                releaseFirst.wait()
                return [older]
            }
            return [newer]
        })

        model.load()
        await fulfillment(of: [firstStarted], timeout: 1)
        model.load()
        await eventually { model.apps == [newer] && !model.loading }

        releaseFirst.signal()
        await settle()

        XCTAssertEqual(model.apps, [newer])
        XCTAssertFalse(model.loading)
    }

    func testRecentDatesMergeOntoCurrentMetadataByStableIdentity() async {
        let dateStarted = expectation(description: "date pass started")
        let releaseDate = DispatchSemaphore(value: 0)
        let date = Date(timeIntervalSince1970: 123)
        let model = SoftwareModel(lastUsedDate: { _ in
            dateStarted.fulfill()
            releaseDate.wait()
            return date
        })
        model.apps = [app(id: "stable", name: "Before", path: "/Applications/App.app")]

        model.setSort(.recent)
        await fulfillment(of: [dateStarted], timeout: 1)
        model.apps = [app(id: "stable", name: "After", path: "/Applications/App.app", size: 42)]
        releaseDate.signal()
        await eventually { model.apps.first?.lastUsed == date }

        XCTAssertEqual(model.apps.first?.name, "After")
        XCTAssertEqual(model.apps.first?.sizeBytes, 42)
    }

    func testRecentPassFromAnOlderInventoryCannotOverwriteTheNewestLoad() async {
        let oldDateStarted = expectation(description: "old date pass started")
        let releaseOldDate = DispatchSemaphore(value: 0)
        let calls = LockedCounter()
        let old = app(id: "old", name: "Old", path: "/Applications/Old.app")
        let fresh = app(id: "fresh", name: "Fresh", path: "/Applications/Fresh.app")
        let freshDate = Date(timeIntervalSince1970: 456)
        let model = SoftwareModel(
            loadApps: { calls.next() == 1 ? [old] : [fresh] },
            lastUsedDate: { path in
                if path == old.path {
                    oldDateStarted.fulfill()
                    releaseOldDate.wait()
                    return Date(timeIntervalSince1970: 1)
                }
                return freshDate
            }
        )

        model.load()
        await eventually { model.apps == [old] && !model.loading }
        model.setSort(.recent)
        await fulfillment(of: [oldDateStarted], timeout: 1)
        model.load()
        await eventually { model.apps.first?.id == fresh.id && model.apps.first?.lastUsed == freshDate }

        releaseOldDate.signal()
        await settle()

        XCTAssertEqual(model.apps.first?.id, fresh.id)
        XCTAssertEqual(model.apps.first?.lastUsed, freshDate)
    }

    func testPreviewFromAnOlderInventoryCannotPublishAfterReload() async {
        let previewStarted = expectation(description: "old preview started")
        let releasePreview = DispatchSemaphore(value: 0)
        let calls = LockedCounter()
        let old = app(id: "old", name: "Old", path: "/Applications/Old.app")
        let fresh = app(id: "fresh", name: "Fresh", path: "/Applications/Fresh.app")
        let model = SoftwareModel(
            loadApps: { calls.next() == 1 ? [old] : [fresh] },
            loadPreview: { _ in
                previewStarted.fulfill()
                releasePreview.wait()
                return UninstallPreview(
                    appName: "Old",
                    totalText: "1 B",
                    entries: [.init(path: old.path, kind: .application)]
                )
            }
        )

        model.load()
        await eventually { model.apps == [old] }
        model.toggleExpansion(old)
        await fulfillment(of: [previewStarted], timeout: 1)
        model.load()
        await eventually { model.apps == [fresh] && !model.loading }

        releasePreview.signal()
        await settle()

        XCTAssertTrue(model.previews.isEmpty)
        XCTAssertTrue(model.previewLoading.isEmpty)
        XCTAssertNil(model.expandedAppID)
    }

    func testReloadDropsSelectionsThatNoLongerExist() async {
        let calls = LockedCounter()
        let old = app(id: "old", name: "Old", path: "/Applications/Old.app")
        let fresh = app(id: "fresh", name: "Fresh", path: "/Applications/Fresh.app")
        let model = SoftwareModel(loadApps: { calls.next() == 1 ? [old] : [fresh] })

        model.load()
        await eventually { model.apps == [old] }
        model.toggle(old.id)
        model.load()
        await eventually { model.apps == [fresh] }

        XCTAssertTrue(model.selected.isEmpty)
    }

    private func app(
        id: String,
        name: String,
        path: String,
        size: Int64 = 1,
        lastUsed: Date? = nil
    ) -> InstalledApp {
        InstalledApp(
            id: id,
            name: name,
            bundleId: "dev.test.\(id)",
            source: "App",
            uninstallName: name,
            path: path,
            sizeStr: "\(size) B",
            sizeBytes: size,
            lastUsed: lastUsed
        )
    }

    private func eventually(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition())
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

//  `SoftwareModel.uninstallTarget` is the one safety-critical decision behind the Software tab's
//  uninstall: which identifier Burrow puts on the engine's argv for a given installed app. It is
//  used by BOTH the dry-run leftover preview and the real removal, and that sharing is the point —
//  the two used to decide separately (`bundleId` for the preview, `uninstallName` for the apply)
//  and, wherever two installed apps share a display name, resolve to DIFFERENT applications.
//
//  Fixture: rows lifted verbatim from a real `burrow-engine uninstall --list` capture on a machine
//  with 135 installed apps, parsed here through the production parser (`MoleClient.parseApps`)
//  rather than hand-built as `InstalledApp` values — so the field shapes, the `"unknown"` sentinel
//  and the Homebrew cask token are the engine's own, not this file's idea of them. The subset is
//  chosen for what it exhibits: three `Restarter`s and two `Steam`s that collide on display name
//  while carrying distinct bundle ids, two rows with no `CFBundleIdentifier` at all, and one
//  Homebrew row whose `uninstall_name` is the lowercase cask token.
//

final class SoftwareUninstallModelTests: XCTestCase {

    // MARK: - Fixture

    /// Verbatim rows from `burrow-engine uninstall --list` (2026-08, 135-row inventory).
    private static let capturedInventoryJSON = """
    [
      {"name": "Restarter", "bundle_id": "com.install4j.5556-0173-2910-4100.640", "source": "App", "uninstall_name": "Restarter", "path": "/Users/henry/Applications/IB Gateway 10.41/.install4j/Restarter.app", "size": "--"},
      {"name": "Restarter", "bundle_id": "com.install4j.5889-6375-8446-2021.640", "source": "App", "uninstall_name": "Restarter", "path": "/Users/henry/Applications/Trader Workstation/.install4j/Restarter.app", "size": "--"},
      {"name": "Updater", "bundle_id": "com.install4j.5889-6375-8446-2021.443", "source": "App", "uninstall_name": "Updater", "path": "/Users/henry/Applications/Trader Workstation/.install4j/Updater.app", "size": "--"},
      {"name": "Synergy", "bundle_id": "unknown", "source": "App", "uninstall_name": "Synergy", "path": "/Users/henry/Applications/Synergy.app", "size": "93KB"},
      {"name": "Steam", "bundle_id": "com.codeweavers.CrossOverHelper.4DB4563826BAD0EB2F60EE6E42D0EA4B.D7B460B2ACE2473B3D92C221DB864590", "source": "App", "uninstall_name": "Steam", "path": "/Users/henry/Applications/CrossOver/Steam/Steam.app", "size": "351KB"},
      {"name": "Stats", "bundle_id": "eu.exelban.Stats", "source": "Homebrew", "uninstall_name": "stats", "path": "/Applications/Stats.app", "size": "57.6MB"},
      {"name": "Stardew Valley", "bundle_id": "unknown", "source": "App", "uninstall_name": "Stardew Valley", "path": "/Users/henry/Applications/Stardew Valley.app", "size": "55KB"},
      {"name": "Steam", "bundle_id": "com.valvesoftware.steam", "source": "App", "uninstall_name": "Steam", "path": "/Applications/Steam.app", "size": "11.2MB"}
    ]
    """

    private func inventory() -> [InstalledApp] {
        MoleClient.parseApps(Data(Self.capturedInventoryJSON.utf8))
    }

    private func row(named name: String, bundleId: String) -> InstalledApp {
        inventory().first { $0.name == name && $0.bundleId == bundleId }!
    }

    /// A row built by hand, only for the two argv shapes the real capture cannot contain: a
    /// missing `bundle_id` key (`parseApps` defaults it to `""`) and a flag-shaped one.
    private func app(bundleId: String, uninstallName: String = "Display Name") -> InstalledApp {
        InstalledApp(id: "x", name: "App", bundleId: bundleId, source: "App",
                     uninstallName: uninstallName, path: "/Applications/App.app",
                     sizeStr: "1MB", sizeBytes: 1_000_000, lastUsed: nil)
    }

    func testFixture_isTheRealCaptureAndCarriesTheCasesUnderTest() {
        let inv = inventory()
        XCTAssertEqual(inv.count, 8, "every captured row must survive MoleClient.parseApps")
        XCTAssertEqual(inv.filter { $0.name == "Steam" }.count, 2,
                       "the display-name collision is the whole point of this fixture")
        XCTAssertEqual(Set(inv.filter { $0.name == "Steam" }.map(\.bundleId)).count, 2,
                       "…and the colliding rows carry distinct bundle ids")
        XCTAssertEqual(inv.filter { $0.bundleId == "unknown" }.count, 2)
        XCTAssertEqual(row(named: "Stats", bundleId: "eu.exelban.Stats").uninstallName, "stats",
                       "a Homebrew row's uninstall_name is the cask token, not the display name")
    }

    // MARK: - uninstallTarget

    func testUninstallTarget_bundledEngineWithBundleId_sendsTheBundleId() {
        let a = row(named: "Steam", bundleId: "com.valvesoftware.steam")
        XCTAssertEqual(SoftwareModel.uninstallTarget(for: a, resolvedIsBundledEngine: true),
                       .engine(bundleId: "com.valvesoftware.steam"))
    }

    /// THE regression. Both call sites now derive their argument from this one function, so for a
    /// given row the preview and the apply cannot name different applications — and the two
    /// colliding rows cannot name the same one.
    func testUninstallTarget_collidingDisplayNamesResolveToDistinctArguments() {
        let valve = row(named: "Steam", bundleId: "com.valvesoftware.steam")
        let crossover = row(named: "Steam",
                            bundleId: "com.codeweavers.CrossOverHelper.4DB4563826BAD0EB2F60EE6E42D0EA4B.D7B460B2ACE2473B3D92C221DB864590")
        XCTAssertEqual(valve.uninstallName, crossover.uninstallName,
                       "precondition: the old argument was identical for both rows — that WAS the bug")
        XCTAssertNotEqual(SoftwareModel.uninstallTarget(for: valve, resolvedIsBundledEngine: true),
                          SoftwareModel.uninstallTarget(for: crossover, resolvedIsBundledEngine: true),
                          "two different applications must not send the same argument")
    }

    /// Every row in the capture that has a real bundle id must send it, and no two of them may
    /// send the same thing — otherwise a multi-select silently collapses onto one app.
    func testUninstallTarget_everyRealRowSendsAUniqueArgument() {
        let addressable = inventory().filter { SoftwareModel.isSendableBundleID($0.bundleId) }
        let arguments: [String] = addressable.compactMap { app in
            guard case .engine(let id) = SoftwareModel.uninstallTarget(for: app, resolvedIsBundledEngine: true) else {
                XCTFail("\(app.name) should be addressable")
                return nil
            }
            return id
        }
        XCTAssertEqual(Set(arguments).count, addressable.count,
                       "arguments collided: \(arguments)")
    }

    /// The trap the `isEmpty` check does not catch. `uninstall --list` writes the literal string
    /// `"unknown"` for a bundle with no `CFBundleIdentifier` — five rows on the captured machine.
    /// Sent to the engine it resolves through the bundle-id pass to whichever unknown-id row comes
    /// first (Synergy, verified against the real binary), so a report for one app would be
    /// presented as another's. The engine happens to short-circuit `"unknown"` to zero leftovers
    /// today, which makes it a mis-attributed EMPTY answer rather than a misdirected deletion —
    /// an engine internal, not a contract this side may lean on.
    func testUninstallTarget_unknownBundleId_refusesRatherThanResolveToSomeoneElse() {
        for app in inventory() where app.bundleId == "unknown" {
            XCTAssertEqual(SoftwareModel.uninstallTarget(for: app, resolvedIsBundledEngine: true),
                           .unavailable, "\(app.name) has no bundle id and must not be sent")
        }
        XCTAssertFalse(SoftwareModel.isSendableBundleID("unknown"))
    }

    /// The other dangerous case. An empty bundle id must NOT be sent: the engine's `positionals`
    /// hands the empty string to its resolver, whose substring pass matches `name.contains("")`
    /// for every row — `uninstall --dry-run ""` resolved all 135 installed apps and enumerated
    /// 224 leftover paths, verified against the real binary. Refusing outright is the only safe
    /// move; a preview that confidently shows the wrong app's leftovers is worse than one that
    /// shows nothing.
    func testUninstallTarget_emptyBundleId_refusesRatherThanGuess() {
        XCTAssertEqual(SoftwareModel.uninstallTarget(for: app(bundleId: ""), resolvedIsBundledEngine: true),
                       .unavailable)
        XCTAssertFalse(SoftwareModel.isSendableBundleID(""))
    }

    /// A flag-shaped identifier would be skipped by the engine's `positionals` scan, so the run
    /// would act on fewer apps than it reported — the silent-drop class this whole change closes.
    func testUninstallTarget_flagShapedBundleId_refuses() {
        XCTAssertEqual(SoftwareModel.uninstallTarget(for: app(bundleId: "--permanent"), resolvedIsBundledEngine: true),
                       .unavailable)
        XCTAssertFalse(SoftwareModel.isSendableBundleID("-x"))
    }

    /// A real legacy `mo`/MIT-fork binary resolved instead — unchanged pre-fix behavior: send the
    /// display name, regardless of whether a bundle id also happens to be known. Its matcher only
    /// understands names, so the engine-only special-casing must never leak into this branch.
    func testUninstallTarget_legacyMo_sendsDisplayNameEvenWhenABundleIdIsKnown() {
        let a = row(named: "Steam", bundleId: "com.valvesoftware.steam")
        XCTAssertEqual(SoftwareModel.uninstallTarget(for: a, resolvedIsBundledEngine: false),
                       .legacy(name: "Steam"))
    }

    func testUninstallTarget_legacyMo_unknownAndEmptyBundleIdsStillSendTheDisplayName() {
        let synergy = row(named: "Synergy", bundleId: "unknown")
        XCTAssertEqual(SoftwareModel.uninstallTarget(for: synergy, resolvedIsBundledEngine: false),
                       .legacy(name: "Synergy"))
        XCTAssertEqual(SoftwareModel.uninstallTarget(for: app(bundleId: "", uninstallName: "Slack"),
                                                     resolvedIsBundledEngine: false),
                       .legacy(name: "Slack"))
    }

    /// A Homebrew row's `uninstall_name` is the cask token, which is what the legacy binary's
    /// `--list` advertises and what a `brew uninstall` would need — so the legacy branch keeps
    /// sending it, while the engine branch sends the bundle id like every other row.
    func testUninstallTarget_homebrewRow_caskTokenOnTheLegacyPathBundleIdOnTheEngine() {
        let stats = row(named: "Stats", bundleId: "eu.exelban.Stats")
        XCTAssertEqual(SoftwareModel.uninstallTarget(for: stats, resolvedIsBundledEngine: false),
                       .legacy(name: "stats"))
        XCTAssertEqual(SoftwareModel.uninstallTarget(for: stats, resolvedIsBundledEngine: true),
                       .engine(bundleId: "eu.exelban.Stats"))
    }

    // MARK: - uninstallBatch

    func testUninstallBatch_argumentsAreAlignedWithTheAppsTheyName() {
        let inv = inventory()
        let batch = SoftwareModel.uninstallBatch(for: inv, resolvedIsBundledEngine: true)
        XCTAssertEqual(batch.arguments.count, batch.addressable.count)
        for (arg, app) in zip(batch.arguments, batch.addressable) {
            XCTAssertEqual(arg, app.bundleId, "\(app.name)'s argument must name \(app.name)")
        }
    }

    /// The rule that keeps a run honest: an app Burrow cannot name is reported, never folded into
    /// the request. A dropped positional would otherwise be counted in the "N apps" the HUD and
    /// the confirm sheet both claim.
    func testUninstallBatch_unaddressableAppsAreSurfacedNotDropped() {
        let inv = inventory()
        let batch = SoftwareModel.uninstallBatch(for: inv, resolvedIsBundledEngine: true)
        XCTAssertEqual(batch.unaddressable.map(\.name).sorted(), ["Stardew Valley", "Synergy"])
        XCTAssertEqual(batch.addressable.count + batch.unaddressable.count, inv.count,
                       "every selected app is accounted for in exactly one bucket")
        XCTAssertFalse(batch.arguments.contains("unknown"),
                       "the `unknown` sentinel must never reach argv")
    }

    func testUninstallBatch_legacyPathAddressesEveryAppByName() {
        let inv = inventory()
        let batch = SoftwareModel.uninstallBatch(for: inv, resolvedIsBundledEngine: false)
        XCTAssertTrue(batch.unaddressable.isEmpty,
                      "a legacy binary takes display names, so nothing is unaddressable")
        XCTAssertEqual(batch.arguments, inv.map(\.uninstallName))
    }

    func testUninstallBatch_emptySelectionIsEmpty() {
        let batch = SoftwareModel.uninstallBatch(for: [], resolvedIsBundledEngine: true)
        XCTAssertEqual(batch, SoftwareModel.UninstallBatch(arguments: [], addressable: [],
                                                           unaddressable: []))
    }

    // MARK: - confirmCopy
    //
    // This sheet has now been wrong in BOTH directions. It said "These move to the Trash
    // (recoverable)" while the engine removed only `~/Library` leftovers; it was corrected to "The
    // apps themselves stay installed"; and burrow-engine @ df9ea3f then made THAT false by porting
    // `lib/uninstall/batch.sh`'s bundle removal. So the assertions below pin the two claims that
    // can be false about a real machine — where the app goes, and what Homebrew does instead —
    // rather than the wording around them. Compared against the localized keys themselves, not
    // English substrings, so they hold in any locale the test host runs under.

    private func lines(_ names: [String]) -> [SoftwareModel.ConfirmLine] {
        names.map { SoftwareModel.ConfirmLine(name: $0, reviewedCount: nil) }
    }

    /// Reverting to either dead wording — "These move to the Trash (recoverable)" with no mention
    /// of the app, or "The apps themselves stay installed" — fails this, because neither produces
    /// the sentence asserted here. A negative assertion against the old English literals would not
    /// add anything: those keys no longer exist in either `.strings` file, so under a zh test host
    /// they would compare against themselves and pass vacuously.
    func testConfirmCopy_saysTheAppItselfGoesToTheTrash() {
        let copy = SoftwareModel.confirmCopy(lines: lines(["Steam", "Stats"]), skipped: [],
                                             hasReviewedSubset: false)
        XCTAssertTrue(copy.body.contains(
            String(format: NSLocalizedString("These move to the Trash — the app itself and the support files it keeps in your Library (containers, caches, preferences, saved state). You can put them back:\n\n%@", comment: ""),
                   "• Steam\n• Stats")), copy.body)
        XCTAssertEqual(copy.title,
                       String(format: NSLocalizedString("Remove %d apps?", comment: ""), 2))
        XCTAssertEqual(copy.confirmButton, NSLocalizedString("Move to Trash", comment: ""))
    }

    func testConfirmCopy_singularTitle() {
        let copy = SoftwareModel.confirmCopy(lines: lines(["Steam"]), skipped: [],
                                             hasReviewedSubset: false)
        XCTAssertEqual(copy.title,
                       String(format: NSLocalizedString("Remove %d app?", comment: ""), 1))
    }

    /// A Homebrew cask is removed by `brew uninstall --cask --zap`, which does not Trash anything
    /// and deletes more than the preview can enumerate. Folding it into the Trash sentence would
    /// make the sheet's central promise false for exactly the apps where it matters most, so it
    /// gets its own paragraph and the button stops naming a mechanism that only half applies.
    func testConfirmCopy_homebrewAppsGetTheirOwnParagraphAndNoTrashPromise() {
        let copy = SoftwareModel.confirmCopy(
            lines: [SoftwareModel.ConfirmLine(name: "Stats", reviewedCount: nil, homebrewCask: "stats")],
            skipped: [], hasReviewedSubset: false)
        XCTAssertTrue(copy.body.contains(
            String(format: NSLocalizedString("Homebrew removes these by running `brew uninstall --cask --zap`. That doesn't use the Trash, and `--zap` also deletes configuration and data the cask declares — more than the file list can show:\n\n%@", comment: ""),
                   "• Stats")), copy.body)
        XCTAssertFalse(copy.body.contains(
            String(format: NSLocalizedString("These move to the Trash — the app itself and the support files it keeps in your Library (containers, caches, preferences, saved state). You can put them back:\n\n%@", comment: ""),
                   "• Stats")),
            "a brew app does not go to the Trash, so it must not appear under that sentence")
        XCTAssertEqual(copy.confirmButton, NSLocalizedString("Remove", comment: ""),
                       "with a cask in the set there is no single mechanism for the button to name")
    }

    func testConfirmCopy_mixedSetSplitsTheTwoMechanisms() {
        let copy = SoftwareModel.confirmCopy(
            lines: [SoftwareModel.ConfirmLine(name: "Steam", reviewedCount: nil),
                    SoftwareModel.ConfirmLine(name: "Stats", reviewedCount: nil, homebrewCask: "stats")],
            skipped: [], hasReviewedSubset: false)
        XCTAssertTrue(copy.body.contains("• Steam"), copy.body)
        XCTAssertTrue(copy.body.contains("• Stats"), copy.body)
        // Each app is listed once, under the mechanism that actually applies to it.
        XCTAssertEqual(copy.body.components(separatedBy: "• Steam").count - 1, 1, copy.body)
        XCTAssertEqual(copy.body.components(separatedBy: "• Stats").count - 1, 1, copy.body)
        XCTAssertEqual(copy.confirmButton, NSLocalizedString("Remove", comment: ""))
    }

    /// The engine gates the leftover sweep on the bundle coming away, so an app it cannot remove
    /// keeps its support files too. Said before consent, it makes a "nothing happened for this one"
    /// outcome legible instead of baffling.
    func testConfirmCopy_statesThatAFailedRemovalLeavesTheSupportFilesAlone() {
        let copy = SoftwareModel.confirmCopy(lines: lines(["Steam"]), skipped: [],
                                             hasReviewedSubset: false)
        XCTAssertTrue(copy.body.contains(NSLocalizedString("If an app can't be removed, Burrow leaves its support files alone too, rather than half-removing it.", comment: "")),
                      copy.body)
    }

    func testConfirmCopy_namesEveryAppItWillActOnAndEveryAppItSkips() {
        let copy = SoftwareModel.confirmCopy(lines: lines(["Steam", "Stats"]),
                                             skipped: ["Synergy", "Stardew Valley"],
                                             hasReviewedSubset: false)
        for name in ["Steam", "Stats", "Synergy", "Stardew Valley"] {
            XCTAssertTrue(copy.body.contains(name), "\(name) must appear in the sheet: \(copy.body)")
        }
        XCTAssertFalse(copy.title.contains("4"),
                       "the count must cover only the apps actually acted on, not the skipped ones")
    }

    func testConfirmCopy_reviewedSubsetShowsItsFileCountAndTheActivityLogCaveat() {
        let copy = SoftwareModel.confirmCopy(
            lines: [SoftwareModel.ConfirmLine(name: "Stats", reviewedCount: 3)],
            skipped: [], hasReviewedSubset: true)
        XCTAssertTrue(copy.body.contains(String(format: NSLocalizedString("%d reviewed files", comment: ""), 3)),
                      copy.body)
        XCTAssertTrue(copy.body.contains(NSLocalizedString("Reviewed subsets are trashed by Burrow directly and appear in Burrow's Activity log, not `mo history`.", comment: "")),
                      copy.body)
    }

    // MARK: - "Clear Data": the subset that KEEPS the app
    //
    // The button's own tooltip is "Select everything except the app itself — removes its data but
    // keeps the app installed", and it sets `UninstallPlan.dataOnly`, which filters the `.app` out.
    // That makes the removal a subset, and the rewritten sheet printed the whole-app sentence over
    // it: "These move to the Trash — the app itself and the support files…". The consent dialog
    // said the opposite of what the button does. The surviving subset test asserted only the
    // "%d reviewed files" fragment, so it passed either way — these do not.

    private var trashSentence: String {
        NSLocalizedString("These move to the Trash — the app itself and the support files it keeps in your Library (containers, caches, preferences, saved state). You can put them back:\n\n%@", comment: "")
            .components(separatedBy: ":\n\n").first ?? ""
    }

    private var keptSentence: String {
        NSLocalizedString("These stay installed — only the reviewed support files move to the Trash, and you can put them back:\n\n%@", comment: "")
            .components(separatedBy: ":\n\n").first ?? ""
    }

    /// The names a given sentence governs. `confirmCopy` formats every block as
    /// `"<sentence>:\n\n<names>"` and then joins the blocks with "\n\n" — so slicing the whole body
    /// on "\n\n" (what the mixed-case test used to do) cuts each block at its OWN separator: the
    /// sentence lands in one component and the names it introduces in the next, and "the removal
    /// block lists Steam" comes out false however right the copy is. Anchor on the sentence's own
    /// separator instead and take the single paragraph it introduces.
    private func listed(under sentence: String, in body: String) -> String {
        guard let intro = body.range(of: sentence + ":\n\n") else { return "" }
        return body[intro.upperBound...].components(separatedBy: "\n\n").first ?? ""
    }

    func testConfirmCopy_aKeptAppIsNeverDescribedAsMovingToTheTrash() {
        let copy = SoftwareModel.confirmCopy(
            lines: [SoftwareModel.ConfirmLine(name: "Stats", reviewedCount: 3,
                                              removesAppBundle: false)],
            skipped: [], hasReviewedSubset: true)
        XCTAssertFalse(copy.body.contains(trashSentence),
                       "Clear Data keeps the app installed — the sheet must not promise otherwise: \(copy.body)")
        XCTAssertTrue(copy.body.contains(
            String(format: NSLocalizedString("These stay installed — only the reviewed support files move to the Trash, and you can put them back:\n\n%@", comment: ""),
                   "• Stats — \(String(format: NSLocalizedString("%d reviewed files", comment: ""), 3))")),
            copy.body)
        XCTAssertFalse(copy.title.contains(
            String(format: NSLocalizedString("Remove %d app?", comment: ""), 1)),
            "and it must not ASK to remove an app it is about to keep: \(copy.title)")
    }

    /// The branch has to cut both ways in one sheet: select-all on one app and Clear Data on
    /// another, and each line appears under the promise that is true of it.
    func testConfirmCopy_mixedKeptAndRemovedAppsEachGetTheTrueSentence() {
        let copy = SoftwareModel.confirmCopy(
            lines: [SoftwareModel.ConfirmLine(name: "Steam", reviewedCount: nil),
                    SoftwareModel.ConfirmLine(name: "Stats", reviewedCount: 3,
                                              removesAppBundle: false)],
            skipped: [], hasReviewedSubset: true)
        let trashed = listed(under: trashSentence, in: copy.body)
        XCTAssertTrue(trashed.contains("Steam"), copy.body)
        XCTAssertFalse(trashed.contains("Stats"),
                       "the kept app must not be listed under the sentence that removes it: \(copy.body)")
        // The other half of "each gets the true sentence", which the old slicing couldn't state:
        // the kept app is under the promise that keeps it, and the removed one is not.
        let kept = listed(under: keptSentence, in: copy.body)
        XCTAssertTrue(kept.contains("Stats"), copy.body)
        XCTAssertFalse(kept.contains("Steam"),
                       "the removed app must not be listed under the sentence that keeps it: \(copy.body)")
    }

    /// A whole-app removal is unchanged — the default is still "the bundle goes".
    func testConfirmCopy_wholeAppRemovalStillPromisesTheAppItself() {
        let copy = SoftwareModel.confirmCopy(lines: lines(["Steam"]), skipped: [],
                                             hasReviewedSubset: false)
        XCTAssertTrue(copy.body.contains(trashSentence), copy.body)
    }

    // MARK: - Ordering: the subsets ride BEHIND the pre-flight
    //
    // `trashSubsets` used to run first and unconditionally, before any dry run. When the guard
    // then aborted, the user was shown a sentence ending "so nothing was removed" over a Trash
    // that already held a subset app's files — its `.app` among them, since the bundle is
    // auto-ticked. Route, not statement order, so it can be asserted.

    func testRemovalRoute_aMixedSelectionDefersTheHandTrashBehindTheEngineRun() {
        let whole = row(named: "Steam", bundleId: "com.valvesoftware.steam")
        let subset = row(named: "Stats", bundleId: "eu.exelban.Stats")
        XCTAssertEqual(SoftwareModel.removalRoute(addressable: [whole], subsets: [subset]),
                       .engineThenTrash([subset]),
                       "there must be no route that trashes a subset alongside an unverified engine run")
    }

    func testRemovalRoute_subsetsAloneHaveNoPreflightToWaitFor() {
        let subset = row(named: "Stats", bundleId: "eu.exelban.Stats")
        XCTAssertEqual(SoftwareModel.removalRoute(addressable: [], subsets: [subset]),
                       .trashOnly([subset]))
        XCTAssertEqual(SoftwareModel.removalRoute(addressable: [], subsets: []), .none)
    }

    /// The sheet's brew-vs-Trash claim, captured at consent time so the post-consent dry run has
    /// something to be checked against. Keyed by the argument, lowercased, to line up with the
    /// engine's `apps[].query`.
    func testPromisedMechanisms_recordWhatTheSheetToldTheUserPerArgument() {
        // Straight off the real `--list` capture: Stats is `source: "Homebrew"`, Steam is `"App"`.
        let brewed = row(named: "Stats", bundleId: "eu.exelban.Stats")
        let plain = row(named: "Steam", bundleId: "com.valvesoftware.steam")
        XCTAssertEqual(brewed.source, "Homebrew")
        let promised = SoftwareModel.promisedMechanisms([brewed, plain],
                                                        ["eu.exelban.Stats", "com.valvesoftware.steam"])
        XCTAssertEqual(promised["eu.exelban.stats"], .homebrew)
        XCTAssertEqual(promised["com.valvesoftware.steam"], .direct)
    }
}
