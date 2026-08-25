import SwiftUI

/// History tab (contract P2): past runs newest-first plus per-mode trends.
///
/// Layout:
/// - **Trends** section: last ≤20 runs of one mode rendered as simple HStack
///   bar chart (heights scaled to the series min/max). No third-party or
///   Charts dependency needed — plain shapes work on macOS 13.
/// - **Runs** section: every record with a mode badge, relative timestamp,
///   and params summary.
/// - Toolbar: Clear History (with confirmation dialog) and Refresh.
struct HistoryView: View {
    @State private var records: [HistoryRecord] = []
    @State private var trendMode: String?
    @State private var showingClearConfirmation = false
    @State private var selectedRun: IdentifiedRun?
    @State private var showingTimeline = false
    @State private var timelineRange: TimelineRange = .oneDay

    var body: some View {
        List {
            trendsSection
            runsSection
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .navigationTitle("History")
        .toolbar {
            ToolbarItem {
                Button {
                    showingTimeline = true
                } label: {
                    Label("Quality Timeline", systemImage: "chart.dots.scatter")
                }
                .disabled(records.isEmpty)
                .help("Open the QoE timeline (throughput, loss, jitter + WiFi events)")
            }
            ToolbarItem {
                Button {
                    showingClearConfirmation = true
                } label: {
                    Label("Clear History", systemImage: "trash")
                }
                .disabled(records.isEmpty)
                .help("Delete all saved measurement history")
            }
            ToolbarItem {
                Button {
                    reload()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Reload history from disk")
            }
        }
        .confirmationDialog(
            "Clear all history?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All History", role: .destructive) {
                HistoryStore.shared.clear()
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes all \(records.count) saved run(s) from this Mac.")
        }
        .sheet(item: $selectedRun) { run in
            RunDetailSheet(record: run.record)
        }
        .sheet(isPresented: $showingTimeline) {
            TimelineSheet(rows: TimelineModel.build(
                historyFileURL: HistoryStore.defaultFileURL,
                eventsFileURL: WifiEventsReader.defaultFileURL
            ))
        }
        .onAppear(perform: reload)
    }

    // MARK: - Sections

    @ViewBuilder
    private var trendsSection: some View {
        Section("Trends") {
            if let mode = effectiveTrendMode {
                TrendChart(records: Self.trendSeries(for: mode, in: records))
                    .padding(.vertical, 4)
            } else {
                Text("Run a measurement to see its trend here.")
                    .foregroundStyle(.secondary)
            }
            if availableModes.count > 1 {
                Picker("Mode", selection: $trendMode) {
                    ForEach(availableModes, id: \.self) { Text($0) }
                }
                .pickerStyle(.menu)
            }
        }
    }

    @ViewBuilder
    private var runsSection: some View {
        Section("Past Runs") {
            if records.isEmpty {
                Text("No measurements yet. Runs you start in Mode Lab are saved here.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(newestFirst, id: \.ts) { record in
                    Button {
                        selectedRun = IdentifiedRun(record: record)
                    } label: {
                        HistoryRow(record: record)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Derived data

    /// Newest-first view of the log (file itself stays oldest-first).
    private var newestFirst: [HistoryRecord] {
        records.sorted { $0.ts > $1.ts }
    }

    private var availableModes: [String] {
        Array(Set(records.map(\.mode))).sorted()
    }

    /// Mode shown in the trends section: user pick, else most recent mode.
    private var effectiveTrendMode: String? {
        if let trendMode, availableModes.contains(trendMode) { return trendMode }
        return newestFirst.first?.mode
    }

    /// Last ≤20 runs of `mode`, oldest-first so the chart reads left→right.
    static func trendSeries(for mode: String, in records: [HistoryRecord]) -> [HistoryRecord] {
        let matching = records.filter { $0.mode == mode }.sorted { $0.ts < $1.ts }
        return Array(matching.suffix(20))
    }

    private func reload() {
        records = HistoryStore.shared.loadAll()
        if let current = trendMode, !availableModes.contains(current) {
            trendMode = nil // cleared history or unknown mode → fall back
        }
    }
}

// MARK: - One row

private struct HistoryRow: View {
    let record: HistoryRecord

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(record.mode)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                Spacer()
                Text(Self.relativeFormatter.localizedString(for: record.ts, relativeTo: Date()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(paramsSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    /// Compact `key=value` summary of the run parameters.
    private var paramsSummary: String {
        record.params.isEmpty
            ? "no parameters"
            : record.params
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
    }
}

// MARK: - Trends mini-chart

/// Plain-SwiftUI bar chart: one capsule per run, height scaled between the
/// series' min and max numeric value (first number found in `result_raw`).
private struct TrendChart: View {
    let records: [HistoryRecord]

    var body: some View {
        if let values = values {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                        Capsule()
                            .fill(Color.accentColor.opacity(0.75))
                            .frame(height: barHeight(normalized: normalize(value)))
                    }
                }
                .frame(height: 64, alignment: .bottom)
                .frame(maxWidth: .infinity)

                caption
            }
        } else {
            Text("No numeric result found yet for this mode.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var caption: some View {
        let count = values?.count ?? 0
        let range = values.map { series in
            "min \(Self.trim(series.min() ?? 0)) – max \(Self.trim(series.max() ?? 0))"
        } ?? ""
        return Text("\(count) run\(count == 1 ? "" : "s") \(range)")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    /// Numeric series extracted from each record's raw payload, oldest-first.
    private var values: [Double]? {
        let parsed = records.compactMap { Self.firstNumber(in: $0.resultRaw) }
        return parsed.isEmpty ? nil : parsed
    }

    private func normalize(_ value: Double) -> Double {
        guard let lo = values?.min(), let hi = values?.max(), hi > lo else { return 0.5 }
        return (value - lo) / (hi - lo) // 0...1; constant series reads as mid-height
    }

    private func barHeight(normalized n: Double) -> CGFloat {
        8 + CGFloat(n) * 56 // floor of 8pt so tiny values stay visible
    }

    /// First number (int or decimal) appearing anywhere in the raw payload.
    /// Good enough for trend purposes regardless of exact engine schema.
    static func firstNumber(in raw: String) -> Double? {
        guard let match = raw.range(of: #"\d+(?:\.\d+)?"#, options: .regularExpression) else {
            return nil
        }
        return Double(raw[match])
    }

    private static func trim(_ d: Double) -> String {
        d.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(d))
            : String(format: "%.2f", d)
    }
}

#if DEBUG
#endif  // (Offline self-checks for HistoryStore live in HistoryStoreTests.swift.)
