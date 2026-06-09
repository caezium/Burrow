//
//  IOMonitor.swift
//  Burrow
//
//  One always-on, high-cadence reader for the two burstiest metrics —
//  network throughput and disk I/O. `mo status` reports both at the slow
//  sampler cadence (5–60 s), which is far too coarse: a file copy or a
//  download is a 1–2 s spike that lands between ticks and never shows up.
//
//  This reads the raw counters natively every second (network via
//  getifaddrs/if_data, disk via IOBlockStorageDriver) and keeps an in-memory
//  ring (~1 h) of timestamped samples. Both the live Home tiles AND the
//  History net/disk charts read from it, so they update at the SAME rate —
//  no per-second rows in the database. A shared singleton because it's
//  app-global state with no per-view lifecycle.
//

import Foundation
import Combine
import IOKit

@MainActor
final class IOMonitor: ObservableObject {
    static let shared = IOMonitor()

    struct Sample {
        let time: Date
        let rxMBs: Double
        let txMBs: Double
        let readMBs: Double
        let writeMBs: Double
    }

    /// Current per-second rates (MB/s).
    @Published private(set) var rxMBs = 0.0
    @Published private(set) var txMBs = 0.0
    @Published private(set) var readMBs = 0.0
    @Published private(set) var writeMBs = 0.0
    /// Timestamped ring, oldest → newest. Capped to `window` seconds.
    @Published private(set) var samples: [Sample] = []

    private let interval: TimeInterval = 1.0
    private let window = 3600          // keep ~1 h at 1 s
    private var timer: Timer?

    private var lastNet: (rx: UInt64, tx: UInt64)?
    private var lastDisk: (read: UInt64, write: UInt64)?
    private var lastAt: Date?

    private init() {}

    func start() {
        guard timer == nil else { return }
        lastNet = Self.netCounters(); lastDisk = Self.diskCounters(); lastAt = Date()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// Convenience series for sparklines (total rx+tx / read+write).
    var netHistory: [Double] { samples.map { $0.rxMBs + $0.txMBs } }
    var diskHistory: [Double] { samples.map { $0.readMBs + $0.writeMBs } }

    private func tick() {
        let now = Date()
        guard let prevAt = lastAt else { lastAt = now; return }
        let dt = now.timeIntervalSince(prevAt)
        guard dt > 0.05 else { return }
        let mb = 1_048_576.0

        if let net = Self.netCounters(), let prev = lastNet, net.rx >= prev.rx, net.tx >= prev.tx {
            rxMBs = Double(net.rx - prev.rx) / mb / dt
            txMBs = Double(net.tx - prev.tx) / mb / dt
            lastNet = net
        } else if let net = Self.netCounters() { lastNet = net }

        if let disk = Self.diskCounters(), let prev = lastDisk, disk.read >= prev.read, disk.write >= prev.write {
            readMBs = Double(disk.read - prev.read) / mb / dt
            writeMBs = Double(disk.write - prev.write) / mb / dt
            lastDisk = disk
        } else if let disk = Self.diskCounters() { lastDisk = disk }

        lastAt = now
        samples.append(Sample(time: now, rxMBs: rxMBs, txMBs: txMBs, readMBs: readMBs, writeMBs: writeMBs))
        if samples.count > window { samples.removeFirst(samples.count - window) }
    }

    // MARK: - Native counters

    private static func netCounters() -> (rx: UInt64, tx: UInt64)? {
        var rx: UInt64 = 0, tx: UInt64 = 0
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let ifa = p.pointee; ptr = ifa.ifa_next
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let name = String(cString: ifa.ifa_name)
            if name.hasPrefix("lo") || name.hasPrefix("gif") || name.hasPrefix("stf") { continue }
            guard let raw = ifa.ifa_data else { continue }
            let d = raw.assumingMemoryBound(to: if_data.self).pointee
            rx += UInt64(d.ifi_ibytes); tx += UInt64(d.ifi_obytes)
        }
        return (rx, tx)
    }

    private static func diskCounters() -> (read: UInt64, write: UInt64)? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iter) }
        var r: UInt64 = 0, w: UInt64 = 0, found = false
        var svc = IOIteratorNext(iter)
        while svc != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let stats = dict["Statistics"] as? [String: Any] {
                if let rr = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value { r += rr; found = true }
                if let ww = (stats["Bytes (Write)"] as? NSNumber)?.uint64Value { w += ww; found = true }
            }
            IOObjectRelease(svc); svc = IOIteratorNext(iter)
        }
        return found ? (r, w) : nil
    }
}
