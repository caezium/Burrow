//
//  CleanupFinderTests.swift
//  BurrowTests
//
//  InstallerFinder.scan(in:) is the selectable-installers feature's only
//  non-UI logic, and it takes its directories as a parameter so it can be
//  pinned against a temp folder.
//

import XCTest
@testable import Burrow

final class CleanupFinderTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-finder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ name: String, bytes: Int) throws {
        try Data(count: bytes).write(to: tempDir.appendingPathComponent(name))
    }

    func testScan_returnsOnlyInstallerTypesBySizeDescending() throws {
        try write("small.dmg", bytes: 100)
        try write("big.pkg", bytes: 1_000)
        try write("notes.txt", bytes: 500)         // wrong type — excluded
        try write("archive.zip", bytes: 800)        // not an installer type here — excluded

        let found = InstallerFinder.scan(in: [("Test", tempDir)])
        XCTAssertEqual(found.map { $0.name }, ["big.pkg", "small.dmg"], "installer types only, largest first")
        XCTAssertEqual(found.first?.size, 1_000)
        XCTAssertEqual(found.first?.location, "Test")
        XCTAssertEqual(found.first?.name, "big.pkg")
        XCTAssertTrue(found.first?.path.hasSuffix("/big.pkg") ?? false)
    }

    func testScan_isCaseInsensitiveOnExtension() throws {
        try write("Installer.DMG", bytes: 42)
        let found = InstallerFinder.scan(in: [("Test", tempDir)])
        XCTAssertEqual(found.map { $0.name }, ["Installer.DMG"])
    }

    func testScan_missingDirectoryIsSkippedNotFatal() {
        let ghost = tempDir.appendingPathComponent("does-not-exist")
        let found = InstallerFinder.scan(in: [("Gone", ghost), ("Test", tempDir)])
        XCTAssertTrue(found.isEmpty)
    }

    func testTrash_movesFilesToTrashAndReportsFailures() throws {
        try write("toss.dmg", bytes: 10)
        let real = tempDir.appendingPathComponent("toss.dmg").path
        let failed = CleanupTrasher.trash([real, "/nonexistent/nope.dmg"])
        XCTAssertEqual(failed, ["/nonexistent/nope.dmg"], "the missing path fails; the real one is trashed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: real), "trashed file no longer at its path")
    }
}
