//
//  OperationCenter.swift
//  Burrow
//
//  One shared, observable list of "things Burrow is doing" — clean,
//  optimize, analyze scans. The main window's runners report into it, and
//  the menu-bar HUD reads from it, so a job you kicked off in the window
//  is visible from the dropdown (and survives switching tabs). Finished
//  ops linger briefly then drop themselves.
//

import SwiftUI

@MainActor
final class OperationCenter: ObservableObject {
    static let shared = OperationCenter()

    enum Phase: Equatable { case running, done, failed }

    struct Op: Identifiable, Equatable {
        let id: UUID
        var label: String
        var phase: Phase
        var detail: String
        var startedAt: Date
    }

    @Published private(set) var ops: [Op] = []

    var hasActivity: Bool { !ops.isEmpty }

    func begin(_ id: UUID, label: String) {
        if let i = ops.firstIndex(where: { $0.id == id }) {
            ops[i].label = label
            ops[i].phase = .running
            ops[i].detail = ""
        } else {
            ops.insert(Op(id: id, label: label, phase: .running, detail: "", startedAt: Date()), at: 0)
        }
        if ops.count > 6 { ops = Array(ops.prefix(6)) }
    }

    func detail(_ id: UUID, _ text: String) {
        guard let i = ops.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        ops[i].detail = trimmed
    }

    func end(_ id: UUID, success: Bool, detail: String = "") {
        guard let i = ops.firstIndex(where: { $0.id == id }) else { return }
        ops[i].phase = success ? .done : .failed
        if !detail.isEmpty { ops[i].detail = detail }
        DispatchQueue.main.asyncAfter(deadline: .now() + 22) { [weak self] in
            guard let self, let j = self.ops.firstIndex(where: { $0.id == id }) else { return }
            // The runner reuses its id across runs (dry-run → real run):
            // if this op was re-begun inside the linger window, the expiry
            // belongs to the OLD run — a live row must never be removed.
            guard self.ops[j].phase != .running else { return }
            self.ops.remove(at: j)
        }
    }
}
