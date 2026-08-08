//
//  DoctorTests.swift
//  BurrowTests
//
//  The diagnostics verdict composer (roadmap I), tested through `report`.
//

import XCTest
@testable import Burrow

final class DoctorTests: XCTestCase {
    private func healthy() -> Doctor.Input {
        .init(fullDiskAccess: true, moInstalled: true, pressure: .normal,
              diskFreeBytes: 200_000_000_000, diskTotalBytes: 500_000_000_000,
              recentErrorCount: 0, lastBackupDaysAgo: 1, smartVerified: true)
    }

    private func check(_ report: [Doctor.Check], _ name: String) -> Doctor.Check? {
        report.first { $0.name == name }
    }

    func testReport_healthyMachine_allOK() {
        let r = Doctor.report(healthy())
        XCTAssertEqual(r.count, 7)
        XCTAssertTrue(r.allSatisfy { $0.level == .ok })
    }

    func testReport_staleBackup_warns() {
        var i = healthy(); i.lastBackupDaysAgo = 26
        XCTAssertEqual(check(Doctor.report(i), "Backups")?.level, .warn)
    }

    func testReport_noBackup_warns() {
        var i = healthy(); i.lastBackupDaysAgo = nil
        XCTAssertEqual(check(Doctor.report(i), "Backups")?.level, .warn)
    }

    func testReport_smartFailing_fails() {
        var i = healthy(); i.smartVerified = false
        XCTAssertEqual(check(Doctor.report(i), "Disk health")?.level, .fail)
    }

    func testReport_noEngine_fails() {
        var i = healthy(); i.moInstalled = false
        XCTAssertEqual(check(Doctor.report(i), "Engine")?.level, .fail)
    }

    func testReport_noFullDiskAccess_warns() {
        var i = healthy(); i.fullDiskAccess = false
        let c = check(Doctor.report(i), "Full Disk Access")
        XCTAssertEqual(c?.level, .warn)
        XCTAssertTrue(c?.detail.hasPrefix("off") == true)
    }

    // When no probe location existed to refuse us, Doctor must not assert the
    // permission is off — that false negative is what kept users re-granting
    // it to no effect on macOS 27 betas (#177, #181, #319).
    func testReport_inconclusiveFullDiskAccess_warnsWithoutClaimingOff() {
        var i = healthy()
        i.fullDiskAccess = false
        i.fullDiskAccessConclusive = false
        let c = check(Doctor.report(i), "Full Disk Access")
        XCTAssertEqual(c?.level, .warn)
        XCTAssertFalse(c?.detail.hasPrefix("off") == true,
                       "an undetermined probe must not be reported as a denial")
        XCTAssertTrue(c?.detail.contains("could not be determined") == true)
    }

    // A live grant is reported the same way regardless of the conclusive bit.
    func testReport_grantedFullDiskAccess_ignoresConclusiveFlag() {
        var i = healthy()
        i.fullDiskAccess = true
        i.fullDiskAccessConclusive = false
        XCTAssertEqual(check(Doctor.report(i), "Full Disk Access")?.level, .ok)
    }

    func testReport_criticalPressure_fails() {
        var i = healthy(); i.pressure = .critical
        XCTAssertEqual(check(Doctor.report(i), "Memory pressure")?.level, .fail)
    }

    func testReport_diskNearlyFull_fails() {
        var i = healthy()
        i.diskFreeBytes = 10_000_000_000  // 2% of 500 GB
        XCTAssertEqual(check(Doctor.report(i), "Disk space")?.level, .fail)
    }

    func testReport_diskTight_warns() {
        var i = healthy()
        i.diskFreeBytes = 40_000_000_000  // 8% of 500 GB
        XCTAssertEqual(check(Doctor.report(i), "Disk space")?.level, .warn)
    }

    func testReport_recentErrors_warn() {
        var i = healthy(); i.recentErrorCount = 3
        let c = check(Doctor.report(i), "Recent errors")
        XCTAssertEqual(c?.level, .warn)
        XCTAssertTrue(c?.detail.contains("3") ?? false)
    }

    func testReport_sortableWorstFirst() {
        var i = healthy(); i.moInstalled = false; i.pressure = .critical
        let worst = Doctor.report(i).max { $0.level.rawValue < $1.level.rawValue }
        XCTAssertEqual(worst?.level, .fail, "Level.rawValue orders ok<warn<fail for sorting")
    }

    func testReport_securityAllOn_okAndAppended() {
        var i = healthy()
        i.sip = .on; i.gatekeeper = .on; i.fileVault = .on; i.firewall = .on
        let r = Doctor.report(i)
        XCTAssertEqual(check(r, "Security")?.level, .ok)
        XCTAssertEqual(r.count, 8)   // 7 + Security
    }

    func testReport_securityFacetOff_warns() {
        var i = healthy()
        i.sip = .on; i.gatekeeper = .on; i.fileVault = .off; i.firewall = .on
        let c = check(Doctor.report(i), "Security")
        XCTAssertEqual(c?.level, .warn)
        XCTAssertTrue(c?.detail.contains("FileVault") ?? false)
    }

    func testReport_securityUnknown_omitted() {
        XCTAssertNil(check(Doctor.report(healthy()), "Security"))  // healthy() leaves facets .unknown
    }

    func testReport_highCPU_warns() {
        var hot = healthy(); hot.cpuLoadPercent = 95
        XCTAssertEqual(check(Doctor.report(hot), "CPU load")?.level, .warn)
        var calm = healthy(); calm.cpuLoadPercent = 20
        XCTAssertEqual(check(Doctor.report(calm), "CPU load")?.level, .ok)
    }
}
