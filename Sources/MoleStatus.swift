//
//  MoleStatus.swift
//  Burrow
//
//  Codable mirror of `mo status --json` output. We don't model every
//  field upstream emits — only what the UI / queryserver / charts will
//  read. JSONDecoder ignores unknown keys by default so adding more
//  fields later is non-breaking.
//
//  The full snapshot is stored as raw JSON in the DB (`prefix:
//  "mole.snapshot"`); this struct exists for in-process consumers
//  (popup, history charts) that want typed access without re-parsing
//  unrelated fields.
//
//  Schema reference is `cmd/status/metrics.go` upstream — keep the
//  struct names there in mind if you add fields here.
//

import Foundation

struct MoleStatus: Codable {
    let collectedAt: Date
    let host: String
    let platform: String
    let uptimeSeconds: UInt64
    let procs: UInt64
    let hardware: Hardware
    let healthScore: Int
    let healthScoreMsg: String

    let cpu: CPUStatus
    let memory: MemoryStatus
    let diskIO: DiskIOStatus
    let disks: [DiskStatus]
    let network: [NetworkStatus]
    let batteries: [BatteryStatus]?
    let thermal: ThermalStatus?
    let topProcesses: [ProcessInfo]?
    let gpu: [GPUStatus]?
    let proxy: ProxyStatus?
    let bluetooth: [BluetoothDevice]?

    // Mole emits ISO8601 with sub-second precision (`2026-05-31T01:33:40.112723-07:00`).
    // The default ISO formatter rejects fractional seconds, so we configure
    // it explicitly. This is the only custom decoding the type needs.
    private enum CodingKeys: String, CodingKey {
        case collectedAt = "collected_at"
        case host, platform
        case uptimeSeconds = "uptime_seconds"
        case procs, hardware
        case healthScore = "health_score"
        case healthScoreMsg = "health_score_msg"
        case cpu, memory
        case diskIO = "disk_io"
        case disks, network, batteries, thermal
        case topProcesses = "top_processes"
        case gpu, proxy, bluetooth
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let dateStr = try c.decode(String.self, forKey: .collectedAt)
        guard let date = MoleStatus.iso8601.date(from: dateStr) else {
            throw DecodingError.dataCorruptedError(
                forKey: .collectedAt, in: c,
                debugDescription: "Couldn't parse ISO8601 timestamp '\(dateStr)'")
        }
        self.collectedAt = date
        self.host = try c.decode(String.self, forKey: .host)
        self.platform = try c.decode(String.self, forKey: .platform)
        self.uptimeSeconds = try c.decode(UInt64.self, forKey: .uptimeSeconds)
        self.procs = try c.decode(UInt64.self, forKey: .procs)
        self.hardware = try c.decode(Hardware.self, forKey: .hardware)
        self.healthScore = try c.decode(Int.self, forKey: .healthScore)
        self.healthScoreMsg = try c.decodeIfPresent(String.self, forKey: .healthScoreMsg) ?? ""
        self.cpu = try c.decode(CPUStatus.self, forKey: .cpu)
        self.memory = try c.decode(MemoryStatus.self, forKey: .memory)
        self.diskIO = try c.decode(DiskIOStatus.self, forKey: .diskIO)
        self.disks = try c.decodeIfPresent([DiskStatus].self, forKey: .disks) ?? []
        self.network = try c.decodeIfPresent([NetworkStatus].self, forKey: .network) ?? []
        self.batteries = try c.decodeIfPresent([BatteryStatus].self, forKey: .batteries)
        self.thermal = try c.decodeIfPresent(ThermalStatus.self, forKey: .thermal)
        self.topProcesses = try c.decodeIfPresent([ProcessInfo].self, forKey: .topProcesses)
        self.gpu = try c.decodeIfPresent([GPUStatus].self, forKey: .gpu)
        self.proxy = try c.decodeIfPresent(ProxyStatus.self, forKey: .proxy)
        self.bluetooth = try c.decodeIfPresent([BluetoothDevice].self, forKey: .bluetooth)
    }

    func encode(to encoder: Encoder) throws {
        // Burrow only ever encodes from raw JSON the sampler captured, so
        // this branch is unreachable in production. Implementing it is
        // cheap insurance for future tooling that wants typed round-trip.
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(MoleStatus.iso8601.string(from: collectedAt), forKey: .collectedAt)
        try c.encode(host, forKey: .host)
        try c.encode(platform, forKey: .platform)
        try c.encode(uptimeSeconds, forKey: .uptimeSeconds)
        try c.encode(procs, forKey: .procs)
        try c.encode(hardware, forKey: .hardware)
        try c.encode(healthScore, forKey: .healthScore)
        try c.encode(healthScoreMsg, forKey: .healthScoreMsg)
        try c.encode(cpu, forKey: .cpu)
        try c.encode(memory, forKey: .memory)
        try c.encode(diskIO, forKey: .diskIO)
        try c.encode(disks, forKey: .disks)
        try c.encode(network, forKey: .network)
        try c.encodeIfPresent(batteries, forKey: .batteries)
        try c.encodeIfPresent(thermal, forKey: .thermal)
        try c.encodeIfPresent(topProcesses, forKey: .topProcesses)
        try c.encodeIfPresent(gpu, forKey: .gpu)
        try c.encodeIfPresent(proxy, forKey: .proxy)
        try c.encodeIfPresent(bluetooth, forKey: .bluetooth)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

struct Hardware: Codable {
    let model: String
    let cpuModel: String
    let totalRam: String
    let diskSize: String
    let osVersion: String

    private enum CodingKeys: String, CodingKey {
        case model
        case cpuModel = "cpu_model"
        case totalRam = "total_ram"
        case diskSize = "disk_size"
        case osVersion = "os_version"
    }
}

struct CPUStatus: Codable {
    let usage: Double
    let perCore: [Double]?
    let load1: Double
    let load5: Double
    let load15: Double
    let coreCount: Int
    let logicalCpu: Int
    let pCoreCount: Int?
    let eCoreCount: Int?

    private enum CodingKeys: String, CodingKey {
        case usage
        case perCore = "per_core"
        case load1, load5, load15
        case coreCount = "core_count"
        case logicalCpu = "logical_cpu"
        case pCoreCount = "p_core_count"
        case eCoreCount = "e_core_count"
    }
}

struct MemoryStatus: Codable {
    let used: UInt64
    let total: UInt64
    /// `available` is documented in Mole's source but omitted from the
    /// actual JSON output (Go `omitempty` on a derived field). Treat it
    /// as opportunistic — fall back to `total - used` when missing.
    let available: UInt64?
    let usedPercent: Double
    let swapUsed: UInt64
    let swapTotal: UInt64
    let pressure: String

    private enum CodingKeys: String, CodingKey {
        case used, total, available
        case usedPercent = "used_percent"
        case swapUsed = "swap_used"
        case swapTotal = "swap_total"
        case pressure
    }
}

struct DiskIOStatus: Codable {
    let readRate: Double   // MB/s
    let writeRate: Double  // MB/s

    private enum CodingKeys: String, CodingKey {
        case readRate = "read_rate"
        case writeRate = "write_rate"
    }
}

struct DiskStatus: Codable {
    let mount: String
    let used: UInt64
    let total: UInt64
    let usedPercent: Double
    let external: Bool

    private enum CodingKeys: String, CodingKey {
        case mount, used, total
        case usedPercent = "used_percent"
        case external
    }
}

struct NetworkStatus: Codable {
    let name: String
    let rxRateMbs: Double
    let txRateMbs: Double
    let ip: String

    private enum CodingKeys: String, CodingKey {
        case name
        case rxRateMbs = "rx_rate_mbs"
        case txRateMbs = "tx_rate_mbs"
        case ip
    }
}

struct BatteryStatus: Codable {
    let percent: Double
    let status: String
    let timeLeft: String
    let health: String
    let cycleCount: Int
    let capacity: Int

    private enum CodingKeys: String, CodingKey {
        case percent, status
        case timeLeft = "time_left"
        case health
        case cycleCount = "cycle_count"
        case capacity
    }
}

struct ThermalStatus: Codable {
    let cpuTemp: Double
    let gpuTemp: Double
    /// Battery temperature (°C). On Apple Silicon, `cpu_temp`/`gpu_temp` are
    /// usually 0 (no unprivileged SMC die-temp), but battery temp IS reported
    /// — so it's the one thermal series that actually has data on these Macs.
    let batteryTemp: Double?
    let fanSpeed: Int
    /// Number of fans Mole detected. 0 means Mole couldn't read any fan (common
    /// on Apple Silicon) — the UI treats 0 as "no fan data" rather than "idle".
    let fanCount: Int?
    let systemPower: Double
    let adapterPower: Double?
    let batteryPower: Double?

    private enum CodingKeys: String, CodingKey {
        case cpuTemp = "cpu_temp"
        case gpuTemp = "gpu_temp"
        case batteryTemp = "battery_temp"
        case fanSpeed = "fan_speed"
        case fanCount = "fan_count"
        case systemPower = "system_power"
        case adapterPower = "adapter_power"
        case batteryPower = "battery_power"
    }

    /// The best temperature reading available, in °C — CPU first, then GPU,
    /// then battery. Returns nil only when nothing is reported (all 0/absent).
    var bestTemp: Double? {
        if cpuTemp > 0 { return cpuTemp }
        if gpuTemp > 0 { return gpuTemp }
        if let b = batteryTemp, b > 0 { return b }
        return nil
    }
}

/// Avoid the name `Process` to not collide with `Foundation.Process`.
struct ProcessInfo: Codable {
    let pid: Int
    let ppid: Int?
    let name: String
    let command: String
    let cpu: Double
    let memory: Double
    /// Resident memory in bytes, when Mole reports it. Lets the UI rank by
    /// absolute RAM (not just percent) and show a human size.
    let memoryBytes: UInt64?

    private enum CodingKeys: String, CodingKey {
        case pid, ppid, name, command, cpu, memory
        case memoryBytes = "memory_bytes"
    }
}

struct GPUStatus: Codable {
    let name: String
    /// `-1` when the platform can't report GPU utilisation (common on
    /// Apple Silicon); treat negative as "unavailable".
    let usage: Double
    let memoryUsed: UInt64
    let memoryTotal: UInt64
    let coreCount: Int
    let note: String?

    private enum CodingKeys: String, CodingKey {
        case name, usage
        case memoryUsed = "memory_used"
        case memoryTotal = "memory_total"
        case coreCount = "core_count"
        case note
    }
}

struct ProxyStatus: Codable {
    let enabled: Bool
    let type: String
    let host: String
}

struct BluetoothDevice: Codable {
    let name: String
    let connected: Bool
    /// Mole reports battery as a string ("85%" or empty). Parse the percent
    /// when present.
    let battery: String

    var batteryPercent: Int? {
        let digits = battery.filter(\.isNumber)
        return digits.isEmpty ? nil : Int(digits)
    }
}
