//
//  Format.swift
//  Burrow
//
//  The shared presentation vocabulary: every number-to-string rule the views
//  render lives here, behind golden tests (FormatTests). Rendered strings are
//  load-bearing — five views and two localizations depend on them — so a
//  change here is a deliberate golden-file edit, never a drive-by.
//

import SwiftUI

enum Fmt {
    static func gb(_ v: Double) -> String {
        v < 10 ? String(format: "%.2f", v) : String(format: "%.0f", v)
    }
    static func bytes(_ b: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(b); var i = 0
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        let s = (i == 0) ? "\(Int(v))" : String(format: v < 10 ? "%.2f" : "%.1f", v)
        return "\(s) \(units[i])"
    }
    /// Bytes → binary gigabytes. The only home of the 1_073_741_824 constant.
    static func gib(_ bytes: Double) -> Double { bytes / 1_073_741_824 }
    static func gib(_ bytes: UInt64) -> Double { Double(bytes) / 1_073_741_824 }
    /// Net-rate, footnote form ("↓ 512 KB/s"). Truncates KB/s — pinned;
    /// the tile form below rounds instead. Two renderings, named apart.
    static func rate(_ mbs: Double) -> String {
        mbs < 1 ? "\(Int(mbs * 1024)) KB/s" : String(format: "%.1f MB/s", mbs)
    }
    /// Net-rate, tile form: value and unit rendered separately. The two
    /// screens genuinely differ in MB/s precision (Status 2, HUD 1), so the
    /// caller states it instead of hiding it in a copy-pasted formatter.
    static func rateParts(_ mbs: Double, mbDecimals: Int) -> (value: String, unit: String) {
        mbs < 1 ? (String(format: "%.0f", mbs * 1024), "KB/s")
                : (String(format: "%.\(mbDecimals)f", mbs), "MB/s")
    }
    static func uptime(_ secs: UInt64) -> String {
        let d = secs / 86_400, h = (secs % 86_400) / 3_600, m = (secs % 3_600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()
    static func day(_ date: Date) -> String { dayFmt.string(from: date) }
    /// Operation timer: seconds under a minute, then m:ss. Clamps skew to 0s.
    static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s < 60 ? "\(s)s" : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Health-score semantics shared by the dashboard and the menu-bar HUD.
/// `tier` is the only threshold switch; label and color derive from it so
/// the two ladders can never drift apart by accident.
enum HealthRating {
    enum Tier { case excellent, good, fair, poor, critical }

    static func tier(_ score: Int) -> Tier {
        switch score {
        case 90...:   return .excellent
        case 75..<90: return .good
        case 60..<75: return .fair
        case 40..<60: return .poor
        default:      return .critical
        }
    }

    static func label(_ score: Int) -> String {
        switch tier(score) {
        case .excellent: return NSLocalizedString("Excellent", comment: "")
        case .good:      return NSLocalizedString("Good", comment: "")
        case .fair:      return NSLocalizedString("Fair", comment: "")
        case .poor:      return NSLocalizedString("Poor", comment: "")
        case .critical:  return NSLocalizedString("Critical", comment: "")
        }
    }

    static func color(_ score: Int) -> Color {
        // Deliberately coarser than the label ladder: excellent and good
        // share green. Pinned by FormatTests.
        switch tier(score) {
        case .excellent, .good: return Brand.green
        case .fair:             return Brand.gold
        case .poor:             return Brand.orange
        case .critical:         return Brand.red
        }
    }
}
