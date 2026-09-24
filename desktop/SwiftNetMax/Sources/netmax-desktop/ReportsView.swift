//
//  ReportsView.swift
//  netmax-desktop
//
//  L3-D — Reports tab: shows the LAST RESULT (newest contract-P2 history
//  record) and exports it as CSV or JSON via NSSavePanel. When history is
//  non-empty it also offers "Export Report Card (PDF)", presenting the
//  graded report-card share sheet (ReportCardShareView, ALPHA-A1-08).
//
//  Data source: `HistoryStore.shared` (Lane B). Newest record is
//  `loadAll().last` — the store documents oldest-first file order. The
//  store is injected for previews/tests; production uses the shared one.
//
//  W13B TEAM-UB / UB-2 (S-009): "Monthly Summary" section computing last-
//  30-day stats (tests count, average Mbps, worst bufferbloat grade, count
//  of unusual readings via AnomalyEngine) rendered through the existing
//  ReportCardPDF machinery into a downloadable PDF. Parsing goes through
//  DashboardCardsView's MetricExtractor so every surface agrees on what a
//  payload says.
//

import AppKit
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
    /// Presents the graded report-card share sheet (ALPHA-A1-08).
    @State private var showCardShare = false

    /// W13B UB-2 (S-009): last-30-day aggregate, recomputed on every reload.
    @State private var monthly = MonthlySummaryStats(testsCount: 0,
                                                     averageMbps: nil,
                                                     worstGrade: nil,
                                                     anomalyCount: 0)
    /// W13B UB-2: outcome of the last monthly-PDF save attempt.
    @State private var monthlyStatus: ExportStatus = .idle

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

            // Task 3: ISP evidence packet — chronological degradation
            // timeline + plan-vs-actual for support tickets.
            if !records.isEmpty {
                Button {
                    exportIspEvidence()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Export ISP Evidence Packet…")
                            Text("Markdown timeline of degradations + plan vs actual — paste into a support ticket")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "doc.text")
                            .foregroundColor(.accentColor)
                    }
                }
                .buttonStyle(.plain)
                .help("Writes a markdown evidence packet you can send to your ISP")
                .accessibilityLabel(Text("Export ISP evidence packet"))
                .accessibilityHint(Text("Saves a markdown file with the degradation timeline and plan-vs-actual speeds for an ISP support ticket."))
                .accessibilityIdentifier("reports.exportIspEvidence")
            }

            // W13B UB-2 (S-009): Monthly Summary card — last-30-day aggregate
            // with its own downloadable PDF. Shown whenever there is any
            // history (an empty window renders honest zeros, not a blank).
            if !records.isEmpty {
                monthlySummaryCard
            }

            Spacer(minLength: 0)

            statusFooter
            monthlyStatusFooter
        }
        .padding(16)
        .frame(minWidth: 380, minHeight: 430)
        .task { reload() }
        .onAppear { reload() }  // re-read history whenever the tab resurfaces
        .sheet(isPresented: $showCardShare) {
            // Report-card share surface (ALPHA-A1-08) — integration note
            // from its header: one-liner sheet host, no edits needed there.
            ReportCardShareView.makeDefault()
        }
    }

    /// W13B UB-2 (S-009): the Monthly Summary card + Save PDF button.
    private var monthlySummaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "calendar.badge.clock")
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)
                Text("Monthly Summary")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("last \(MonthlySummary.windowDays) days")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Monthly summary, last \(MonthlySummary.windowDays) days")

            HStack(alignment: .top, spacing: 10) {
                monthlyStatTile(title: "Tests run",
                                value: "\(monthly.testsCount)")
                monthlyStatTile(
                    title: "Avg speed",
                    value: monthly.averageMbps.map { String(format: "%.1f", $0) } ?? "—",
                    unit: monthly.averageMbps == nil ? nil : "Mbps")
                monthlyStatTile(title: "Worst grade",
                                value: monthly.worstGrade ?? "—")
                monthlyStatTile(title: "Unusual readings",
                                value: "\(monthly.anomalyCount)")
            }

            Button {
                saveMonthlyPDF()
            } label: {
                Label("Save Monthly Summary (PDF)", systemImage: "doc.richtext")
            }
            .buttonStyle(.bordered)
            .disabled(monthlyStatus == .exporting)
            .accessibilityHint("Renders this summary through the report-card PDF engine and saves it")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
        .accessibilityElement(children: .contain)
    }

    /// One compact stat tile inside the Monthly Summary card.
    private func monthlyStatTile(title: String, value: String,
                                 unit: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(unit.map { "\(value) \($0)" } ?? value)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(unit.map { "\(value) \($0)" } ?? value)
    }

    /// Footer twin for the monthly save flow (reuses ExportStatus shapes so
    /// both flows read identically; idle collapses to nothing).
    @ViewBuilder
    private var monthlyStatusFooter: some View {
        switch monthlyStatus {
        case .idle:
            EmptyView()
        case .exporting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Preparing monthly PDF…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Preparing monthly PDF")
        case .success:
            Label {
                Text("Monthly summary saved to \(savedPath)")
                    .font(.footnote)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Monthly summary saved to \(savedPath)")
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
            .accessibilityLabel("Monthly export failed: \(message)")
        case .cancelled:
            Text("Monthly export canceled.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Monthly export canceled")
        }
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

            // ALPHA-A3-04 — graded report card (roadmap N7): sheet host for
            // ReportCardShareView. Only offered when there is history, so the
            // empty path keeps the existing honest empty state.
            Button {
                showCardShare = true
            } label: {
                Label("Export Report Card (PDF)", systemImage: "doc.richtext")
            }
            .buttonStyle(.bordered)
            .disabled(isExporting)
            .accessibilityHint("Opens a preview of the graded connection report card to share or save")
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
        monthly = MonthlySummary.compute(from: records)
    }

    /// Task 3: ISP evidence packet — plan comes from the shared Target Speed
    /// AppStorage key (`netmax.plan.mbps`); nil when never set (default 0
    /// after first read is still meaningful — pass Double only if > 0).
    private func exportIspEvidence() {
        let plan = UserDefaults.standard.object(forKey: "netmax.plan.mbps") as? Double
        let planMbps = (plan ?? 0) > 0 ? plan : nil
        if let url = IspEvidencePacket.export(records: records, planMbps: planMbps) {
            savedPath = url.path
            status = .success
        } else {
            status = .cancelled
        }
    }

    /// UB-2 (S-009): NSSavePanel → render the Monthly Summary card through
    /// ReportCardPDF and write it. Same non-blocking `begin` pattern as
    /// ReportCardShareView's save path (works without a parent window).
    private func saveMonthlyPDF() {
        monthlyStatus = .exporting
        Task {
            do {
                let url = try await Self.presentMonthlySavePanelAndWrite(
                    stats: monthly, days: MonthlySummary.windowDays)
                await MainActor.run {
                    savedPath = url.path
                    monthlyStatus = .success
                }
            } catch is CancellationError {
                await MainActor.run { monthlyStatus = .cancelled }
            } catch ExportError.cancelled {
                await MainActor.run { monthlyStatus = .cancelled }
            } catch {
                await MainActor.run { monthlyStatus = .failure(error.localizedDescription) }
            }
        }
    }

    /// Panel + write for the monthly PDF. Internal static so the offline
    /// harness can exercise the write path against a temp directory.
    @MainActor
    static func presentMonthlySavePanelAndWrite(stats: MonthlySummaryStats,
                                                days: Int) async throws -> URL {
        let panel = NSSavePanel()
        panel.nameFieldStringValue =
            "NetMax-MonthlySummary-\(Self.filenameStamp(Date())).pdf"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.message = "Save the last-\(days)-days summary as PDF."

        // Same non-blocking `begin` shape as ReportCardShareView's saver:
        // works with or without a parent window (menu-bar popover has none).
        let response: NSApplication.ModalResponse = await withCheckedContinuation {
            continuation in
            panel.begin { resp in continuation.resume(returning: resp) }
        }
        guard response == .OK, let destination = panel.url else {
            throw ExportError.cancelled
        }
        try ReportCardPDF.write(
            MonthlySummary.pdfContent(for: stats, days: days), to: destination)
        return destination
    }

    /// Filesystem-safe UTC stamp for default filenames — same shape as
    /// ReportExporter's/ReportCardShareView's (`:` swapped for `-`) so all
    /// NetMax artifacts sort naturally side by side.
    static func filenameStamp(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return fmt.string(from: date)
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

private enum ExportStatus: Equatable {
    case idle
    case exporting
    case success
    case failure(String)
    case cancelled
}

#if DEBUG
// MARK: - Offline self-checks (W13B UB-2)
//
// Same convention as HistoryStoreTests / DashboardCardsTests: plain static
// checks compiled into the DEBUG build (never executed at runtime); the
// real offline verification runs via the temp-dir snippet harness.
enum ReportsMonthlyTests {
    @discardableResult
    static func runAll() -> Int {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            failures += condition ? 0 : 1
            if !condition { print("[ReportsMonthlyTests] FAIL: \(name)") }
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func rec(_ daysAgo: Double, _ raw: String) -> HistoryRecord {
            HistoryRecord(ts: now.addingTimeInterval(-daysAgo * 86_400),
                          mode: "baseline", params: [:], resultRaw: raw)
        }

        // Window membership: a 40-day-old run is excluded, a 5-day-old kept;
        // the average flows through the SAME extractor as the dashboard cards.
        let stats = MonthlySummary.compute(
            from: [rec(40, "{\"mbps\": 500}"), rec(5, "{\"mbps\": 100}")],
            now: now)
        check(stats.testsCount == 1, "30-day window excludes older runs")
        check(stats.averageMbps == 100, "average speed via card extractor")

        // Worst grade wins by the Waveform rubric order; absence reads nil.
        let graded = MonthlySummary.compute(
            from: [rec(1, "grade: B"), rec(2, "grade: D")], now: now)
        check(graded.worstGrade == "D", "worst grade wins")
        check(MonthlySummary.compute(from: [], now: now).worstGrade == nil,
              "no grades reads nil")
        check(MonthlySummary.compute(from: [], now: now).testsCount == 0,
              "empty history counts zero tests")

        // Quiet gate: a flat series flags nothing…
        let uniform = (1...12).map { rec(Double($0), "{\"mbps\": 100}") }
        check(MonthlySummary.compute(from: uniform, now: now).anomalyCount == 0,
              "flat series has no unusual readings")
        // …and a pronounced spike is counted.
        var spiky = uniform
        spiky[0] = rec(0.5, "{\"mbps\": 900}")
        check(MonthlySummary.compute(from: spiky, now: now).anomalyCount >= 1,
              "spike counted as unusual")

        // PDF mapping: four stat rows carrying the real numbers; the big
        // letter honestly renders "—" when no grade exists.
        let content = MonthlySummary.pdfContent(for: stats)
        check(content.title == "NetMax Monthly Summary", "pdf title set")
        check(content.sections.count == 1 && content.sections[0].rows.count == 4,
              "four stat rows reach the renderer")
        check(content.sections[0].rows[1].value == "100.0 Mbps",
              "average-speed row cites the measured figure")
        check(content.overallGrade == "—", "gradeless window renders a dash")

        // Range line shape.
        check(MonthlySummary.dateRangeText(from: now, to: now).contains("–"),
              "range line joins both endpoints")

        return failures
    }
}

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
