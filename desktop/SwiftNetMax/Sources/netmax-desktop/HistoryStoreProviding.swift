//
//  HistoryStoreProviding.swift
//  netmax-desktop
//
//  Task 4 view decomposition — read-side store seam extracted from
//  ReportsView so the view file stays focused on UI. Same types, same
//  names, same module.
//

import Foundation

// MARK: - Store seam (Lane B integration)

/// Minimal read-side surface of Lane B's `HistoryStore` that this view needs.
/// Keeps `ReportsView` testable without touching the real history file and
/// decouples us from store-internal changes.
protocol HistoryStoreProviding {
    func loadAll() -> [HistoryRecord]
}

/// Production adapter around `HistoryStore.shared`.
struct SystemHistoryStore: HistoryStoreProviding {
    private let backing: HistoryStore

    init(backing: HistoryStore = .shared) {
        self.backing = backing
    }

    func loadAll() -> [HistoryRecord] { backing.loadAll() }
}
