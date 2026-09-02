//
//  NetUsage.swift
//  Burrow
//
//  Per-process network bandwidth + reverse DNS for the Ports pane (plan §2.1,
//  the bandwhich/rustnet substance). Bandwidth comes from `nettop` — which
//  reports the kernel's per-process byte counters WITHOUT root (the same source
//  Activity Monitor uses), so sampling its `-d` delta frame over ~1s gives live
//  up/down rates with no packet capture, no BPF, no sudo. The frame parser is
//  pure and unit-tested; sampling + DNS are the impure edge.
//

import Foundation
import Darwin

enum NetUsage {
    /// Per-process byte rates, bytes/sec.
    struct Rates: Equatable {
        let down: Int64   // bytes_in
        let up: Int64     // bytes_out
    }

    /// Parse `nettop -P -x -d -L 2 -J bytes_in,bytes_out`. Output is CSV:
    ///
    ///     ,bytes_in,bytes_out,
    ///     mDNSResponder.626,627,426,
    ///     io.tailscale.ip.1550,20406,31037875,
    ///
    /// Frames are separated by the header line; with `-d` the LAST frame holds
    /// the per-interval deltas (≈ per-second rates). The first CSV field is
    /// `name.pid` where the *name itself can contain dots*, so the pid is the
    /// trailing dot-component.
    static func parse(_ output: String) -> [Int: Rates] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var frames: [[String]] = []
        var cur: [String] = []
        for l in lines {
            if l.hasPrefix(",bytes_in") || l.contains("bytes_in,bytes_out") {
                if !cur.isEmpty { frames.append(cur); cur = [] }
            } else {
                cur.append(l)
            }
        }
        if !cur.isEmpty { frames.append(cur) }
        guard let frame = frames.last(where: { !$0.isEmpty }) else { return [:] }

        var out: [Int: Rates] = [:]
        for row in frame {
            let f = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3,
                  let pid = Int(f[0].split(separator: ".").last.map(String.init) ?? "") else { continue }
            let down = Int64(f[1]) ?? 0
            let up = Int64(f[2]) ?? 0
            let prev = out[pid]
            out[pid] = Rates(down: (prev?.down ?? 0) + down, up: (prev?.up ?? 0) + up)
        }
        return out
    }

    private static let cacheLock = NSLock()
    private static var cached: (at: Date, rates: [Int: Rates])?
    /// Reuse a recent frame instead of re-running the ~1 s blocking nettop for
    /// every caller. PortsView re-samples on appear / tab-change / refresh /
    /// after each kill, and ProcessInspector samples the whole system just to
    /// read one pid — within this window they now share one frame. #238
    private static let cacheTTL: TimeInterval = 2.5

    /// Per-process bandwidth (bytes/sec), served from a ≤`cacheTTL`s cache; on a
    /// miss it runs nettop for ~1 s (blocking — call off the main thread).
    /// Returns empty on any failure (bandwidth degrades to "—").
    static func sample() -> [Int: Rates] {
        cacheLock.lock()
        if let c = cached, Date().timeIntervalSince(c.at) < cacheTTL {
            let r = c.rates; cacheLock.unlock(); return r
        }
        cacheLock.unlock()
        let out = (try? EngineRunner.shared.capture(
            MoCommand(target: .executable("/usr/bin/nettop"),
                      args: ["-P", "-x", "-d", "-s", "1", "-L", "2", "-J", "bytes_in,bytes_out"],
                      timeout: 8)))?.stdout ?? ""
        let rates = parse(out)
        cacheLock.lock(); cached = (Date(), rates); cacheLock.unlock()
        return rates
    }

    /// Reverse-DNS a numeric IP to a hostname, or nil if there's no PTR (or it
    /// just echoes the IP back). Blocks on the resolver — call off-main, cache
    /// the result. `AI_NUMERICHOST` parses the literal into a sockaddr without a
    /// forward lookup; `NI_NAMEREQD` fails fast when there's no reverse record.
    static func reverseDNS(_ ip: String) -> String? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_family = AF_UNSPEC
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ip, nil, &hints, &res) == 0, let info = res else { return nil }
        defer { freeaddrinfo(res) }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let r = getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen,
                            &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
        guard r == 0 else { return nil }
        let name = String(cString: host)
        return (name.isEmpty || name == ip) ? nil : name
    }
}
