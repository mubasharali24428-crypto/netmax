//
//  ReportCardShareView.swift
//  netmax-desktop
//
//  ALPHA-A1-08 — report-card share UI (roadmap N7, consumes N5+N6 output).
//
//  Sheet/window content that previews the graded ISP report card built by
//  ReportCardModel (ALPHA-A1-06) from HistoryStore records, and hands it to
//  the world three ways:
//
//    • Share Link — renders the exact PDF via ReportCardPDF (ALPHA-A1-07)
//      into a temp file and presents it through NSSharingServicePicker.
//    • Save…      — NSSavePanel → writes the PDF wherever the user picks.
//    • Copy Summary — plain-text grade summary onto the clipboard.
//
//  Ownership boundaries respected:
//    - Reads history ONLY through the P2 surface (HistoryStore.loadAll /
//      HistoryRecord fields), same seam ReportsView uses.
//    - Maps the canonical `ReportCard` into ReportCardPDF's own `Content`
//      input here at the call site — exactly the shim A1-07's header
//      reserves this lane for. Neither sibling file is modified.
//
//  Pure mapping/formatting lives in `ReportCardShareComposer` (Foundation
//  only) so it is unit-testable offline; only the view touches AppKit.
//


import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Composer (pure mapping + text, no AppKit)

/// Pure translation layer between the canonical report card and its
/// shareable forms (PDF input struct, clipboard summary). Deterministic:
/// identical `ReportCard` + `generatedAt` produce byte-identical text.
enum ReportCardShareComposer {

    /// Single source of truth for the honest-limits sentence. Kept verbatim
    /// equal to ReportCardPDF.Content's default footer so screen and paper
    /// never disagree.
    static let limitsFooter =
        "Honest limits: results reflect this device and link at the "
            + "times measured — not an ISP's maximum capability."

    /// Window title used in PDF metadata, headers, and summary first line.
    static let cardTitle = "NetMax Connection Report Card"

    // MARK: PDF input mapping

    /// Map the canonical card into A1-07's renderer input. One section holds
    /// one row per graded metric; 0–100 scores normalize to the renderer's
    /// 0…1 bar scale; `.incomplete` sections hide the bar and say why.
    static func pdfContent(for card: ReportCard) -> ReportCardPDF.Content {
        ReportCardPDF.Content(
            title: cardTitle,
            dateRangeText: rangeLine(for: card),
            overallGrade: card.overall.rawValue,
            sections: [
                ReportCardPDF.Content.Section(
                    heading: "Measured metrics",
                    rows: card.sections.map(pdfRow)
                )
            ],
            limitsFooter: limitsFooter
        )
    }

    /// One canonical section → one renderer row.
    static func pdfRow(_ section: ReportCardSection) -> ReportCardPDF.Content.Row {
        let value: String
        switch section.grade {
        case .incomplete:
            value = "not enough runs"
        default:
            if let score = section.score {
                value = "\(section.grade.rawValue) · \(Int(score.rounded())) pts"
            } else {
                value = section.grade.rawValue
            }
        }
        return ReportCardPDF.Content.Row(
            metric: section.metric.rawValue,
            value: value,
            score: normalizedScore(of: section)
        )
    }

    /// Renderer bars want 0…1; the model grades in 0–100 points. Nil passes
    /// through nil (`Incomplete` draws no bar — honesty over decoration).
    static func normalizedScore(of section: ReportCardSection) -> Double? {
        section.score.map { min(max($0 / 100, 0), 1) }
    }

    // MARK: Baseline trend mapping (W7-3, consumes W7-2's comparisons)

    /// Provenance sentence shown under the metric rows — only when at least
    /// one row actually carries a baseline (see `hasAnyBaseline`).
    static let baselineFooter =
        "Comparisons use your own runs from 1–3 weeks ago"

    /// Maps a `BaselineComparison.metric` key onto the report-card row the
    /// trend indicator belongs beside. The P5b contract defines exactly
    /// `"mbps"`, `"loss"`, `"bloat-delta"`; unknown keys map to `nil` so
    /// upstream drift degrades to "no indicator", never to a wrong row.
    /// Jitter has no key, so its row honestly shows no comparison.
    static func metric(forComparisonKey key: String) -> ReportMetric? {
        switch key {
        case "mbps": .throughput
        case "loss": .loss
        case "bloat-delta": .bufferbloat
        default: nil
        }
    }

    /// True when any row carries a real 7–21-day baseline median. Gates the
    /// footer so it never promises a comparison that isn't there.
    static func hasAnyBaseline(_ comparisons: [BaselineComparison]) -> Bool {
        comparisons.contains { $0.baselineMedian != nil }
    }

    /// SF Symbol for a trend, per the W7-3 lane spec: up-right for better,
    /// down-right for worse, minus for flat, dashed for "no baseline yet".
    static func trendSymbol(for trend: BaselineTrend) -> String {
        switch trend {
        case .better: "arrow.up.right.circle"
        case .worse: "arrow.down.right.circle"
        case .flat: "minus.circle"
        case .noBaseline: "dashed.circle"
        }
    }

    /// Compact human form of a compared value with its unit, mirroring the
    /// engine's printed units (Mbps / % / ms). Whole numbers stay bare
    /// ("100 Mbps"); fractions keep one decimal ("2.5%").
    static func valueText(_ value: Double, forKey key: String) -> String {
        let rounded = (value * 10).rounded() / 10
        let number = rounded.rounded() == rounded
            ? String(Int(rounded))
            : String(format: "%.1f", rounded)
        switch key {
        case "mbps": return "\(number) Mbps"
        case "loss": return "\(number)%"
        default: return "\(number) ms"
        }
    }

    /// Spoken/announced phrasing for one row's trend. Cites the actual
    /// baseline median where one exists; `.noBaseline` says so outright
    /// instead of dressing absence up as a verdict.
    static func trendText(for comparison: BaselineComparison) -> String {
        switch comparison.trend {
        case .better:
            return "Trend: better than your 14-day baseline of "
                + valueText(comparison.baselineMedian ?? comparison.current,
                            forKey: comparison.metric)
        case .worse:
            return "Trend: worse than your 14-day baseline of "
                + valueText(comparison.baselineMedian ?? comparison.current,
                            forKey: comparison.metric)
        case .flat:
            return "Trend: close to your 14-day baseline of "
                + valueText(comparison.baselineMedian ?? comparison.current,
                            forKey: comparison.metric)
        case .noBaseline:
            return "No baseline yet"
        }
    }

    // MARK: Descriptive lines

    /// Honest description of what the card covers, cited in PDF and text.
    static func rangeLine(for card: ReportCard) -> String {
        guard card.runsConsidered > 0 else { return "No runs recorded yet" }
        var line = "\(card.runsConsidered) run\(card.runsConsidered == 1 ? "" : "s") considered"
        if let days = card.windowDays {
            line += days == 0
                ? " · within a single day"
                : " · spanning \(days) day\(days == 1 ? "" : "s")"
        }
        return line
    }

    // MARK: Clipboard summary

    /// Plain-text grade summary. Layout survives any destination (Mail,
    /// Notes, terminal) because it relies on punctuation, not alignment.
    ///
    ///     NetMax Connection Report Card — overall grade: B (78/100)
    ///     Generated Aug 23, 2026 at 2:45 PM · 12 runs considered · spanning 7 days
    ///
    ///     Download speed: B — median 42.5 Mbps over 12 runs.
    ///     Packet loss: Incomplete — only 2 usable runs — need 3+ before grading.
    ///     …
    ///
    ///     <limitsFooter>
    static func summaryText(for card: ReportCard, generatedAt: Date = Date()) -> String {
        let overall: String
        if let score = card.score {
            overall = "\(card.overall.rawValue) (\(Int(score.rounded()))/100)"
        } else {
            overall = card.overall.rawValue
        }

        var lines: [String] = []
        lines.append("\(cardTitle) — overall grade: \(overall)")
        lines.append("Generated \(timestampText(generatedAt)) · \(rangeLine(for: card))")
        lines.append("")
        for section in card.sections {
            // `.incomplete` summaries already open with "Incomplete:", so the
            // letter prefix is added only for genuinely graded sections.
            let gradePart = section.grade == .incomplete ? "" : "\(section.grade.rawValue) — "
            lines.append("\(section.metric.rawValue): \(gradePart)\(section.summary)")
        }
        lines.append("")
        lines.append(limitsFooter)
        return lines.joined(separator: "\n")
    }

    /// Human timestamp for the summary header (locale-aware, unlike the
    /// machine-facing contract-P2 ISO8601 stamps elsewhere).
    static func timestampText(_ date: Date) -> String {
        fmt.string(from: date)
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

// MARK: - View

/// Preview-and-share surface for the ISP report card.
///
/// Intended presentation is a sheet from whichever tab owns the entry point
/// (Reports is the natural host — one-liner for ATLAS, do not edit there):
///
///     @State private var showCardShare = false
///     // …on a Reports toolbar/button:
///     .sheet(isPresented: $showCardShare) { ReportCardShareView.makeDefault() }
///
/// The card is rebuilt from history whenever the view appears, matching
/// ReportsView's resurfacing behavior.
struct ReportCardShareView: View {

    // MARK: Dependencies

    /// Injectable so previews/tests can pass a fake; production resolves to
    /// the shared Lane-B store (same seam as ReportsView).
    private let store: HistoryStoreProviding

    init(store: HistoryStoreProviding = SystemHistoryStore()) {
        self.store = store
    }

    /// Convenience mirroring `ReportsView.makeDefault()` for callers holding
    /// a concrete store (tests).
    static func makeDefault(store: HistoryStore = .shared) -> ReportCardShareView {
        ReportCardShareView(store: SystemHistoryStore(backing: store))
    }

    // MARK: State

    @Environment(\.dismiss) private var dismiss
    @State private var records: [HistoryRecord] = []
    @State private var status: ShareStatus = .idle
    @State private var savedPath: String = ""
    @State private var shareItems: [Any] = []
    @State private var showSharePicker = false

    private var card: ReportCard { ReportCardModel.makeCard(from: records) }
    /// "How does the newest run compare to your 1–3-weeks-ago normal?" —
    /// W7-2's direction-aware comparison of the latest record against the
    /// 7–21-day window. Empty until history exists (the newest record is
    /// what's being judged).
    private var baselineComparisons: [BaselineComparison] {
        guard let latest = records.last else { return [] }
        return ReportCardModel.baselineComparisons(
            currentRecord: latest, history: records)
    }
    private var isSaving: Bool { status == .saving }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()

            ScrollView {
                cardPreview(card)
                    .padding(.vertical, 4)
            }
            .accessibilityLabel("Report card preview")

            Divider()
            statusFooter

            actionButtons
        }
        .padding(16)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 500, idealHeight: 560)
        .background(sharingAnchor)
        .task { reload() }
        .onAppear { reload() }  // rebuild whenever the sheet resurfaces
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Image(systemName: "doc.richtext")
                .foregroundStyle(.blue)
            Text("Connection Report Card")
                .font(.headline)
            Spacer()
            if let last = records.last {
                Text("Last run: \(ReportCardShareComposer.timestampText(last.ts))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func cardPreview(_ card: ReportCard) -> some View {
        cardPreviewBody(card, trendByMetric: baselineTrendMap)
    }

    /// Comparison rows keyed by the report-card row they decorate, so each
    /// `sectionRow` lookup stays O(1) and unmapped keys (upstream drift)
    /// simply never surface.
    private var baselineTrendMap: [ReportMetric: BaselineComparison] {
        Dictionary(
            baselineComparisons.compactMap { comparison in
                ReportCardShareComposer.metric(forComparisonKey: comparison.metric)
                    .map { ($0, comparison) }
            },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    /// Re-rendered SwiftUI summary of the card (screen twin of the PDF:
    /// big overall letter, per-metric grade rows with 0–100 score bars,
    /// plus a per-row trend indicator against the 1–3-weeks-ago baseline).
    private func cardPreviewBody(
        _ card: ReportCard,
        trendByMetric: [ReportMetric: BaselineComparison]
    ) -> some View {
        VStack(spacing: 16) {

            if card.runsConsidered == 0 {
                Label {
                    Text("No measurements yet — run a test to fill this card.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            VStack(spacing: 2) {
                Text("OVERALL GRADE")
                    .font(.caption.weight(.semibold))
                    .tracking(1.5)
                    .foregroundStyle(.secondary)
                Text(card.overall.rawValue)
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(tint(for: card.overall))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                if let score = card.score {
                    Text("\(Int(score.rounded())) out of 100")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(ReportCardShareComposer.rangeLine(for: card))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Overall grade")
            .accessibilityValue(accessibilityOverall(card))

            ForEach(card.sections, id: \.metric) { section in
                sectionRow(section, trend: trendByMetric[section.metric])
            }

            if ReportCardShareComposer.hasAnyBaseline(baselineComparisons) {
                Text(ReportCardShareComposer.baselineFooter)
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(
                        "Comparisons use your own runs from 1 to 3 weeks ago")
            }
        }
        .padding(.horizontal, 4)
    }

    /// One metric row: grade letter, summary, score bar — plus the W7-3
    /// trend indicator beside the row when the newest run has a comparison
    /// for this metric (jitter honestly gets none; there is no baseline key
    /// for it yet).
    private func sectionRow(
        _ section: ReportCardSection,
        trend: BaselineComparison?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(section.metric.rawValue)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let trend {
                    Image(systemName:
                            ReportCardShareComposer.trendSymbol(for: trend.trend))
                        .foregroundStyle(
                            trendTint(for: trend.trend),
                            trendEmphasis(for: trend.trend) ? .primary : .secondary)
                        .imageScale(.small)
                        .accessibilityHidden(true)
                }
                Text(section.grade.rawValue)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(tint(for: section.grade))
            }
            Text(section.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let normalized = ReportCardShareComposer.normalizedScore(of: section) {
                ProgressView(value: normalized)
                    .progressViewStyle(.linear)
                    .tint(tint(for: section.grade))
                    .accessibilityLabel("\(section.metric.rawValue) quality bar")
                    .accessibilityValue("\(Int(normalized * 100)) percent")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        // Trend phrasing rides along with the row so VoiceOver announces
        // "Download speed. Grade B. … Trend: better than your …" in one
        // stop instead of a separate mystery icon.
        .accessibilityLabel(accessibilityRowText(section, trend: trend))
    }

    /// Full spoken form of one row: grade, summary, then the honest trend
    /// sentence (or nothing at all when this metric has no comparison).
    private func accessibilityRowText(
        _ section: ReportCardSection,
        trend: BaselineComparison?
    ) -> String {
        let base = "\(section.grade.rawValue). \(section.summary)"
        guard let trend else { return base }
        return "\(base). \(ReportCardShareComposer.trendText(for: trend))"
    }

    /// Indicator color: green for better, orange (grade-D token) for worse;
    /// everything else stays de-emphasized.
    private func trendTint(for trend: BaselineTrend) -> Color {
        switch trend {
        case .better: Theme.gradeA
        case .worse: Theme.gradeD
        case .flat, .noBaseline: Theme.secondaryText
        }
    }

    /// `.better`/`.worse` are verdicts worth full emphasis; flat/no-baseline
    /// render as quiet secondary glyphs.
    private func trendEmphasis(for trend: BaselineTrend) -> Bool {
        switch trend {
        case .better, .worse: true
        case .flat, .noBaseline: false
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button(action: sharePDF) {
                Label("Share Link", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: [.command])
            .accessibilityHint("Opens the macOS share sheet with the report card PDF")

            Button(action: savePDF) {
                Label("Save…", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .disabled(isSaving)

            Button(action: copySummary) {
                Label("Copy Summary", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)

            Spacer()

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .accessibilityElement(children: .contain)
    }

    /// Anchored host for NSSharingServicePicker (pops from the Share button's
    /// neighborhood rather than mid-window).
    private var sharingAnchor: some View {
        SharingPickerAnchor(items: shareItems, isPresented: $showSharePicker)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var statusFooter: some View {
        switch status {
        case .idle:
            EmptyView()
        case .copied:
            Label {
                Text("Summary copied to the clipboard.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Summary copied to the clipboard")
        case .saving:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Preparing PDF…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Preparing PDF")
        case .saved(let path):
            Label {
                Text("Saved to \(path)")
                    .font(.footnote)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Report card saved to \(path)")
        case .failed(let message):
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
            .accessibilityLabel("Sharing failed: \(message)")
        case .cancelled:
            Text("Canceled.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Save canceled")
        }
    }

    // MARK: Actions

    private func reload() {
        records = store.loadAll()
    }

    /// Render the current card to a temp PDF and open the share sheet on it.
    private func sharePDF() {
        status = .idle
        do {
            let url = try writeTemporaryPDF()
            shareItems = [url]
            showSharePicker = true
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// NSSavePanel → write the PDF to the chosen destination.
    private func savePDF() {
        status = .saving
        Task {
            do {
                let url = try await presentSavePanelAndWrite()
                await MainActor.run {
                    savedPath = url.path
                    status = .saved(url.path)
                }
            } catch ShareError.cancelled {
                await MainActor.run { status = .cancelled }
            } catch {
                await MainActor.run { status = .failed(error.localizedDescription) }
            }
        }
    }

    /// Put the plain-text summary on the general pasteboard.
    private func copySummary() {
        let text = ReportCardShareComposer.summaryText(for: card)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        status = .copied
    }

    // MARK: PDF plumbing

    /// Render + write the current card's PDF into a predictably-named temp
    /// file for the share sheet. Throws when rendering produced no bytes.
    private func writeTemporaryPDF() throws -> URL {
        let content = ReportCardShareComposer.pdfContent(for: card)
        let stamp = Self.filenameStamp(Date())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NetMax-ReportCard-\(stamp).pdf")
        try ReportCardPDF.write(content, to: url)
        return url
    }

    /// Same non-blocking `begin` pattern as `ReportExporter.save` — works
    /// with or without a parent window (menu-bar popover has none).
    @MainActor
    private func presentSavePanelAndWrite() async throws -> URL {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "NetMax-ReportCard-\(Self.filenameStamp(Date())).pdf"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.message = "Save the connection report card as PDF."

        let response: NSApplication.ModalResponse = await withCheckedContinuation {
            continuation in
            panel.begin { resp in continuation.resume(returning: resp) }
        }

        guard response == .OK, let destination = panel.url else {
            throw ShareError.cancelled
        }
        try ReportCardPDF.write(
            ReportCardShareComposer.pdfContent(for: card), to: destination)
        return destination
    }

    /// Filesystem-safe UTC stamp for default filenames — kept byte-equal in
    /// spirit to `ReportExporter.filenameStamp` (colons swapped for `-`) so
    /// every NetMax artifact sorts naturally side by side.
    private static func filenameStamp(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return fmt.string(from: date)
    }

    // MARK: Appearance helpers

    private func accessibilityOverall(_ card: ReportCard) -> String {
        if let score = card.score {
            return "\(card.overall.rawValue), \(Int(score.rounded())) out of 100"
        }
        return card.overall.rawValue
    }

    private func tint(for grade: ReportGrade) -> Color {
        switch grade {
        case .aPlus, .a: .green
        case .b: .blue
        case .c: .orange
        case .d: .orange
        case .f: .red
        case .incomplete: .secondary
        }
    }
}

// MARK: - Status model

/// User-visible outcome of the last share/save/copy action.
private enum ShareStatus: Equatable {
    case idle
    case copied
    case saving
    case saved(String)
    case failed(String)
    case cancelled
}

/// Panel dismissal modeled as an error, matching `ReportExporter`'s shape.
private enum ShareError: LocalizedError {
    case cancelled

    var errorDescription: String? { "Save canceled." }
}

// MARK: - Sharing-service anchor

/// Zero-size AppKit shim: when `isPresented` flips true it presents an
/// `NSSharingServicePicker` anchored to this (invisible) view — placed in the
/// button row's background so the picker pops near the Share control. The
/// coordinator clears the binding when the user commits or dismisses, so the
/// next tap re-presents cleanly.
private struct SharingPickerAnchor: NSViewRepresentable {
    let items: [Any]
    @Binding var isPresented: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.host = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.host = nsView
        context.coordinator.parent = self
        if isPresented, !context.coordinator.presenting {
            context.coordinator.presenting = true
            let picker = NSSharingServicePicker(items: items)
            picker.delegate = context.coordinator
            picker.show(relativeTo: nsView.bounds, of: nsView, preferredEdge: .minY)
        } else if !isPresented {
            context.coordinator.presenting = false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSharingServicePickerDelegate {
        var parent: SharingPickerAnchor
        weak var host: NSView?
        var presenting = false

        init(_ parent: SharingPickerAnchor) {
            self.parent = parent
        }

        func picker(_ picker: NSSharingServicePicker,
                    didChoose service: NSSharingService?) {
            DispatchQueue.main.async { [weak self] in
                self?.presenting = false
                self?.parent.isPresented = false
            }
        }
    }
}

// MARK: - Offline self-check

/// Offline checks for the pure composer (same discipline as
/// HistoryStoreTests: Package.swift has no test target, so these compile into
/// the build as a plain enum and the real offline verification runs via a
/// temp-dir snippet harness against the same API).
enum ReportCardShareSelfCheck {

    /// Run all checks; returns number of failures (0 == pass).
    @discardableResult
    static func runAll() -> Int {
        var failures = 0
        func check(_ cond: Bool, _ what: String) {
            if !cond {
                failures += 1
                #if DEBUG
                print("[ReportCardShareSelfCheck] FAIL: \(what)")
                #endif
            }
        }

        func section(_ metric: ReportMetric, _ grade: ReportGrade,
                     _ score: Double?, count: Int = 3,
                     summary: String? = nil) -> ReportCardSection {
            // Mirror ReportCardModel's summary shapes exactly: incomplete
            // sections explain themselves ("Incomplete: …"), graded ones
            // cite their median.
            let text = summary
                ?? (grade == .incomplete
                    ? "Incomplete: only \(count - 2) usable run — need 3+ before grading."
                    : "median probe over \(count) runs.")
            return ReportCardSection(
                metric: metric, grade: grade, score: score,
                summary: text, sampleCount: count)
        }

        let fixed = Date(timeIntervalSince1970: 1_750_000_000)
        let graded = ReportCard(
            overall: .b, score: 78,
            sections: [
                section(.throughput, .aPlus, 100),
                section(.loss, .b, 85),
                section(.jitter, .incomplete, nil),
                section(.bufferbloat, .c, 62),
            ],
            runsConsidered: 9, windowDays: 4)

        // Score bars normalize into the renderer's 0…1 domain; incomplete → nil.
        check(ReportCardShareComposer.normalizedScore(of: graded.sections[0]) == 1.0,
              "score 100 normalizes to full bar")
        check(ReportCardShareComposer.normalizedScore(of: graded.sections[1]) == 0.85,
              "score 85 normalizes to 0.85")
        check(ReportCardShareComposer.normalizedScore(of: graded.sections[2]) == nil,
              "incomplete section hides its bar")

        // Out-of-domain scores still clamp (defensive against upstream drift).
        let weird = section(.throughput, .a, 250)
        check(ReportCardShareComposer.normalizedScore(of: weird) == 1.0,
              "over-100 score clamps to 1.0")

        // PDF mapping: four rows, honest value cells, footer carried verbatim.
        let content = ReportCardShareComposer.pdfContent(for: graded)
        check(content.title == ReportCardShareComposer.cardTitle, "pdf title set")
        check(content.sections.count == 1 && content.sections[0].rows.count == 4,
              "one row per metric reaches the renderer")
        check(content.sections[0].rows[2].score == nil
                  && content.sections[0].rows[2].value == "not enough runs",
              "incomplete row says so instead of inventing a bar")
        check(content.limitsFooter == ReportCardShareComposer.limitsFooter,
              "honest-limits footer carried verbatim")
        check(content.overallGrade == "B", "overall letter mapped")

        // Range line cites only real numbers.
        check(ReportCardShareComposer.rangeLine(for: graded)
                  == "9 runs considered · spanning 4 days",
              "range line cites runs and window")
        var empty = graded
        empty = ReportCard(overall: .incomplete, score: nil,
                           sections: [], runsConsidered: 0, windowDays: nil)
        check(ReportCardShareComposer.rangeLine(for: empty) == "No runs recorded yet",
              "empty history reported honestly")

        // Summary: covers every metric + footer, deterministic for fixed inputs.
        let text = ReportCardShareComposer.summaryText(for: graded, generatedAt: fixed)
        let again = ReportCardShareComposer.summaryText(for: graded, generatedAt: fixed)
        check(text == again, "identical inputs give identical summary bytes")
        check(text.contains("overall grade: B (78/100)"), "summary leads with overall grade")
        for metric in ReportMetric.allCases {
            check(text.contains(metric.rawValue), "summary lists \(metric.rawValue)")
        }
        check(text.contains("Incomplete"), "summary keeps the incomplete section honest")
        check(text.hasSuffix(ReportCardShareComposer.limitsFooter),
              "summary ends with the honest-limits footer")

        // MARK: W7-3 — trend-indicator mapping (consumes W7-2's comparisons)

        // Synthetic history shaped exactly like W7-2's own self-checks:
        // JSON payloads the parser reads structurally. Current carries all
        // three comparable metrics; the 8–12-day-old window carries five
        // usable mbps+loss samples (a real baseline) but no bloat, so the
        // bloat row exercises the honest `.noBaseline` path.
        func rec(ageDays: Double, json: String) -> HistoryRecord {
            HistoryRecord(
                ts: Date(timeIntervalSince1970: 1_800_000_000 - ageDays * 86_400),
                mode: "full", params: [:], resultRaw: json)
        }
        let currentRun = rec(
            ageDays: 0,
            json: #"{"mbps_down": 120, "loss_pct": 0.4, "bloat_delta_ms": 30}"#)
        let windowRuns = (8...12).map {
            rec(ageDays: Double($0),
                json: #"{"mbps_down": 100, "loss_pct": 2.0}"#)
        }
        let trends = ReportCardModel.baselineComparisons(
            currentRecord: currentRun, history: windowRuns)
        let mbpsRow = trends.first { $0.metric == "mbps" }
        let lossRow = trends.first { $0.metric == "loss" }
        let bloatRow = trends.first { $0.metric == "bloat-delta" }

        check(trends.count == 3
                  && mbpsRow?.trend == .better && mbpsRow?.baselineMedian == 100
                  && lossRow?.trend == .better && lossRow?.baselineMedian == 2
                  && bloatRow?.trend == .noBaseline
                  && bloatRow?.baselineMedian == nil,
              "window of five yields baselines; missing metric says noBaseline")

        // Key → report-card row mapping, including drift-degrades-to-nil.
        check(ReportCardShareComposer.metric(forComparisonKey: "mbps") == .throughput
                  && ReportCardShareComposer.metric(forComparisonKey: "loss") == .loss
                  && ReportCardShareComposer.metric(forComparisonKey: "bloat-delta")
                      == .bufferbloat
                  && ReportCardShareComposer.metric(forComparisonKey: "packet-loss")
                      == nil,
              "comparison keys map to rows; unknown keys map to nothing")

        // Symbols follow the lane spec per classification.
        check(ReportCardShareComposer.trendSymbol(for: .better)
                  == "arrow.up.right.circle"
                  && ReportCardShareComposer.trendSymbol(for: .worse)
                      == "arrow.down.right.circle"
                  && ReportCardShareComposer.trendSymbol(for: .flat)
                      == "minus.circle"
                  && ReportCardShareComposer.trendSymbol(for: .noBaseline)
                      == "dashed.circle",
              "each trend renders its specified SF Symbol")

        // Spoken text cites the real median; absence stays honest.
        check(ReportCardShareComposer.trendText(for: mbpsRow!)
                  == "Trend: better than your 14-day baseline of 100 Mbps",
              "better trend announces its baseline median")
        check(ReportCardShareComposer.trendText(for: lossRow!)
                  == "Trend: better than your 14-day baseline of 2%",
              "lower-is-better improvement reads as better")
        check(ReportCardShareComposer.trendText(for: bloatRow!) == "No baseline yet",
              "noBaseline row says so outright")

        // Worse + flat phrasing against the same 100 Mbps baseline.
        let slower = ReportCardModel.baselineComparisons(
            currentRecord: rec(ageDays: 0, json: #"{"mbps_down": 90}"#),
            history: windowRuns).first { $0.metric == "mbps" }
        check(slower?.trend == .worse
                  && ReportCardShareComposer.trendText(for: slower!)
                      == "Trend: worse than your 14-day baseline of 100 Mbps",
              "regression announces worse against the same baseline")
        let steady = ReportCardModel.baselineComparisons(
            currentRecord: rec(ageDays: 0, json: #"{"mbps_down": 102}"#),
            history: windowRuns).first { $0.metric == "mbps" }
        check(steady?.trend == .flat
                  && ReportCardShareComposer.trendText(for: steady!)
                      == "Trend: close to your 14-day baseline of 100 Mbps",
              "within the ±5% band reads as close, not better/worse")

        // Footer gate: on only when at least one row carries a baseline.
        check(ReportCardShareComposer.hasAnyBaseline(trends),
              "footer shown when a real baseline exists")
        let allBlind = ReportCardModel.baselineComparisons(
            currentRecord: currentRun, history: [])
        check(allBlind.count == 3
                  && allBlind.allSatisfy { $0.trend == .noBaseline }
                  && !ReportCardShareComposer.hasAnyBaseline(allBlind),
              "empty window hides the provenance footer honestly")

        // Value formatting mirrors engine units; fractions keep one decimal.
        check(ReportCardShareComposer.valueText(100, forKey: "mbps") == "100 Mbps"
                  && ReportCardShareComposer.valueText(42.5, forKey: "mbps")
                      == "42.5 Mbps"
                  && ReportCardShareComposer.valueText(2.04, forKey: "loss") == "2%"
                  && ReportCardShareComposer.valueText(52.3, forKey: "bloat-delta")
                      == "52.3 ms",
              "compared values format compactly with their units")

        return failures
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Graded card") {
    struct FixedStore: HistoryStoreProviding {
        func loadAll() -> [HistoryRecord] {
            (0..<6).map { i in
                HistoryRecord(
                    ts: Date().addingTimeInterval(Double(-i) * 3600),
                    mode: i % 2 == 0 ? "baseline" : "bloat",
                    params: ["streams": 8],
                    resultRaw: "{\"mbps\": \(120 - i * 10)}\npacket loss: 0.4%\njitter: 3.1 ms\nloaded increase: +\(18 * i).0 ms   grade: \(i < 3 ? "B" : "C")")
            }
        }
    }
    return ReportCardShareView(store: FixedStore())
}

#Preview("Empty history") {
    struct EmptyStore: HistoryStoreProviding {
        func loadAll() -> [HistoryRecord] { [] }
    }
    return ReportCardShareView(store: EmptyStore())
}
#endif
