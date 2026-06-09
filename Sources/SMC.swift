//
//  SMC.swift
//  Burrow
//
//  Minimal, read-only Apple SMC client — fans and on-die temperatures that
//  `mo status` leaves at 0 on Apple Silicon. Reading SMC keys needs no
//  privileged helper (only *changing* fan speed would); this just opens the
//  AppleSMC user client and reads.
//
//  The struct layout is ported verbatim from Stats (exelban/stats) — the
//  `padding` field between `keyInfo` and `result` is load-bearing; without it
//  the kernel struct misaligns and every read returns 0/garbage.
//

import Foundation
import IOKit

final class SMC {
    static let shared = SMC()

    private var conn: io_connect_t = 0
    private let available: Bool

    private init() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { available = false; return }
        let rc = IOServiceOpen(svc, mach_task_self_, 0, &conn)
        IOObjectRelease(svc)
        available = (rc == kIOReturnSuccess)
    }

    // MARK: - Kernel struct (ported from Stats)

    private struct KeyData {
        typealias Bytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                           UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                           UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                           UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
        struct Vers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
        struct Limit { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
        struct Info { var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0 }
        var key: UInt32 = 0
        var vers = Vers()
        var limit = Limit()
        var info = Info()
        var padding: UInt16 = 0     // load-bearing — do not remove
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    }

    private static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    private static func typeStr(_ t: UInt32) -> String {
        String(UnicodeScalar(t >> 24 & 0xff)!) + String(UnicodeScalar(t >> 16 & 0xff)!)
            + String(UnicodeScalar(t >> 8 & 0xff)!) + String(UnicodeScalar(t & 0xff)!)
    }

    private func call(_ input: inout KeyData, _ output: inout KeyData) -> kern_return_t {
        var outSize = MemoryLayout<KeyData>.stride
        return IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<KeyData>.stride, &output, &outSize)
    }

    /// Read a key's raw type + bytes (two calls: key-info then read-bytes).
    private func readRaw(_ key: String) -> (type: String, bytes: [UInt8])? {
        guard available else { return nil }
        var input = KeyData(); input.key = Self.fourCC(key); input.data8 = 9   // read key info
        var output = KeyData()
        guard call(&input, &output) == kIOReturnSuccess else { return nil }
        let size = Int(output.info.dataSize)
        guard size > 0 else { return nil }
        let type = Self.typeStr(output.info.dataType)
        input.info.dataSize = output.info.dataSize
        input.data8 = 5   // read bytes
        guard call(&input, &output) == kIOReturnSuccess else { return nil }
        var arr = [UInt8](repeating: 0, count: 32)
        withUnsafeBytes(of: output.bytes) { buf in for i in 0..<min(size, 32) { arr[i] = buf[i] } }
        return (type, Array(arr.prefix(max(size, 4))))
    }

    /// Decode a key to a Double, handling the SMC numeric types Burrow reads.
    func double(_ key: String) -> Double? {
        guard let r = readRaw(key) else { return nil }
        let b = r.bytes
        switch r.type {
        case "flt ": return Double(b.prefix(4).withUnsafeBytes { $0.load(as: Float.self) })
        case "ui8 ": return Double(b[0])
        case "ui16": return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32": return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        case "fpe2": return Double((Int(b[0]) << 6) + (Int(b[1]) >> 2))
        case "sp78": return Double(Int(b[0]) * 256 + Int(b[1])) / 256
        default:     return nil
        }
    }

    /// The four-char key at an enumeration index (used once to discover sensors).
    private func keyAt(_ index: Int) -> String? {
        guard available else { return nil }
        var input = KeyData(); input.data8 = 8; input.data32 = UInt32(index)   // read by index
        var output = KeyData()
        guard call(&input, &output) == kIOReturnSuccess else { return nil }
        return Self.typeStr(output.key)
    }

    /// Every key name the SMC exposes (a few thousand). Call sparingly.
    func allKeys() -> [String] {
        guard available, let count = double("#KEY") else { return [] }
        return (0..<Int(count)).compactMap { keyAt($0) }
    }
}

// MARK: - Sensors

/// Fans + on-die temperatures from the SMC, shaped for the snapshot patch.
/// Temp-sensor keys vary per chip, so they're discovered once (a key sweep)
/// then cached and re-read cheaply each sample.
final class SensorReader {
    private let smc = SMC.shared
    private var cpuTempKeys: [String]?
    private var gpuTempKeys: [String]?

    /// (fan count, actual RPM per fan). RPM 0 is valid — a cool Mac parks its fans.
    func fans() -> (count: Int, rpm: [Int]) {
        guard let n = smc.double("FNum"), n > 0 else { return (0, []) }
        let count = Int(n)
        let rpm = (0..<count).map { Int((smc.double("F\($0)Ac") ?? 0).rounded()) }
        return (count, rpm)
    }

    /// Representative CPU and GPU die temperatures (°C), averaged over the chip's
    /// cluster sensors. Nil when nothing readable. Approximate by design — the
    /// SoC exposes dozens of sensors and there's no single "the CPU temp" key.
    func temps() -> (cpu: Double?, gpu: Double?) {
        discoverIfNeeded()
        let cpu = average(cpuTempKeys ?? [])
        let gpu = average(gpuTempKeys ?? [])
        return (cpu, gpu)
    }

    private func average(_ keys: [String]) -> Double? {
        let vals = keys.compactMap { smc.double($0) }.filter { $0 >= 10 && $0 <= 105 }
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    /// One-time sweep: classify die-temp sensors by name prefix. CPU clusters are
    /// "Te"/"TC" (efficiency / CPU), GPU is "Tg"; skin/battery/VRM/disk are skipped.
    private func discoverIfNeeded() {
        guard cpuTempKeys == nil else { return }
        var cpu: [String] = [], gpu: [String] = []
        for key in smc.allKeys() where key.hasPrefix("T") {
            guard let v = smc.double(key), v >= 10, v <= 105 else { continue }
            if key.hasPrefix("Tg") { gpu.append(key) }
            else if key.hasPrefix("Te") || key.hasPrefix("TC") { cpu.append(key) }
        }
        cpuTempKeys = cpu
        gpuTempKeys = gpu
    }
}
