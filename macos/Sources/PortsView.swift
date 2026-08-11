//
//  PortsView.swift
//  Burrow
//
//  Port / connection inspector pane (roadmap C.10 + plan §2.1, rustnet /
//  bandwhich grade). A native `lsof -i`-style table over PortEnumerator:
//  listening sockets AND established connections with their remote endpoint
//  (reverse-DNS resolved), per-process up/down bandwidth (nettop, no sudo),
//  well-known service labels, conflict flags, sortable columns, free-text
//  filter, and a per-row detail with copy-lsof/kill + a confirm-gated Quit on
//  the user's own processes only.
//
//  NOTE (hand-test): native enumeration + nettop sampling + a real kill —
//  verify the list/peers vs `lsof -i -P`, the rates against Activity Monitor,
//  and that Quit only targets your own processes.
//

import SwiftUI
import AppKit
import Darwin

struct PortsView: View {
    var isActive: Bool = true

    @State private var conns: [ListeningPort] = []
    @State private var rates: [Int: NetUsage.Rates] = [:]
    @State private var hostnames: [String: String] = [:]   // remote ip → hostname
    @State private var filter: PortInspector.Filter = .all
    @State private var query = ""
    @State private var sortKey: PortInspector.SortKey = .port
    @State private var sortAsc = true
    @State private var resolveDNS = true
    @State private var expandedID: String?
    @State private var loaded = false
    @State private var loading = false
    private let uid = Int(getuid())

    private var conflicts: Set<Int> { PortInspector.conflicts(conns) }
    private var rows: [ListeningPort] {
        PortInspector.sorted(PortInspector.filter(conns, filter, query: query),
                             by: sortKey, ascending: sortAsc, rates: rates)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar.padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 12)
            Rectangle().fill(Brand.hairline).frame(height: 1)
            columnHeader.padding(.horizontal, 18).padding(.vertical, 7)
            Rectangle().fill(Brand.hairline).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row($0) }
                    if loaded, rows.isEmpty {
                        Text(NSLocalizedString("No matching ports.", comment: ""))
                            .font(Brand.sans(13)).foregroundStyle(Brand.textSecondary)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .onAppear { if isActive { reload() } }
        .onChange(of: isActive) { _, now in if now { reload() } }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(PortInspector.Filter.allCases, id: \.self) { seg($0) }
            }
            .padding(3)
            .background(Capsule().fill(Color.black.opacity(0.22)))
            .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 1))
            if loading { ProgressView().controlSize(.small) }
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Brand.textTertiary)
                TextField(NSLocalizedString("port, process, service, host…", comment: ""), text: $query)
                    .textFieldStyle(.plain).font(Brand.sans(12)).frame(width: 170)
            }
            Button { resolveDNS.toggle(); if resolveDNS { resolveHosts(conns) } } label: {
                Image(systemName: resolveDNS ? "globe" : "number")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(resolveDNS ? Tool.ports.accent : Brand.textTertiary)
            }
            .buttonStyle(.plain)
            .help(resolveDNS ? NSLocalizedString("Showing hostnames — click for raw IPs", comment: "")
                             : NSLocalizedString("Showing raw IPs — click to resolve hostnames", comment: ""))
            Button { reload() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Brand.textSecondary)
            }
            .buttonStyle(.plain).help(NSLocalizedString("Refresh", comment: ""))
        }
    }

    private func seg(_ f: PortInspector.Filter) -> some View {
        let on = filter == f
        let label: String
        switch f {
        case .all: label = NSLocalizedString("All", comment: "")
        case .listening: label = NSLocalizedString("Listening", comment: "")
        case .established: label = NSLocalizedString("Established", comment: "")
        }
        return Button { filter = f } label: {
            Text(label).font(Brand.mono(11, on ? .semibold : .regular))
                .foregroundStyle(on ? .black : Brand.textSecondary)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background { if on { Capsule().fill(.white) } }
                .contentShape(Capsule())
        }.buttonStyle(.plain)
    }

    // MARK: Header (sortable)

    private var columnHeader: some View {
        HStack(spacing: 12) {
            sortHeader("PORT", .port, width: 104, align: .leading)
            sortHeader("PROCESS", .process, width: nil, align: .leading)
            sortHeader("PEER", .peer, width: 210, align: .leading)
            HStack(spacing: 8) {
                sortArrow("DOWN", .down)
                sortArrow("UP", .up)
            }
            .frame(width: 104, alignment: .trailing)
            Spacer().frame(width: 22)
        }
        .font(Brand.mono(9, .bold)).tracking(0.6).foregroundStyle(Brand.textTertiary)
    }

    @ViewBuilder
    private func sortHeader(_ label: String, _ key: PortInspector.SortKey, width: CGFloat?, align: Alignment) -> some View {
        Button { toggleSort(key) } label: {
            HStack(spacing: 3) {
                Text(label).foregroundStyle(sortKey == key ? Brand.textSecondary : Brand.textTertiary)
                if sortKey == key {
                    Image(systemName: sortAsc ? "chevron.up" : "chevron.down").font(.system(size: 7, weight: .bold))
                }
            }
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: align)
            .frame(width: width, alignment: align)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    @ViewBuilder
    private func sortArrow(_ label: String, _ key: PortInspector.SortKey) -> some View {
        Button { toggleSort(key) } label: {
            HStack(spacing: 2) {
                Text(label).foregroundStyle(sortKey == key ? Brand.textSecondary : Brand.textTertiary)
                if sortKey == key {
                    Image(systemName: sortAsc ? "chevron.up" : "chevron.down").font(.system(size: 7, weight: .bold))
                }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func toggleSort(_ key: PortInspector.SortKey) {
        if sortKey == key { sortAsc.toggle() }
        else { sortKey = key; sortAsc = (key == .port || key == .process || key == .peer) }
    }

    // MARK: Row

    @ViewBuilder private func row(_ p: ListeningPort) -> some View {
        let on = expandedID == p.id
        let conflicted = p.state == .listen && conflicts.contains(p.port)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // PORT + proto + service
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("\(p.port)").font(Brand.mono(13, .bold)).foregroundStyle(Brand.textPrimary)
                        Text(p.proto).font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                    }
                    if let svc = PortLookup.service(for: p.port) {
                        Text(svc).font(Brand.mono(9)).foregroundStyle(Brand.textSecondary).lineLimit(1)
                    }
                }
                .frame(width: 104, alignment: .leading)

                // PROCESS + pid (+ conflict)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(p.process).font(Brand.sans(13, .medium)).foregroundStyle(Brand.textPrimary)
                            .lineLimit(1).truncationMode(.middle)
                        if conflicted {
                            Text(NSLocalizedString("conflict", comment: ""))
                                .font(Brand.mono(9, .medium)).foregroundStyle(Brand.amber)
                                .padding(.horizontal, 5).padding(.vertical, 1.5)
                                .background(Capsule().fill(Brand.amber.opacity(0.16)))
                        }
                    }
                    Text("pid \(p.pid)").font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // PEER
                peerView(p).frame(width: 210, alignment: .leading)

                // NET (down/up)
                netView(p).frame(width: 104, alignment: .trailing)

                Image(systemName: on ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Brand.textTertiary)
                    .frame(width: 22, alignment: .center)
            }
            .padding(.horizontal, 18).padding(.vertical, 9)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.12)) { expandedID = on ? nil : p.id } }

            if on { detail(p) }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Brand.hairline).frame(height: 1) }
    }

    @ViewBuilder private func peerView(_ p: ListeningPort) -> some View {
        if let remoteIP = p.remoteAddress, let rport = p.remotePort {
            let host = (resolveDNS ? hostnames[remoteIP] : nil)
            VStack(alignment: .leading, spacing: 1) {
                Text(host ?? remoteIP).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                Text(host != nil ? "\(remoteIP):\(rport)" : ":\(rport)")
                    .font(Brand.mono(9)).foregroundStyle(Brand.textTertiary).lineLimit(1).truncationMode(.middle)
            }
        } else {
            Chip(text: "listening", color: Brand.green)
        }
    }

    @ViewBuilder private func netView(_ p: ListeningPort) -> some View {
        if let r = rates[p.pid], r.down > 0 || r.up > 0 {
            VStack(alignment: .trailing, spacing: 1) {
                Text("↓ \(Fmt.bytes(r.down))/s").font(Brand.mono(9)).foregroundStyle(Brand.green)
                Text("↑ \(Fmt.bytes(r.up))/s").font(Brand.mono(9)).foregroundStyle(Brand.blue)
            }
        } else {
            Text("—").font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
        }
    }

    // MARK: Detail (expanded)

    @ViewBuilder private func detail(_ p: ListeningPort) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            detailRow(NSLocalizedString("Local", comment: ""), p.localDisplay)
            if let rd = p.remoteDisplay {
                let host = resolveDNS ? hostnames[p.remoteAddress ?? ""] : nil
                detailRow(NSLocalizedString("Remote", comment: ""), host.map { "\($0)  ·  \(rd)" } ?? rd)
            }
            detailRow(NSLocalizedString("State", comment: ""), p.state == .listen ? "listening" : p.state.rawValue)
            if let svc = PortLookup.service(for: p.port) {
                detailRow(NSLocalizedString("Service", comment: ""), svc)
            }
            HStack(spacing: 8) {
                copyButton(NSLocalizedString("Copy lsof", comment: ""), "lsof -i :\(p.port)")
                copyButton(NSLocalizedString("Copy kill", comment: ""), "kill \(p.pid)")
                Spacer()
                if PortInspector.isKillable(p, currentUID: uid) {
                    Button(NSLocalizedString("Quit…", comment: "")) {
                        ProcessActions.confirmTermination(
                            pid: p.pid,
                            displayName: p.process,
                            onRefresh: reload
                        )
                    }
                        .buttonStyle(.plain)
                        .font(Brand.sans(11, .semibold)).foregroundStyle(Brand.red)
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 18).padding(.top, 2).padding(.bottom, 12)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(label.uppercased()).font(Brand.mono(8, .bold)).tracking(0.5)
                .foregroundStyle(Brand.textTertiary).frame(width: 56, alignment: .leading)
            Text(value).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
        }
    }

    private func copyButton(_ title: String, _ cmd: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
        } label: {
            Text(title).font(Brand.mono(10, .medium)).foregroundStyle(Brand.textSecondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7).fill(Brand.cardFill))
        }.buttonStyle(.plain).help(cmd)
    }

    // MARK: Load

    private func reload() {
        loading = true
        Task.detached(priority: .userInitiated) {
            let found = PortEnumerator.connections(includeEstablished: true)
            let r = NetUsage.sample()
            await MainActor.run {
                conns = found; rates = r; loaded = true; loading = false
            }
            if await resolveDNS { resolveHosts(found) }
        }
    }

    /// Reverse-resolve the unique remote IPs we haven't seen yet, one at a time
    /// (off-main), filling the cache as each returns.
    private func resolveHosts(_ ports: [ListeningPort]) {
        Task.detached(priority: .utility) {
            let known = await hostnames
            let ips = Set(ports.compactMap { $0.remoteAddress }).subtracting(known.keys)
            for ip in ips {
                guard let host = NetUsage.reverseDNS(ip) else { continue }
                await MainActor.run { hostnames[ip] = host }
            }
        }
    }
}
