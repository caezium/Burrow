//
//  LocalMetrics.swift
//  Burrow
//
//  Native IOKit readers for the two metrics Mole's `status --json` can't
//  deliver on Apple Silicon / macOS 26:
//
//    * Disk I/O throughput — `mo status` reports `disk_io.read_rate` and
//      `write_rate` as 0 even under heavy load here, so the chart was a flat
//      line. We sum IOBlockStorageDriver byte counters and differentiate
//      across sampler ticks to get MB/s.
//    * GPU utilisation — `mo status` reports `gpu[].usage == -1` (unavailable)
//      on Apple Silicon, so the GPU tile read "—". The IOAccelerator registry
//      entry exposes `Device Utilization %`, which is exactly what Activity
//      Monitor and istatistics-style tools read.
//
//  These are *fallbacks*: the Sampler only injects them into the snapshot when
//  Mole's own values are missing (0 disk rate / negative GPU usage), so on a
//  platform where Mole reports them we keep Mole's numbers and the contract
//  stays "the snapshot is whatever the sampler stored".
//

import Foundation
import IOKit

/// Stateful reader: disk throughput is a rate, so it needs the previous byte
/// counters + timestamp to differentiate. One instance lives on the Sampler.
final class LocalMetrics {
    private var lastDiskRead: UInt64 = 0
    private var lastDiskWrite: UInt64 = 0
    private var lastDiskAt: Date?
    private let sensors = SensorReader()

    init() {}

    // MARK: - Disk I/O

    /// Cumulative bytes read/written across every IOBlockStorageDriver. These
    /// are monotonic since boot; the rate is their delta over time.
    private func diskByteCounters() -> (read: UInt64, write: UInt64)? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"),
                                           &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }

        var totalR: UInt64 = 0, totalW: UInt64 = 0, found = false
        var svc = IOIteratorNext(iter)
        while svc != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let stats = dict["Statistics"] as? [String: Any] {
                if let r = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value { totalR += r; found = true }
                if let w = (stats["Bytes (Write)"] as? NSNumber)?.uint64Value { totalW += w; found = true }
            }
            IOObjectRelease(svc)
            svc = IOIteratorNext(iter)
        }
        return found ? (totalR, totalW) : nil
    }

    /// Read/write throughput in MB/s since the previous call. Returns nil on the
    /// first call (no baseline yet) or if the counters are unreadable. Averaged
    /// over the inter-tick interval — for a 60 s sampler that's a windowed
    /// average, which reads more honestly on a chart than an instantaneous spike.
    func diskRateMBs() -> (read: Double, write: Double)? {
        guard let now = diskByteCounters() else { return nil }
        let at = Date()
        defer { lastDiskRead = now.read; lastDiskWrite = now.write; lastDiskAt = at }
        guard let prevAt = lastDiskAt else { return nil }
        let dt = at.timeIntervalSince(prevAt)
        guard dt > 0.05 else { return nil }
        // Counters reset (reboot / driver replug) → skip this delta.
        guard now.read >= lastDiskRead, now.write >= lastDiskWrite else { return nil }
        let mb = 1_048_576.0
        return (Double(now.read - lastDiskRead) / mb / dt,
                Double(now.write - lastDiskWrite) / mb / dt)
    }

    // MARK: - GPU

    /// GPU busy percent (0–100) from the IOAccelerator `Device Utilization %`
    /// performance counter, or nil if no accelerator exposes it. Takes the max
    /// across accelerators (a Mac with discrete + integrated reports both).
    func gpuUtilization() -> Double? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }

        var best: Double? = nil
        var svc = IOIteratorNext(iter)
        while svc != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let perf = dict["PerformanceStatistics"] as? [String: Any],
               let util = (perf["Device Utilization %"] as? NSNumber)?.doubleValue {
                best = max(best ?? 0, util)
            }
            IOObjectRelease(svc)
            svc = IOIteratorNext(iter)
        }
        return best
    }

    // MARK: - Snapshot patching

    /// Inject native disk-I/O and GPU readings into Mole's `status --json` text,
    /// but only where Mole left a hole: disk rate is overwritten only when Mole
    /// reports 0/0 (so a platform where `mo` works keeps its values), and GPU
    /// usage only when Mole reports a negative ("unavailable") number. Returns
    /// the patched JSON string, or the original if nothing needed patching /
    /// the JSON couldn't be parsed.
    func patched(json: String) -> String {
        guard let data = json.data(using: .utf8),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return json }

        var changed = false

        // Disk I/O — only when Mole reports nothing.
        let io = root["disk_io"] as? [String: Any]
        let moRead = (io?["read_rate"] as? NSNumber)?.doubleValue ?? 0
        let moWrite = (io?["write_rate"] as? NSNumber)?.doubleValue ?? 0
        if moRead == 0, moWrite == 0, let rate = diskRateMBs() {
            root["disk_io"] = ["read_rate": rate.read, "write_rate": rate.write]
            changed = true
        }

        // GPU usage — only when Mole reports it as unavailable (-1).
        if var gpus = root["gpu"] as? [[String: Any]], !gpus.isEmpty {
            let moUsage = (gpus[0]["usage"] as? NSNumber)?.doubleValue ?? -1
            if moUsage < 0, let util = gpuUtilization() {
                gpus[0]["usage"] = util
                root["gpu"] = gpus
                changed = true
            }
        }

        // Thermal — fans + die temps Mole reports as 0 on Apple Silicon, read
        // natively from the SMC. Only patch when Mole actually emitted a thermal
        // object (never synthesize one — an empty {} would fail to decode), and
        // only fill the holes, keeping Mole's values (e.g. battery_temp).
        if var thermal = root["thermal"] as? [String: Any] {
            var thermalChanged = false
            if (thermal["fan_count"] as? NSNumber)?.intValue ?? 0 == 0 {
                let f = sensors.fans()
                if f.count > 0 {
                    thermal["fan_count"] = f.count
                    thermal["fan_speed"] = f.rpm.max() ?? 0
                    thermalChanged = true
                }
            }
            if (thermal["cpu_temp"] as? NSNumber)?.doubleValue ?? 0 == 0, let c = sensors.temps().cpu {
                thermal["cpu_temp"] = c; thermalChanged = true
            }
            if (thermal["gpu_temp"] as? NSNumber)?.doubleValue ?? 0 == 0, let g = sensors.temps().gpu {
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
