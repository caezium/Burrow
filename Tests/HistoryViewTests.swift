//
//  HistoryViewTests.swift
//  BurrowTests
//
//  The bar-chart down-sample cap (#57): a 90-day range stride-samples to
//  720 points, and a BarMark per point is a SwiftUI layout node — 720 ×
//  several bar cards drove the layout engine into a recursive explosion
//  (a ≥2 s main-thread hang). capBars bounds the mark count to something a
//  card can actually render, evenly, keeping the first and last sample.
//

import XCTest
@testable import Burrow

final class HistoryViewTests: XCTestCase {
    private func points(_ n: Int) -> [ChartPoint] {
        (0..<n).map { ChartPoint(time: Date(timeIntervalSince1970: TimeInterval($0)),
                                 value: Double($0)) }
    }

    func testCapBars_underCapIsUnchanged() {
        let pts = points(100)
        let capped = HistoryView.capBars(pts, max: 140)
        XCTAssertEqual(capped.count, 100)
        XCTAssertEqual(capped.map(\.value), pts.map(\.value))
    }

    func testCapBars_atCapIsUnchanged() {
        XCTAssertEqual(HistoryView.capBars(points(140), max: 140).count, 140)
    }

    func testCapBars_overCapStridesDownToCap() {
        // The worst case: a 90-day range stride-sampled to 720 points.
        let capped = HistoryView.capBars(points(720), max: 140)
        XCTAssertEqual(capped.count, 140, "bounded to the cap so layout can't explode")
    }

    func testCapBars_keepsFirstAndLastSample() {
        let pts = points(720)
        let capped = HistoryView.capBars(pts, max: 140)
        XCTAssertEqual(capped.first?.value, pts.first?.value)
        XCTAssertEqual(capped.last?.value, pts.last?.value)
    }

    func testCapBars_preservesAscendingOrder() {
        let capped = HistoryView.capBars(points(500), max: 120)
        XCTAssertEqual(capped.map(\.value), capped.map(\.value).sorted(),
                       "down-sampling must not reorder time")
    }

    func testCapBars_emptyAndTiny() {
        XCTAssertTrue(HistoryView.capBars([], max: 140).isEmpty)
        XCTAssertEqual(HistoryView.capBars(points(1), max: 140).count, 1)
    }
}
