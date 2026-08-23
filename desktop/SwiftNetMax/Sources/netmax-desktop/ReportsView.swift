//
//  ReportsView.swift
//  netmax-desktop
//
//  L3-D — Reports tab: shows the LAST RESULT (newest contract-P2 history
//  record) and exports it as CSV or JSON via NSSavePanel.
//
//  Data source: `HistoryStore.shared` (Lane B). Newest record is
//  `loadAll().last` — the store documents oldest-first file order. The
//  store is injected for previews/tests; production uses the shared one.
//

import SwiftUI

struct ReportsView: View {

    // MARK: Dependencies

    /// Injectable so previews/tests can pass a fake; production default
    /// resolves to the Lane-B store.
    private let store: HistoryStoreProviding

    init(store: HistoryStoreProviding = SystemHistoryStore()) {
        self.store = store
    }

    /// Convenience for callers that hand over a concrete `HistoryStore`
    /// (e.g. `HistoryStore(fileURL:)` in tests).
    static func makeDefault(store: HistoryStore = .shared) -> ReportsView {
        ReportsView(store: SystemHistoryStore(backing: store))
    }

    // MARK: State

    @State private var records: [HistoryRecord] = []
    @State private var status: ExportStatus = .idle
    @State private var savedPath: String = ""

    private var lastRecord: HistoryRecord? { records.last }

    private var isExporting: Bool {
        if case .exporting = status { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            if let record = lastRecord {
                resultSummary(record)
                exportButtons(for: record)
            } else {
                emptyState
            }

            Spacer(minLength: 0)

            statusFooter
        }
        .padding(16)
        .frame(minWidth: 380, minHeight: 430)
        .task { reload() }
        .onAppear { reload() }  // re-read history whenever the tab resurfaces
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Image(systemName: "square.and.arrow.up")
                .foregroundStyle(.blue)
            Text("Reports")
                .font(.headline)
            Spacer()
            if let record = lastRecord {
                Text("Last run: \(Self.timestampText(record.ts))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func resultSummary(_ record: HistoryRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text("Last result — mode “\(record.mode)”")
                    .font(.subheadline.weight(.medium))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Last result, mode \(record.mode)")

            ScrollView {
                Text(record.resultRaw)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )
            .cornerRadius(6)
            .frame(minHeight: 180)
            .accessibilityLabel("Last result details")
            .accessibilityValue(record.resultRaw)

            if !record.params.isEmpty {
                Text("Parameters: " + record.params.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func exportButtons(for record: HistoryRecord) -> some View {
        HStack(spacing: 10) {
            Button {
                runExport(.csv, record: record)
            } label: {
                Label("Export CSV", systemImage: "tablecells")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isExporting)

            Button {
                runExport(.json, record: record)
            } label: {
                Label("Export JSON", systemImage: "curlybraces.square")
            }
            .buttonStyle(.bordered)
            .disabled(isExporting)
        }
        .accessibilityElement(children: .contain)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No results yet")
                .font(.subheadline.weight(.medium))
            Text("Run a test from Mode Lab or the dashboard — it will appear here and be ready to export.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No results yet")
    }

    @ViewBuilder
    private var statusFooter: some View {
        switch status {
        case .idle:
            EmptyView()
        case .exporting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Exporting…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Export in progress")
        case .success:
            Label {
                Text("Saved to \(savedPath)")
                    .font(.footnote)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Export succeeded, saved to \(savedPath)")
        case .failure(let message):
            Label {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Export failed: \(message)")
        case .cancelled:
            Text("Export canceled.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Export canceled")
        }
    }

    // MARK: Actions

    private func reload() {
        records = store.loadAll()
    }

    private func runExport(_ format: ExportFormat, record: HistoryRecord) {
        status = .exporting
        savedPath = ""
        let snapshot = ExportRecord(
            ts: record.ts,
            mode: record.mode,
            params: record.params,
            raw: record.resultRaw
        )
        Task {
            do {
                let url = try await ReportExporter.save(snapshot, as: format)
                await MainActor.run {
                    savedPath = url.path
                    status = .success
                }
            } catch is CancellationError {
                await MainActor.run { status = .cancelled }
            } catch ExportError.cancelled {
                await MainActor.run { status = .cancelled }
            } catch {
                await MainActor.run {
                    status = .failure(error.localizedDescription)
                }
            }
        }
    }

    // MARK: Helpers

    private static func timestampText(_ date: Date) -> String {
        fmt.string(from: date)
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

// MARK: - Status model

private enum ExportStatus {
    case idle
    case exporting
    case success
    case failure(String)
    case cancelled
}

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

#if DEBUG
#Preview("With result") {
    ReportsView.makeDefault()
}

#Preview("Empty") {
    struct EmptyStore: HistoryStoreProviding {
        func loadAll() -> [HistoryRecord] { [] }
    }
    return ReportsView(store: EmptyStore())
}
#endif
