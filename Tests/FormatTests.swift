//
//  FormatTests.swift
//  BurrowTests
//
//  Golden-value tests for the shared presentation vocabulary. These pin the
//  EXACT rendered strings — including historical warts like the "1023 B" →
//  "1.00 KB" precision jump — because five views render them and a silent
//  change is a regression. Fixing a wart later is a deliberate golden edit.
//

import XCTest
@testable import Burrow

final class FormatTests: XCTestCase {

    // MARK: Fmt.bytes — adaptive unit, 2 decimals under 10, 1 above

    func testBytesGoldenValues() {
        XCTAssertEqual(Fmt.bytes(0), "0 B")
        XCTAssertEqual(Fmt.bytes(999), "999 B")
        XCTAssertEqual(Fmt.bytes(1023), "1023 B")
        XCTAssertEqual(Fmt.bytes(1024), "1.00 KB")
        XCTAssertEqual(Fmt.bytes(1536), "1.50 KB")
        // Wart, frozen on purpose: 9.999 KB passes the <10 check, then
        // rounds up in formatting — so "10.00 KB" precedes "10.0 KB".
        XCTAssertEqual(Fmt.bytes(10_239), "10.00 KB")
        XCTAssertEqual(Fmt.bytes(10_240), "10.0 KB")
        XCTAssertEqual(Fmt.bytes(1_048_576), "1.00 MB")
        XCTAssertEqual(Fmt.bytes(10 * 1_048_576 + 537), "10.0 MB")
        XCTAssertEqual(Fmt.bytes(1_073_741_824), "1.00 GB")
        XCTAssertEqual(Fmt.bytes(Int64(1) << 40), "1.00 TB")
        // Units cap at TB; the value keeps growing.
        XCTAssertEqual(Fmt.bytes((Int64(1) << 40) * 1024), "1024.0 TB")
    }

    // MARK: Fmt.uptime — d/h, h/m, or bare minutes

    func testUptimeGoldenValues() {
        XCTAssertEqual(Fmt.uptime(0), "0m")
        XCTAssertEqual(Fmt.uptime(59), "0m")
        XCTAssertEqual(Fmt.uptime(60), "1m")
        XCTAssertEqual(Fmt.uptime(3_599), "59m")
        XCTAssertEqual(Fmt.uptime(3_600), "1h 0m")
        XCTAssertEqual(Fmt.uptime(86_399), "23h 59m")
        XCTAssertEqual(Fmt.uptime(86_400), "1d 0h")
        XCTAssertEqual(Fmt.uptime(90_000), "1d 1h")
    }

    // MARK: Fmt.gb — 2 decimals under 10, whole number above

    func testGBGoldenValues() {
        XCTAssertEqual(Fmt.gb(0), "0.00")
        XCTAssertEqual(Fmt.gb(9.99), "9.99")
        // Wart, frozen: 9.999 passes the <10 check then rounds to "10.00".
        XCTAssertEqual(Fmt.gb(9.999), "10.00")
        XCTAssertEqual(Fmt.gb(10), "10")
        XCTAssertEqual(Fmt.gb(234.6), "235")
    }

    // MARK: Fmt.gib — the one home for the 1_073_741_824 constant

    func testGibConvertsBinaryGigabytes() {
        XCTAssertEqual(Fmt.gib(1_073_741_824.0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(Fmt.gib(536_870_912.0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(Fmt.gib(UInt64(2_147_483_648)), 2.0, accuracy: 1e-9)
    }

    // MARK: Fmt.rate / Fmt.rateParts — the two net-rate renderings

    func testRateFootnoteForm() {
        // Footnote form truncates KB/s (Int cast) — historical behavior.
        XCTAssertEqual(Fmt.rate(0.5), "512 KB/s")
        XCTAssertEqual(Fmt.rate(0.999), "1022 KB/s")   // 1022.976 truncates
        XCTAssertEqual(Fmt.rate(1.0), "1.0 MB/s")
        XCTAssertEqual(Fmt.rate(2.34), "2.3 MB/s")
        XCTAssertEqual(Fmt.rate(2.46), "2.5 MB/s")
    }

    func testRatePartsTileForm() {
        // Tile form rounds KB/s (%.0f) — deliberately different from rate().
        XCTAssertEqual(Fmt.rateParts(0.5, mbDecimals: 2).value, "512")
        XCTAssertEqual(Fmt.rateParts(0.5, mbDecimals: 2).unit, "KB/s")
        XCTAssertEqual(Fmt.rateParts(0.999, mbDecimals: 1).value, "1023") // 1022.976 rounds
        XCTAssertEqual(Fmt.rateParts(2.5, mbDecimals: 2).value, "2.50")  // Status tile precision
        XCTAssertEqual(Fmt.rateParts(2.5, mbDecimals: 1).value, "2.5")   // HUD tile precision
        XCTAssertEqual(Fmt.rateParts(2.5, mbDecimals: 1).unit, "MB/s")
    }

    // MARK: Fmt.elapsed — operation timers ("42s", "3:07")

    func testElapsedGoldenValues() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(Fmt.elapsed(from: t0, to: t0), "0s")
        XCTAssertEqual(Fmt.elapsed(from: t0, to: t0.addingTimeInterval(59)), "59s")
        XCTAssertEqual(Fmt.elapsed(from: t0, to: t0.addingTimeInterval(60)), "1:00")
        XCTAssertEqual(Fmt.elapsed(from: t0, to: t0.addingTimeInterval(187)), "3:07")
        // Clock skew clamps to zero instead of going negative.
        XCTAssertEqual(Fmt.elapsed(from: t0, to: t0.addingTimeInterval(-5)), "0s")
    }

    // MARK: HealthRating — one threshold switch behind both label and color

    func testHealthTierThresholds() {
        XCTAssertEqual(HealthRating.tier(100), .excellent)
        XCTAssertEqual(HealthRating.tier(90), .excellent)
        XCTAssertEqual(HealthRating.tier(89), .good)
        XCTAssertEqual(HealthRating.tier(75), .good)
        XCTAssertEqual(HealthRating.tier(74), .fair)
        XCTAssertEqual(HealthRating.tier(60), .fair)
        XCTAssertEqual(HealthRating.tier(59), .poor)
        XCTAssertEqual(HealthRating.tier(40), .poor)
        XCTAssertEqual(HealthRating.tier(39), .critical)
        XCTAssertEqual(HealthRating.tier(0), .critical)
        XCTAssertEqual(HealthRating.tier(-5), .critical)
    }

    func testHealthColorLadderIsCoarserThanLabelLadder() {
        // Deliberate: excellent and good share green — the color ladder has
        // four buckets, the label ladder five. Pinned so the difference
        // stays intentional instead of drifting.
        XCTAssertEqual(HealthRating.color(90), Brand.green)
        XCTAssertEqual(HealthRating.color(75), Brand.green)
        XCTAssertEqual(HealthRating.color(74), Brand.gold)
        XCTAssertEqual(HealthRating.color(60), Brand.gold)
        XCTAssertEqual(HealthRating.color(59), Brand.orange)
        XCTAssertEqual(HealthRating.color(40), Brand.orange)
        XCTAssertEqual(HealthRating.color(39), Brand.red)
    }
}
