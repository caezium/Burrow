//
//  MetricsCore.swift
//  Burrow
//
//  The pure core of the snapshot producer: counter differentiation and
//  snapshot patching as plain functions of their inputs. No I/O, no clock,
//  no IOKit — time and counters arrive as arguments, so the whole bug
//  surface (rates, reset handling, fill-only-holes rules) is unit-testable.
//

import Foundation

/// Differentiates a pair of monotonic byte counters into MB/s. Stateful
/// (keeps the previous counters + timestamp); time is always an argument.
/// Returns nil while there is no usable baseline: first call, a counter
/// regression (reboot / driver replug — rebaselines), or a dt under 50 ms.
struct RateTracker {
    private var last: (a: UInt64, b: UInt64)?
    private var lastAt: Date?

    mutating func mbps(_ a: UInt64, _ b: UInt64, at now: Date) -> (a: Double, b: Double)? {
        defer { last = (a, b); lastAt = now }
        guard let prev = last, let prevAt = lastAt else { return nil }
        let dt = now.timeIntervalSince(prevAt)
        guard dt > 0.05 else { return nil }
        guard a >= prev.a, b >= prev.b else { return nil }
        let mb = 1_048_576.0
        return (Double(a - prev.a) / mb / dt, Double(b - prev.b) / mb / dt)
    }
}

/// The patch rules for `mo status --json`, in one pure function: native
/// readings fill ONLY the holes Mole left — disk rate when it reports 0/0,
/// GPU usage when it reports negative ("unavailable"), thermal zeros inside
/// an existing thermal object (never synthesized — an invented {} would fail
/// to decode). Where Mole reports real values, they always win. Returns the
/// original text verbatim when nothing needed patching or it isn't JSON.
enum SnapshotPatcher {
    struct NativeFill {
        let disk: (read: Double, write: Double)?
        let gpu: Double?
        let fans: (count: Int, rpm: [Int])?
        let cpuTemp: Double?
        let gpuTemp: Double?
    }

    static func patch(json: String, fill: NativeFill) -> String {
        guard let data = json.data(using: .utf8),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return json }

        var changed = false

        // Disk I/O — only when Mole reports nothing.
        let io = root["disk_io"] as? [String: Any]
        let moRead = (io?["read_rate"] as? NSNumber)?.doubleValue ?? 0
        let moWrite = (io?["write_rate"] as? NSNumber)?.doubleValue ?? 0
        if moRead == 0, moWrite == 0, let rate = fill.disk {
            root["disk_io"] = ["read_rate": rate.read, "write_rate": rate.write]
            changed = true
        }

        // GPU usage — only when Mole reports it as unavailable (-1).
        if var gpus = root["gpu"] as? [[String: Any]], !gpus.isEmpty {
            let moUsage = (gpus[0]["usage"] as? NSNumber)?.doubleValue ?? -1
            if moUsage < 0, let util = fill.gpu {
                gpus[0]["usage"] = util
                root["gpu"] = gpus
                changed = true
            }
        }

        // Thermal — fill the zero holes, keep Mole's values (battery_temp…),
        // and only when Mole actually emitted a thermal object.
        if var thermal = root["thermal"] as? [String: Any] {
            var thermalChanged = false
            if (thermal["fan_count"] as? NSNumber)?.intValue ?? 0 == 0,
               let f = fill.fans, f.count > 0 {
                thermal["fan_count"] = f.count
                thermal["fan_speed"] = f.rpm.max() ?? 0
                thermalChanged = true
            }
            if (thermal["cpu_temp"] as? NSNumber)?.doubleValue ?? 0 == 0, let c = fill.cpuTemp {
                thermal["cpu_temp"] = c; thermalChanged = true
            }
            if (thermal["gpu_temp"] as? NSNumber)?.doubleValue ?? 0 == 0, let g = fill.gpuTemp {
                thermal["gpu_temp"] = g; thermalChanged = true
            }
            if thermalChanged { root["thermal"] = thermal; changed = true }
        }

        guard changed,
              let out = try? JSONSerialization.data(withJSONObject: root),
              let str = String(data: out, encoding: .utf8)
        else { return json }
        return str
    }
}
