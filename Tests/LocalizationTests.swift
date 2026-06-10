//
//  LocalizationTests.swift
//  BurrowTests
//

import XCTest
@testable import Burrow

final class LocalizationTests: XCTestCase {
    private static let coreInterfaceKeys = [
        "Clean",
        "Software",
        "Optimize",
        "Analyze",
        "Status",
        "Settings",
        "History",
        "Open Burrow",
        "Clean Now",
        "Preview",
        "Uninstall",
        "Updates",
        "Search apps",
        "Everything's up to date",
        "Update all",
        "Run maintenance now",
        "Maintenance complete.",
        "Periodic Maintenance",
        "User directory permissions already optimal",
    ]

    func testTaskReportTextLocalizesOptimizeOutput() throws {
        let bundle = try lprojBundle("zh-Hans")
        XCTAssertEqual(TaskReportText.title("Periodic Maintenance", bundle: bundle), "定期维护")
        XCTAssertEqual(TaskReportText.title("Disk Health", bundle: bundle), "磁盘健康")
        XCTAssertEqual(TaskReportText.item("User directory permissions already optimal", bundle: bundle), "用户目录权限已是最佳状态")
        XCTAssertEqual(TaskReportText.item("Periodic maintenance skipped (not available on this macOS version)", bundle: bundle), "已跳过定期维护（此 macOS 版本不可用）")
        XCTAssertEqual(TaskReportText.item("Disk verify skipped (set MOLE_ENABLE_DISK_VERIFY=1 to enable)", bundle: bundle), "已跳过磁盘验证（设置 MOLE_ENABLE_DISK_VERIFY=1 可启用）")
        XCTAssertEqual(TaskReportText.item("Login items all healthy (3 checked)", bundle: bundle), "登录项均正常（已检查 3 项）")
        XCTAssertEqual(TaskReportText.item("Wallpaper agent cache, 33.0MB dry", bundle: bundle), "壁纸代理缓存，33.0MB 可清理")
    }

    func testTaskReportTextLocalizesOptimizeOutputTraditional() throws {
        let bundle = try lprojBundle("zh-Hant")
        XCTAssertEqual(TaskReportText.title("Periodic Maintenance", bundle: bundle), "定期維護")
        XCTAssertEqual(TaskReportText.title("Disk Health", bundle: bundle), "磁碟健康")
        XCTAssertEqual(TaskReportText.item("User directory permissions already optimal", bundle: bundle), "使用者目錄權限已是最佳狀態")
        XCTAssertEqual(TaskReportText.item("Periodic maintenance skipped (not available on this macOS version)", bundle: bundle), "已略過定期維護（此 macOS 版本不支援）")
        XCTAssertEqual(TaskReportText.item("Disk verify skipped (set MOLE_ENABLE_DISK_VERIFY=1 to enable)", bundle: bundle), "已略過磁碟驗證（設定 MOLE_ENABLE_DISK_VERIFY=1 可啟用）")
        XCTAssertEqual(TaskReportText.item("Login items all healthy (3 checked)", bundle: bundle), "登入項目均正常（已檢查 3 項）")
        XCTAssertEqual(TaskReportText.item("Wallpaper agent cache, 33.0MB dry", bundle: bundle), "桌面背景代理程式快取，33.0MB 可清理")
    }

    func testSimplifiedChineseStringsCoverCoreInterface() throws {
        try assertCoversCoreInterface(language: "zh-Hans")
    }

    func testTraditionalChineseStringsCoverCoreInterface() throws {
        try assertCoversCoreInterface(language: "zh-Hant")
    }

    /// Both Chinese variants should translate the same set of keys, so a key
    /// added to one file isn't silently missing from the other.
    func testChineseVariantsShareTheSameKeys() throws {
        let hans = Set(try localizedStrings("zh-Hans").keys)
        let hant = Set(try localizedStrings("zh-Hant").keys)
        XCTAssertEqual(hans.subtracting(hant).sorted(), [], "keys missing from zh-Hant")
        XCTAssertEqual(hant.subtracting(hans).sorted(), [], "keys missing from zh-Hans")
    }

    private func assertCoversCoreInterface(language: String) throws {
        let strings = try localizedStrings(language)
        for key in Self.coreInterfaceKeys {
            let value = try XCTUnwrap(strings[key], "missing \(language) translation for \(key)")
            XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertNotEqual(value, key)
        }
    }

    private func localizedStrings(_ language: String) throws -> [String: String] {
        let url = lprojURL(language).appendingPathComponent("Localizable.strings")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: String])
    }

    private func lprojBundle(_ language: String) throws -> Bundle {
        try XCTUnwrap(Bundle(url: lprojURL(language)))
    }

    private func lprojURL(_ language: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
            .appendingPathComponent("\(language).lproj")
    }
}
