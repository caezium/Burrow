//
//  UpdatesModelTests.swift
//  BurrowTests
//

import XCTest
@testable import Burrow

@MainActor
final class UpdatesModelTests: XCTestCase {
    func testSameCountInventoryChangeRepreparesSourceMetadata() async {
        let detections = LockedStringRecorder()
        let model = UpdatesModel(detectSource: { app in
            detections.append(app.path)
            return app.path.contains("Store") ? .appStore : .sparkle
        })

        model.prepare(apps: [app(id: "one", name: "Vendor", path: "/Applications/Vendor.app")])
        await eventually { model.appItems.first?.source == .sparkle }

        model.prepare(apps: [app(id: "one", name: "Store", path: "/Applications/Store.app")])
        await eventually { model.appItems.first?.source == .appStore }

        XCTAssertEqual(detections.values, ["/Applications/Vendor.app", "/Applications/Store.app"])
        XCTAssertEqual(model.appItems.first?.name, "Store")
    }

    func testNewestPrepareWinsWhenOlderDetectionFinishesLast() async {
        let oldStarted = expectation(description: "old detection started")
        let releaseOld = DispatchSemaphore(value: 0)
        let model = UpdatesModel(detectSource: { app in
            if app.id == "old" {
                oldStarted.fulfill()
                releaseOld.wait()
                return .sparkle
            }
            return .appStore
        })

        model.prepare(apps: [app(id: "old", name: "Old", path: "/Applications/Old.app")])
        await fulfillment(of: [oldStarted], timeout: 1)
        model.prepare(apps: [app(id: "new", name: "New", path: "/Applications/New.app")])
        await eventually { model.appItems.map(\.id) == ["new"] }

        releaseOld.signal()
        await settle()

        XCTAssertEqual(model.appItems.map(\.id), ["new"])
        XCTAssertTrue(model.uncheckableApps.isEmpty)
    }

    func testRemovedAppsDisappearBeforeReplacementDetectionCompletes() async {
        let replacementStarted = expectation(description: "replacement detection started")
        let releaseReplacement = DispatchSemaphore(value: 0)
        let model = UpdatesModel(detectSource: { app in
            if app.name == "Replacement" {
                replacementStarted.fulfill()
                releaseReplacement.wait()
            }
            return .sparkle
        })
        let keep = app(id: "keep", name: "Keep", path: "/Applications/Keep.app")
        let remove = app(id: "remove", name: "Remove", path: "/Applications/Remove.app")

        model.prepare(apps: [keep, remove])
        await eventually { Set(model.appItems.map(\.id)) == ["keep", "remove"] }
        let replacement = app(id: "keep", name: "Replacement", path: "/Applications/Keep.app")
        model.prepare(apps: [replacement])
        await fulfillment(of: [replacementStarted], timeout: 1)

        XCTAssertFalse(model.appItems.contains { $0.id == "remove" })
        XCTAssertFalse(model.uncheckableApps.contains { $0.id == "remove" })

        releaseReplacement.signal()
        await eventually { model.appItems.first?.name == "Replacement" }
    }

    func testSameInstalledAppIdentityRepreparesWhenBundleDetectionMetadataChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdatesModelTests-\(UUID().uuidString)", isDirectory: true)
        let appURL = root.appendingPathComponent("Mutable.app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writePlist(
            ["CFBundleIdentifier": "dev.test.mutable", "SUFeedURL": "https://updates.example.com/appcast.xml"],
            to: contents.appendingPathComponent("Info.plist")
        )
        let installed = app(id: "stable", name: "Mutable", path: appURL.path)
        let model = UpdatesModel()

        model.prepare(apps: [installed])
        await eventually { model.appItems.first?.source == .sparkle }

        try writePlist(
            ["CFBundleIdentifier": "dev.test.mutable"],
            to: contents.appendingPathComponent("Info.plist")
        )
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent("Frameworks/Electron Framework.framework", isDirectory: true),
            withIntermediateDirectories: true
        )
        model.prepare(apps: [installed])
        await eventually { model.appItems.first?.source == .electron }

        XCTAssertEqual(model.appItems.map(\.id), ["stable"])
    }

    func testDetectionFingerprintIncludesElectronAppUpdateConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdatesFingerprintTests-\(UUID().uuidString)", isDirectory: true)
        let resources = root.appendingPathComponent("Mutable.app/Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = resources.appendingPathComponent("app-update.yml")
        try Data("provider: generic\nurl: https://one.example.com".utf8).write(to: config, options: .atomic)
        let before = UpdateSources.detectionFingerprint(appPath: root.appendingPathComponent("Mutable.app").path)

        try Data("provider: generic\nurl: https://two.example.com".utf8).write(to: config, options: .atomic)
        let after = UpdateSources.detectionFingerprint(appPath: root.appendingPathComponent("Mutable.app").path)

        XCTAssertNotEqual(before, after)
    }

    private func app(id: String, name: String, path: String) -> InstalledApp {
        InstalledApp(
            id: id,
            name: name,
            bundleId: "dev.test.\(id)",
            source: "App",
            uninstallName: name,
            path: path,
            sizeStr: "1 B",
            sizeBytes: 1,
            lastUsed: nil
        )
    }

    private func writePlist(_ values: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: values,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)
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

private final class LockedStringRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
