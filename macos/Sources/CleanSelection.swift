//
//  CleanSelection.swift
//  Burrow
//
//  Selection state for the Clean review screen: which preview items are
//  ticked, tri-state per category, live byte totals for the confirm
//  pill, and the exclusion list the whitelist session writes. Pure value
//  type — the view owns one in @State; every rule here is unit-tested.
//
//  Locked items (cache belongs to a running app, or the previous run
//  reported the path busy) start unticked and CANNOT be ticked: the
//  review just promised they'll be skipped.
//

import Foundation

struct CleanSelection {
    enum LockReason: Equatable {
        case appOpen(appName: String)
        case systemBusy
        /// The snapshot refused this entry, so it can never reach a plan.
        /// Locked rather than hidden: the preview counted it, and silently
        /// dropping a line the user was just shown reads as a miscount.
        case notCleanable(reason: String)
    }

    enum CategoryState { case all, mixed, none }

    let list: CleanList
    let locked: [String: LockReason]
    private(set) var ticked: Set<String>

    init(list: CleanList, locked: [String: LockReason]) {
        self.list = list
        self.locked = locked
        self.ticked = Set(list.categories.flatMap(\.items)
            .map(\.path)
            .filter { locked[$0] == nil })
    }

    // MARK: - Ticking

    func isTicked(_ path: String) -> Bool { ticked.contains(path) }

    mutating func toggle(_ path: String) {
        guard locked[path] == nil else { return }
        if ticked.contains(path) { ticked.remove(path) } else { ticked.insert(path) }
    }

    mutating func selectAll() {
        ticked = Set(allPaths.filter { locked[$0] == nil })
    }

    mutating func deselectAll() { ticked = [] }

    /// Header checkbox: anything-not-all-ticked → tick all (unlocked);
    /// all ticked → none.
    mutating func toggleCategory(_ name: String) {
        guard let category = list.categories.first(where: { $0.name == name }) else { return }
        let tickable = category.items.map(\.path).filter { locked[$0] == nil }
        if categoryState(name) == .all {
            ticked.subtract(tickable)
        } else {
            ticked.formUnion(tickable)
        }
    }

    func categoryState(_ name: String) -> CategoryState {
        guard let category = list.categories.first(where: { $0.name == name }) else { return .none }
        let paths = category.items.map(\.path)
        let tickedCount = paths.filter(ticked.contains).count
        if tickedCount == 0 { return .none }
        // "All" means every *tickable* item — locked rows can't count against it.
        let tickable = paths.filter { locked[$0] == nil }.count
        return tickedCount >= tickable && tickable > 0 ? .all : .mixed
    }

    // MARK: - Totals

    var totalCount: Int { allPaths.count }
    var selectedCount: Int { ticked.count }

    var selectedBytes: Int64 {
        list.categories.flatMap(\.items)
            .filter { ticked.contains($0.path) }
            .reduce(0) { $0 + $1.sizeBytes }
    }

    func selectedBytes(in category: CleanList.Category) -> Int64 {
        category.items.filter { ticked.contains($0.path) }.reduce(0) { $0 + $1.sizeBytes }
    }

    func selectedCount(in category: CleanList.Category) -> Int {
        category.items.filter { ticked.contains($0.path) }.count
    }

    /// What the whitelist session protects: every unticked path.
    var excludedPaths: [String] {
        allPaths.filter { !ticked.contains($0) }
    }

    /// "Close Helium, X to clean another N GB · M items" — the locked
    /// upside, summed over app-locked items. nil when nothing is locked.
    var lockedSummary: (appNames: [String], bytes: Int64, itemCount: Int)? {
        // Only .appOpen entries belong in this line. It reads "Close X to clean
        // another N" — a promise that quitting an app reclaims those bytes,
        // which is false for a path a system service holds and outright wrong
        // for one the snapshot refused, since no action of the user's frees it.
        // Counting those inflated the total and, when they were the ONLY locked
        // entries, produced "Close  to clean another 12 GB" with no app named.
        let lockedItems = list.categories.flatMap(\.items).filter {
            if case .appOpen? = locked[$0.path] { return true }
            return false
        }
        guard !lockedItems.isEmpty else { return nil }
        var names: [String] = []
        for item in lockedItems {
            if case .appOpen(let name)? = locked[item.path], !names.contains(name) {
                names.append(name)
            }
        }
        let bytes = lockedItems.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return (names, bytes, lockedItems.count)
    }

    private var allPaths: [String] { list.categories.flatMap(\.items).map(\.path) }
}
