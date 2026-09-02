//
//  ProcessTreeView.swift
//  Burrow
//
//  Process hierarchy sheet (PRD §α — Process Inspector): the flat table folded
//  into a parent→children tree where each node reports its whole subtree's
//  CPU/memory (ProcessTree, pure + tested). Opened from the table's actions
//  menu; collapsed by default so a few-hundred-node tree stays cheap. The flat
//  table's perf-sensitive pump is untouched.
//

import SwiftUI

extension ProcessTree.Node: Identifiable {
    public var id: Int { proc.pid }
    /// OutlineGroup wants nil for leaves, not an empty array.
    var childrenOpt: [ProcessTree.Node]? { children.isEmpty ? nil : children }
}

struct ProcessTreeView: View {
    let processes: [ProcessInfo]
    @Environment(\.dismiss) private var dismiss

    @State private var roots: [ProcessTree.Node] = []
    @State private var names: [Int: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(NSLocalizedString("Process Tree", comment: ""))
                    .font(Brand.serif(18, .medium)).foregroundStyle(Brand.textPrimary)
                Spacer()
                Text(NSLocalizedString("Subtree totals", comment: ""))
                    .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: Brand.scaled(15))).foregroundStyle(Brand.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("Close", comment: ""))
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Rectangle().fill(Brand.hairline).frame(height: 1)
            List {
                OutlineGroup(roots, children: \.childrenOpt) { node in
                    row(node)
                }
            }
            .listStyle(.sidebar)
        }
        .frame(width: 520, height: 560)
        .onAppear(perform: build)
    }

    private func row(_ node: ProcessTree.Node) -> some View {
        HStack(spacing: 8) {
            Text(names[node.proc.pid] ?? "pid \(node.proc.pid)")
                .font(Brand.sans(12)).foregroundStyle(Brand.textPrimary).lineLimit(1)
            Text("\(node.proc.pid)").font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
            Spacer(minLength: 8)
            Text(String(format: "%.1f%%", node.totalCPU))
                .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                .frame(width: 56, alignment: .trailing)
            Text(Fmt.bytes(node.totalMem))
                .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                .frame(width: 72, alignment: .trailing)
        }
    }

    /// Build the tree once on appear — name lookup is O(1) thereafter.
    private func build() {
        names = Dictionary(processes.map { ($0.pid, $0.name) }, uniquingKeysWith: { a, _ in a })
        let procs = processes.map {
            ProcessTree.Proc(pid: $0.pid, ppid: $0.ppid ?? 0,
                             cpu: $0.cpu, mem: Int64($0.memoryBytes ?? 0), threads: 0)
        }
        roots = ProcessTree.build(procs).sorted { $0.totalCPU > $1.totalCPU }
    }
}
