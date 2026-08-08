//
//  SoftwareModelTests.swift
//  BurrowTests
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
