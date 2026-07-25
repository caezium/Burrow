//
//  MoleStatusDecodeTests.swift
//  BurrowTests
//
//  `MoleStatus` is the STRICT decoder behind the whole dashboard — one `try JSONDecoder().decode`
//  whose failure blanks every pane at once — and until now it had no test of its own. That gap is
//  why a payload change could take the dashboard down without a single red build: MetricTests and
//  FeedsTests decode SYNTHETIC status JSON they write themselves, so they only ever prove the
//  decoder agrees with the test, never that it agrees with the program that feeds it.
//
//  These pin three behaviours the GUI depends on, against a payload captured from the real
//  program (plans/repoint-redo-groundtruth/status.golden.json — re-capture it, never hand-edit it):
//
//    1. the real payload decodes, and its values land where the panes read them;
//    2. the ISO8601 trap — `collected_at` is parsed by a formatter configured WITH fractional
//       seconds, so a timestamp without them (`2026-07-25T10:00:00Z`) THROWS. No structural JSON
//       diff can see that: the key is present, the type is right, the dashboard is still dead;
//    3. the required/optional split — a missing REQUIRED field throws (loud), while a missing
//       OPTIONAL one decodes to nil (silent, and the feature pane just renders empty). Both are
//       failure modes; only one is visible without a test.
//

import XCTest
@testable import Burrow

final class MoleStatusDecodeTests: XCTestCase {

    // MARK: - The real payload

    func testDecode_theRealPayload_landsEveryValueThePanesRead() throws {
        let s = try decode(golden)

        XCTAssertEqual(s.host, "Henrys-MacBook.local")
        XCTAssertEqual(s.platform, "darwin 26.5.2")
        XCTAssertEqual(s.procs, 717)
        XCTAssertEqual(s.uptimeSeconds, 267575)
        XCTAssertEqual(s.healthScore, 73)
        XCTAssertEqual(s.healthScoreMsg, "Good: Disk Almost Full")

        XCTAssertEqual(s.hardware.model, "MacBook Pro")
        XCTAssertEqual(s.hardware.cpuModel, "Apple M4 Pro")
        XCTAssertEqual(s.hardware.osVersion, "macOS 26.5.2")

        XCTAssertEqual(s.cpu.usage, 41.240981239374186)
        XCTAssertEqual(s.cpu.coreCount, 14)
        XCTAssertEqual(s.cpu.perCore?.count, 14, "the per-core bars read this array")
        // Byte counts must stay integer-exact — a Double bridge would round 20_947_140_608.
        XCTAssertEqual(s.memory.used, 20_947_140_608)
        XCTAssertEqual(s.memory.total, 25_769_803_776)
        XCTAssertEqual(s.memory.cached, 3_232_694_272)
        XCTAssertEqual(s.diskIO.readRate, 0)

        XCTAssertEqual(s.disks.count, 2)
        XCTAssertEqual(s.disks.first?.mount, "/")
        XCTAssertEqual(s.disks.first?.total, 494_384_795_648)
        XCTAssertEqual(s.disks.first?.external, false)
        XCTAssertEqual(s.network.count, 3)
        XCTAssertEqual(s.network.first?.name, "en0")
        XCTAssertEqual(s.network.first?.ip, "192.168.1.70")

        // The optional feature panes — populated here, so their absence in a later payload is a
        // REGRESSION rather than "that Mac has no battery".
        XCTAssertEqual(s.batteries?.count, 1)
        XCTAssertEqual(s.batteries?.first?.cycleCount, 595)
        XCTAssertEqual(s.topProcesses?.count, 5)
        XCTAssertEqual(s.topProcesses?.first?.name, "WindowServer")
        XCTAssertEqual(s.topProcesses?.first?.memoryBytes, 90_914_816)
        XCTAssertEqual(s.gpu?.count, 1)
        XCTAssertEqual(s.gpu?.first?.usage, -1, "-1 is Apple Silicon's 'no GPU utilisation', not 0%")
        XCTAssertEqual(s.bluetooth?.count, 7)
        XCTAssertEqual(s.proxy?.host, "127.0.0.1:1082")
        // cpu_temp/gpu_temp are 0 on Apple Silicon; battery_temp is the series that has data.
        XCTAssertEqual(s.thermal?.batteryTemp, 30.69)
        XCTAssertEqual(s.thermal?.bestTemp, 30.69)
    }

    // MARK: - The ISO8601 trap

    func testCollectedAt_withFractionalSeconds_decodesToTheRightInstant() throws {
        // The captured payload's own stamp: 2026-07-16T10:48:50.611799-07:00 = …T17:48:50.611Z.
        // ISO8601DateFormatter keeps milliseconds, so compare with that tolerance.
        let s = try decode(golden)
        XCTAssertEqual(s.collectedAt.timeIntervalSince1970, 1_784_224_130.611, accuracy: 0.001)
    }

    func testCollectedAt_withoutFractionalSeconds_throwsAndTakesTheWholeDashboardWithIt() throws {
        // MoleStatus configures ISO8601DateFormatter with .withFractionalSeconds, and that
        // formatter REJECTS a plain second-precision stamp. The key is present and the type is a
        // String, so a structural diff sees nothing — but every pane goes blank.
        var object = try goldenObject()
        object["collected_at"] = "2026-07-25T10:00:00Z"
        XCTAssertThrowsError(try decode(object)) { error in
            guard case DecodingError.dataCorrupted(let ctx) = error else {
                return XCTFail("expected dataCorrupted for a non-fractional stamp, got \(error)")
            }
            XCTAssertEqual(ctx.codingPath.map(\.stringValue), ["collected_at"])
        }
    }

    // MARK: - Required fields: absent means THROW

    /// Every field `init(from:)` decodes with a plain `decode` (not `decodeIfPresent`), including
    /// the ones nested in `hardware` / `cpu` / `memory` / `disk_io` and inside a `disks` /
    /// `network` row. One loop beats sixteen near-identical test functions, and a typo'd path
    /// fails loudly here rather than passing vacuously: removing a path that doesn't exist leaves
    /// the payload decodable, so the assertion below fires.
    private static let requiredPaths = [
        "collected_at", "host", "platform", "uptime_seconds", "procs",
        "hardware", "hardware.model", "hardware.cpu_model", "hardware.total_ram",
        "hardware.disk_size", "hardware.os_version",
        "health_score",
        "cpu", "cpu.usage", "cpu.load1", "cpu.load5", "cpu.load15",
        "cpu.core_count", "cpu.logical_cpu",
        "memory", "memory.used", "memory.total", "memory.used_percent",
        "memory.swap_used", "memory.swap_total", "memory.pressure",
        "disk_io", "disk_io.read_rate", "disk_io.write_rate",
        "disks.0.mount", "disks.0.used", "disks.0.total", "disks.0.used_percent", "disks.0.external",
        "network.0.name", "network.0.rx_rate_mbs", "network.0.tx_rate_mbs", "network.0.ip",
    ]

    func testRequiredFields_removedOneAtATime_makeDecodeThrow() throws {
        let object = try goldenObject()
        for path in Self.requiredPaths {
            let mutated = Self.removing(path, from: object)
            XCTAssertThrowsError(try decode(mutated),
                                 "dropping `\(path)` must throw — a required field that quietly "
                                 + "defaults would render a plausible, wrong dashboard") { error in
                guard case DecodingError.keyNotFound(let key, _) = error else {
                    return XCTFail("dropping `\(path)` threw \(error), expected keyNotFound")
                }
                XCTAssertTrue(path.hasSuffix(key.stringValue),
                              "dropping `\(path)` should be reported against that key, "
                              + "not `\(key.stringValue)`")
            }
        }
    }

    func testProcs_asAString_throwsTypeMismatch() throws {
        // The likeliest engine drift after a missing key: a number arriving quoted.
        var object = try goldenObject()
        object["procs"] = "717"
        XCTAssertThrowsError(try decode(object)) { error in
            guard case DecodingError.typeMismatch = error else {
                return XCTFail("expected typeMismatch for a quoted number, got \(error)")
            }
        }
    }

    // MARK: - Optional fields: absent means a DEAD PANE, not a throw

    func testOptionalPanes_removedOneAtATime_decodeFineAndLeaveThePaneEmpty() throws {
        // This is the silent half of the contract. Each of these is `decodeIfPresent`, so its
        // absence costs a feature — the battery ring, the thermal chart, the process table — with
        // no error anywhere. CI can't fail on that, but it CAN pin that it's the behaviour, so a
        // blank pane is diagnosed as a missing field instead of a broken view.
        let object = try goldenObject()
        for key in ["batteries", "thermal", "top_processes", "gpu", "proxy", "bluetooth"] {
            XCTAssertNoThrow(try decode(Self.removing(key, from: object)),
                             "`\(key)` is Optional: dropping it must NOT throw")
        }

        var stripped = object
        for key in ["batteries", "thermal", "top_processes", "gpu", "proxy", "bluetooth"] {
            stripped.removeValue(forKey: key)
        }
        let s = try decode(stripped)
        XCTAssertNil(s.batteries)
        XCTAssertNil(s.thermal)
        XCTAssertNil(s.topProcesses)
        XCTAssertNil(s.gpu)
        XCTAssertNil(s.proxy)
        XCTAssertNil(s.bluetooth)
        // …while the required spine still decoded, which is exactly what makes it silent.
        XCTAssertEqual(s.host, "Henrys-MacBook.local")
        XCTAssertEqual(s.procs, 717)
    }

    func testDisksAndNetwork_absent_decodeToEmptyArraysNotNil() throws {
        // A third state, and the one that reads as a bug report: `decodeIfPresent ?? []` means a
        // missing `disks` key is indistinguishable from a Mac with no disks.
        var object = try goldenObject()
        object.removeValue(forKey: "disks")
        object.removeValue(forKey: "network")
        object.removeValue(forKey: "health_score_msg")
        let s = try decode(object)
        XCTAssertEqual(s.disks, [])
        XCTAssertEqual(s.network, [])
        XCTAssertEqual(s.healthScoreMsg, "", "health_score_msg degrades to empty, it never throws")
    }

    func testUnknownKeys_areIgnored() throws {
        // The payload already carries fields the struct doesn't model (uptime, trash_size,
        // sensors, process_watch, hardware.refresh_rate, cpu.per_core_estimated). Adding more
        // upstream must stay non-breaking.
        var object = try goldenObject()
        object["a_field_from_a_future_engine"] = ["anything": [1, 2, 3]]
        XCTAssertNoThrow(try decode(object))
    }

    // MARK: - Helpers

    private func decode(_ json: String) throws -> MoleStatus {
        try JSONDecoder().decode(MoleStatus.self, from: Data(json.utf8))
    }

    private func decode(_ object: [String: Any]) throws -> MoleStatus {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(MoleStatus.self, from: data)
    }

    private func goldenObject() throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(golden.utf8)) as? [String: Any])
    }

    /// The payload minus one dotted path — `cpu.load1`, `disks.0.external`. A numeric component
    /// indexes an array; an unknown component is a no-op (and the caller's assertion catches it).
    private static func removing(_ path: String, from object: [String: Any]) -> [String: Any] {
        remove(path.split(separator: ".").map(String.init)[...], from: object) as? [String: Any]
            ?? object
    }

    private static func remove(_ parts: ArraySlice<String>, from value: Any) -> Any {
        guard let head = parts.first else { return value }
        let rest = parts.dropFirst()
        if var dict = value as? [String: Any] {
            if rest.isEmpty {
                dict.removeValue(forKey: head)
            } else if let child = dict[head] {
                dict[head] = remove(rest, from: child)
            }
            return dict
        }
        if var array = value as? [Any], let i = Int(head), array.indices.contains(i) {
            if rest.isEmpty {
                array.remove(at: i)
            } else {
                array[i] = remove(rest, from: array[i])
            }
            return array
        }
        return value
    }

    // MARK: - The captured payload
    //
    // Verbatim `burrow status` output from the shipping program (the `data` payload, envelope
    // unwrapped). Kept whole on purpose: a trimmed fixture only proves the decoder agrees with
    // whoever trimmed it. Re-capture from the real program; don't edit by hand.

    private let golden = """
    {
      "collected_at": "2026-07-16T10:48:50.611799-07:00",
      "host": "Henrys-MacBook.local",
      "platform": "darwin 26.5.2",
      "uptime": "3d 2h",
      "uptime_seconds": 267575,
      "procs": 717,
      "hardware": {
        "model": "MacBook Pro",
        "cpu_model": "Apple M4 Pro",
        "total_ram": "24.0 GB",
        "disk_size": "460.4 GB",
        "os_version": "macOS 26.5.2",
        "refresh_rate": ""
      },
      "health_score": 73,
      "health_score_msg": "Good: Disk Almost Full",
      "cpu": {
        "usage": 41.240981239374186,
        "per_core": [
          55.555555559148615,
          44.44444444085138,
          40.000000023283064,
          44.44444445702017,
          11.111111118297243,
          19.999999994179234,
          27.272727275132546,
          19.999999988358468,
          9.999999979627319,
          54.54545455026509,
          59.9999999825377,
          69.9999999825377,
          60.000000005820766,
          59.999999994179234
        ],
        "per_core_estimated": false,
        "load1": 5.96484375,
        "load5": 7.1875,
        "load15": 6.796875,
        "core_count": 14,
        "logical_cpu": 14,
        "p_core_count": 10,
        "e_core_count": 4
      },
      "gpu": [
        {
          "name": "Apple M4 Pro",
          "usage": -1,
          "memory_used": 0,
          "memory_total": 0,
          "core_count": 20,
          "note": "sppci_vendor_Apple"
        }
      ],
      "memory": {
        "used": 20947140608,
        "total": 25769803776,
        "available": 4822663168,
        "used_percent": 81.28560384114583,
        "swap_used": 12517769216,
        "swap_total": 13958643712,
        "cached": 3232694272,
        "pressure": ""
      },
      "disks": [
        {
          "mount": "/",
          "device": "/dev/disk3s1s1",
          "used": 487365140480,
          "total": 494384795648,
          "used_percent": 98.58012316928169,
          "fstype": "apfs",
          "external": false
        },
        {
          "mount": "/Library/Developer/CoreSimulator/Volumes/iOS_23B86",
          "device": "/dev/disk5s1",
          "used": 17111867392,
          "total": 17572036608,
          "used_percent": 97.3812414220074,
          "fstype": "apfs",
          "external": true
        }
      ],
      "trash_size": 616010685,
      "trash_approx": false,
      "disk_io": {
        "read_rate": 0,
        "write_rate": 0
      },
      "network": [
        {
          "name": "en0",
          "rx_rate_mbs": 0.018720626831054688,
          "tx_rate_mbs": 0.001373291015625,
          "ip": "192.168.1.70"
        },
        {
          "name": "en4",
          "rx_rate_mbs": 0,
          "tx_rate_mbs": 0,
          "ip": ""
        },
        {
          "name": "en5",
          "rx_rate_mbs": 0,
          "tx_rate_mbs": 0,
          "ip": ""
        }
      ],
      "network_history": {
        "rx_history": [
          0.018720626831054688
        ],
        "tx_history": [
          0.001373291015625
        ]
      },
      "proxy": {
        "enabled": true,
        "type": "HTTP",
        "host": "127.0.0.1:1082"
      },
      "batteries": [
        {
          "percent": 100,
          "status": "discharging",
          "time_left": "4:52",
          "health": "Good",
          "cycle_count": 595,
          "capacity": 91
        }
      ],
      "thermal": {
        "cpu_temp": 0,
        "gpu_temp": 0,
        "battery_temp": 30.69,
        "fan_speed": 0,
        "fan_count": 0,
        "system_power": 0,
        "adapter_power": 0,
        "battery_power": -21.568
      },
      "sensors": null,
      "bluetooth": [
        {
          "name": "Rainy 75-1",
          "connected": false,
          "battery": ""
        },
        {
          "name": "DualSense Wireless Controller",
          "connected": false,
          "battery": ""
        },
        {
          "name": "henry’s Mac Studio",
          "connected": false,
          "battery": ""
        },
        {
          "name": "Henwy’s Ipad",
          "connected": false,
          "battery": ""
        },
        {
          "name": "Hidden Network",
          "connected": false,
          "battery": ""
        },
        {
          "name": "K1 LITE_5.0 ",
          "connected": false,
          "battery": ""
        },
        {
          "name": "MOMENTUM 4",
          "connected": false,
          "battery": ""
        }
      ],
      "top_processes": [
        {
          "pid": 602,
          "ppid": 1,
          "name": "WindowServer",
          "command": "WindowServer",
          "cpu": 43.9,
          "memory": 0.4,
          "memory_bytes": 90914816
        },
        {
          "pid": 74492,
          "ppid": 1,
          "name": "zen",
          "command": "zen",
          "cpu": 41.1,
          "memory": 3.3,
          "memory_bytes": 848871424
        },
        {
          "pid": 1369,
          "ppid": 1,
          "name": "Finder",
          "command": "Finder",
          "cpu": 33.5,
          "memory": 0.2,
          "memory_bytes": 45006848
        },
        {
          "pid": 1159,
          "ppid": 1,
          "name": "fileproviderd",
          "command": "fileproviderd",
          "cpu": 31.1,
          "memory": 0.2,
          "memory_bytes": 48431104
        },
        {
          "pid": 49964,
          "ppid": 49963,
          "name": "claude",
          "command": "claude",
          "cpu": 23.7,
          "memory": 0.8,
          "memory_bytes": 217563136
        }
      ],
      "process_watch": {
        "enabled": true,
        "cpu_threshold": 100,
        "window": "5m0s"
      },
      "process_alerts": []
    }
    """
}
