//
//  DashboardCardsView.swift
//  netmax-desktop
//
//  L3-A2 — Dashboard metric cards (wave-1, ALPHA-A2-01).
//
//  A big-card row summarizing the latest measurements from local history
//  (contract P2): Latest Speed (Mbps) · Bufferbloat grade (Waveform/
//  DSLReports letter) · Packet loss (%) · overall Status word
//  (Excellent/Good/Fair/Poor). Pure presentational card subviews plus a
//  Foundation-only extraction layer (`DashboardMetrics`) that is unit-checked
//  offline by `DashboardCardsTests` at the bottom of this file.
//
//  Wave-3 (ALPHA-A3-07): beneath the cards, a Speed Trend strip plots the
//  last 20 recorded Mbps values (oldest-first, past → now) through
//  `SparklineView`'s `.line` style. It reuses `MetricExtractor` verbatim —
//  the same reader behind the Latest Speed card — so the curve always agrees
//  with the headline number. No speed-bearing history means no strip at all
//  (never an empty placeholder).
//
//  Sourcing rule: each card shows the MOST RECENT record that contains its
//  kind of value (newest-first scan), so a `loss` run never blanks the speed
//  card and vice versa. Status is the WORST available signal across speed
//  and loss tiers. With no history at all the view shows an empty state;
//  with history but unparseable payloads the cards read "—" honestly.
//
//  Contracts honored here:
//    • P2: reads exclusively through `HistoryStore.shared.loadAll()` — this
//      file never touches the JSONL file itself (Lane B owns HistoryStore).
//    • Hosting: designed as a tab-hostable root (`DashboardCardsView()`),
//      mirroring ModeLabView's conventions. Tab wiring stays with ATLAS;
//      RootView/App/MenuBarView are not edited here.
//

import SwiftUI

// MARK: - Model (Foundation-only so the extraction layer is harness-testable)

/// One sourced scalar shown on a card, with the run it came from.
struct MetricValue: Equatable {
    let value: Double
    let mode: String
    let date: Date
}

/// A sourced bufferbloat grade letter (plus optional loaded-latency delta).
struct GradeValue: Equatable {
    let letter: String
    let deltaMs: Double?
    let mode: String
    let date: Date
}

/// The four dashboard card inputs, extracted from history records.
///
/// Construction goes through `extract(from:)`; all fields are optional so a
/// partial history renders partial cards instead of failing.
struct DashboardMetrics: Equatable {
    let speed: MetricValue?
    let bloatGrade: GradeValue?
    let loss: MetricValue?
    let statusWord: String?

    /// Per-metric latest-value extraction (newest-first scan per field).
    ///
    /// Value recognition follows the engine's actual output shapes
    /// (netmax.py): labeled tokens first (`Mbps`, `loss`, `grade`,
    /// `increase`), then a conservative bare-number fallback for compact
    /// JSON payloads. Same best-effort spirit as HistoryView's TrendChart,
    /// which parses "the first number found" regardless of schema.
    static func extract(from records: [HistoryRecord]) -> DashboardMetrics {
        let newestFirst = records.sorted { $0.ts > $1.ts }

        var speed: MetricValue?
        var grade: GradeValue?
        var loss: MetricValue?

        for record in newestFirst {
            if speed == nil, let v = MetricExtractor.latestSpeedMbps(in: record.resultRaw) {
                speed = MetricValue(value: v, mode: record.mode, date: record.ts)
            }
            if grade == nil, let g = MetricExtractor.latestBloatGrade(in: record.resultRaw) {
                grade = GradeValue(letter: g.letter,
                                   deltaMs: g.deltaMs,
                                   mode: record.mode,
                                   date: record.ts)
            }
            if loss == nil, let l = MetricExtractor.latestPacketLossPercent(in: record.resultRaw) {
                loss = MetricValue(value: l, mode: record.mode, date: record.ts)
            }
            if speed != nil, grade != nil, loss != nil { break }
        }

        return DashboardMetrics(speed: speed,
                                bloatGrade: grade,
                                loss: loss,
                                statusWord: Self.statusWord(speedMbps: speed?.value,
                                                            lossPercent: loss?.value))
    }

    /// Last `maxSamples` speed readings across history, OLDEST-FIRST — the
    /// input shape ``SparklineView`` expects (left → right = past → now).
    ///
    /// Reuses `MetricExtractor.latestSpeedMbps` verbatim, so the trend curve
    /// and the Latest Speed card can never disagree about a payload. Runs
    /// whose payload carries no recognizable speed are skipped (never
    /// zero-filled); the survivor list is capped to the most recent
    /// `maxSamples` values. Empty when nothing measurable exists.
    static func speedTrend(from records: [HistoryRecord], maxSamples: Int = 20) -> [Double] {
        guard maxSamples > 0 else { return [] }
        let oldestFirst = records.sorted { $0.ts < $1.ts }
        return Array(oldestFirst.compactMap { MetricExtractor.latestSpeedMbps(in: $0.resultRaw) }
            .suffix(maxSamples))
    }

    /// Overall status word: the WORST available tier across speed and loss.
    ///
    /// Rubric (documented product decision, kept deliberately simple):
    ///   speed  ≥100 Mbps Excellent · ≥50 Good · ≥25 Fair · else Poor
    ///   loss   ≤0.5% Excellent · ≤2 Good · ≤5 Fair · else Poor
    /// Bufferbloat grade intentionally does NOT feed the word — it describes
    /// latency-under-load, not raw quality; it keeps its own graded card.
    static func statusWord(speedMbps: Double?, lossPercent: Double?) -> String? {
        let ranks = [Self.speedRank(speedMbps), Self.lossRank(lossPercent)].compactMap { $0 }
        guard let worst = ranks.max() else { return nil }
        // Explicit return: the body is not a single-expression function.
        switch worst {
        case 0: return "Excellent"
        case 1: return "Good"
        case 2: return "Fair"
        default: return "Poor"
        }
    }

    private static func speedRank(_ mbps: Double?) -> Int? {
        guard let mbps, mbps >= 0 else { return nil }
        if mbps >= 100 { return 0 }
        if mbps >= 50 { return 1 }
        if mbps >= 25 { return 2 }
        return 3
    }

    private static func lossRank(_ percent: Double?) -> Int? {
        guard let percent, percent >= 0 else { return nil }
        if percent <= 0.5 { return 0 }
        if percent <= 2 { return 1 }
        if percent <= 5 { return 2 }
        return 3
    }
}

// MARK: - Extraction helpers

/// Regex-based value readers for the engine's human-readable result text and
/// the bridge's pretty-printed JSON `data` payloads. File-private: only
/// `DashboardMetrics.extract` consumes these.
private enum MetricExtractor {

    /// Most recent speed-looking value (Mbps) in one raw payload.
    ///
    /// Order of preference:
    /// 1. Labeled key before the number (`"mbps": 87.4`, `speed = 42.1`);
    ///    occurrences whose number is really a latency/percent/volume figure
    ///    (`download: 115.0 MB`) are rejected.
    /// 2. Unit suffix after the number — the engine's `_print_speed` shape:
    ///    `multi-stream  8 stream(s)   1201.3 Mbps` (LAST match wins, so
    ///    `boost`'s headline multi-stream figure beats the baseline).
    /// 3. Conservative bare-number fallback (nothing annotated ms/%/MB…).
    static func latestSpeedMbps(in raw: String) -> Double? {
        if let token = labeledNumberToken(labels: ["mbps", "throughput", "speed", "download"],
                                          in: raw,
                                          rejectAfter: ["ms", "%", "mb", "kb", "gb"]),
           let value = Double(token), value >= 0 {
            return value
        }
        if let token = lastRegexGroup(#"([+-]?\d+(?:\.\d+)?)\s*(?i:mbps)\b"#, in: raw),
           let value = Double(token), value >= 0 {
            return value
        }
        return firstUnannotatedNumber(in: raw)
    }

    /// Packet-loss percentage: `packet loss: 0.0%` or `"loss": 0.0`,
    /// clamped to the physically meaningful 0...100 range.
    static func latestPacketLossPercent(in raw: String) -> Double? {
        guard let token = labeledNumberToken(labels: ["packet loss", "loss"], in: raw),
              let value = Double(token) else { return nil }
        return max(0, min(100, value))
    }

    /// Bufferbloat grade letter (`grade: B`, `"grade": "A+"`) plus the
    /// loaded-latency increase when the payload carries one (signed token,
    /// so `+12.0` reads positive).
    ///
    /// Rubric source: netmax.py BLOAT_GRADES (Waveform/DSLReports scale,
    /// A+ … F) — letters are validated against exactly that set, uppercase
    /// only (an ordinary lowercase "a" must never grade a link).
    static func latestBloatGrade(in raw: String) -> (letter: String, deltaMs: Double?)? {
        var deltaMs: Double?
        if let token = labeledNumberToken(labels: ["loaded increase", "increase", "delta"],
                                          in: raw),
           let parsed = Double(token) {
            deltaMs = parsed
        }

        let gradePattern = #"grade\s*["']?\s*[:=]?\s*["']?\s*(A\+|[A-F])(?![A-Za-z])"#
        if let letter = lastRegexGroup(gradePattern, in: raw),
           Self.validGrades.contains(letter) {
            return (letter, deltaMs)
        }

        // Last resort: a STANDALONE uppercase grade token ("verdict: C").
        if let token = lastRegexMatch(#"(?<![A-Za-z])(A\+|[A-F])(?![A-Za-z])"#, in: raw),
           Self.validGrades.contains(token) {
            return (token, deltaMs)
        }
        return nil
    }

    /// Exactly the letters netmax.py's rubric emits.
    static let validGrades: Set<String> = ["A+", "A", "B", "C", "D", "F"]

    // MARK: Private plumbing

    /// Last `<label> … [:|=] <signed number>` occurrence across the given
    /// labels (case-insensitive); returns the captured number token.
    ///
    /// Handles both JSON quoting (`"loss": 0`) and prose (`packet loss: 0.0%`).
    /// The lookbehind stops `loss` from matching inside identifiers, and the
    /// optional parenthesized-units group admits `mbps (down)` spellings.
    /// When `rejectAfter` is non-empty, an occurrence whose captured number
    /// is directly followed by one of those unit prefixes (case-insensitive)
    /// is skipped — e.g. `download: 115.0 MB` is volume, not Mbps.
    private static func labeledNumberToken(labels: [String],
                                           in text: String,
                                           rejectAfter: [String] = []) -> String? {
        for label in labels {
            let escaped = NSRegularExpression.escapedPattern(for: label)
            let pattern = "(?<![A-Za-z])(?i:" + escaped
                + ")\\s*(?:\\([^)]*\\))?\\s*[\"']?\\s*[:=]?\\s*[\"']?\\s*([+-]?\\d+(?:\\.\\d+)?)"
            guard let regex = try? NSRegularExpression(pattern: pattern,
                                                       options: [.caseInsensitive]) else { continue }
            let hits = regex.matches(
                in: text, options: [],
                range: NSRange(location: 0, length: (text as NSString).length))
            for hit in hits.reversed() {
                let numberRange = hit.range(at: 1)
                guard numberRange.location != NSNotFound,
                      let swiftNumberRange = Range(numberRange, in: text),
                      let wholeRange = Range(hit.range, in: text) else { continue }
                if !rejectAfter.isEmpty {
                    let after = text[wholeRange.upperBound...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    if rejectAfter.contains(where: { after.hasPrefix($0) }) { continue }
                }
                return String(text[swiftNumberRange])
            }
        }
        return nil
    }

    /// Captured group 1 of the LAST match of `pattern`, or nil.
    private static func lastRegexGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive]) else { return nil }
        let nsText = text as NSString
        let hits = regex.matches(in: text, options: [],
                                 range: NSRange(location: 0, length: nsText.length))
        guard let hit = hits.last,
              hit.numberOfRanges > 1,
              hit.range(at: 1).location != NSNotFound,
              let swiftRange = Range(hit.range(at: 1), in: text) else { return nil }
        return String(text[swiftRange])
    }

    /// First bare number whose suffix is not ms/%/MB (best-effort fallback).
    private static func firstUnannotatedNumber(in text: String) -> Double? {
        for match in allMatches(of: #"-?\d+(?:\.\d+)?"#, in: text) {
            let after = text[match.range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if after.hasPrefix("ms") || after.hasPrefix("%")
                || after.hasPrefix("mb") || after.hasPrefix("kb") || after.hasPrefix("gb") {
                continue
            }
            if let value = Double(match.text), value >= 0 {
                return value
            }
        }
        return nil
    }

    private static func lastRegexMatch(_ pattern: String, in text: String) -> String? {
        allMatches(of: pattern, in: text).last?.text
    }

    private struct RegexHit {
        let range: Range<String.Index>
        let text: String
    }

    private static func allMatches(of pattern: String, in text: String) -> [RegexHit] {
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive]) else {
            return []
        }
        let nsText = text as NSString
        let hits = regex.matches(in: text, options: [],
                                 range: NSRange(location: 0, length: nsText.length))
        return hits.compactMap { hit in
            guard let swiftRange = Range(hit.range, in: text) else { return nil }
            return RegexHit(range: swiftRange, text: String(text[swiftRange]))
        }
    }
}

// MARK: - View

/// Dashboard tab body: header + refresh, the four-card row, a speed-trend
/// sparkline strip (only when history carries speeds), empty state otherwise.
struct DashboardCardsView: View {
    @State private var records: [HistoryRecord] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if records.isEmpty {
                DashboardEmptyState()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        cardRow
                        speedTrendSection
                    }
                        .padding(.vertical, 2)
                }
            }

            Spacer(minLength: 0)

            Text("Cards reflect your latest saved runs — cannot exceed your ISP cap.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 300)
        .onAppear(perform: reload)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Image(systemName: "gauge")
                .foregroundStyle(.blue)
            Text("Dashboard")
                .font(.headline)
            Spacer()
            Button {
                reload()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Reload measurement history from disk")
            .accessibilityLabel("Refresh dashboard")
        }
    }

    // MARK: Cards

    private var metrics: DashboardMetrics { DashboardMetrics.extract(from: records) }

    private var cardRow: some View {
        let m = metrics
        return HStack(alignment: .top, spacing: 10) {
            MetricCard(
                title: "Latest Speed",
                icon: "gauge",
                value: m.speed.map { Self.trimmed($0.value) },
                unit: "Mbps",
                tint: Self.speedTint(m.speed?.value),
                detail: m.speed.map { "\($0.mode) · \(Self.relative($0.date))" }
                    ?? "no speed run yet"
            )
            MetricCard(
                title: "Bufferbloat",
                icon: "waveform.path",
                value: m.bloatGrade?.letter,
                unit: nil,
                tint: Self.gradeTint(m.bloatGrade?.letter),
                detail: bloatDetail(m.bloatGrade)
            )
            MetricCard(
                title: "Packet Loss",
                icon: "wifi.exclamationmark",
                value: m.loss.map { Self.trimmed($0.value) },
                unit: "%",
                tint: Self.lossTint(m.loss?.value),
                detail: m.loss.map { "\($0.mode) · \(Self.relative($0.date))" }
                    ?? "no loss run yet"
            )
            MetricCard(
                title: "Status",
                icon: "checkmark.seal",
                value: m.statusWord,
                unit: nil,
                tint: Self.statusTint(m.statusWord),
                detail: m.statusWord == nil ? "run a test to assess" : "composite of latest results"
            )
        }
    }

    // MARK: Speed trend

    /// Speed-trend strip under the cards: the last ≤20 Mbps values drawn as
    /// a smooth-line sparkline inside a card matching the metric tiles.
    /// Renders only when at least one run carries a recognizable speed.
    @ViewBuilder
    private var speedTrendSection: some View {
        let series = DashboardMetrics.speedTrend(from: records)
        if !series.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.caption)
                        .foregroundStyle(tint(for: series))
                    Text("Speed Trend")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text(caption(for: series))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                SparklineView(series,
                              style: .line,
                              color: tint(for: series),
                              height: 56)
                    .accessibilityLabel("Speed trend sparkline")
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
        }
    }

    /// Same traffic-light tint the Latest Speed card uses, keyed off the
    /// NEWEST sample (the right edge of the curve).
    private func tint(for series: [Double]) -> Color {
        Self.speedTint(series.last)
    }

    /// Honest run count: reads "last 20 runs" at the cap, fewer otherwise.
    private func caption(for series: [Double]) -> String {
        let count = series.count
        return "last \(count) run\(count == 1 ? "" : "s")"
    }

    private func bloatDetail(_ grade: GradeValue?) -> String {
        guard let grade else { return "no bloat run yet" }
        if let delta = grade.deltaMs {
            return String(format: "%+.1f ms under load · %@", delta, grade.mode)
        }
        return "latency under load · \(grade.mode)"
    }

    private func reload() {
        records = HistoryStore.shared.loadAll()
    }

    // MARK: Shared formatting / tinting (system colors only)

    private static func trimmed(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(format: "%.1f", value)
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    private static func speedTint(_ mbps: Double?) -> Color {
        guard let mbps else { return .gray }
        if mbps >= 100 { return .green }
        if mbps >= 25 { return .orange }
        return .red
    }

    /// Waveform-rubric traffic lights (letters validated by MetricExtractor).
    private static func gradeTint(_ letter: String?) -> Color {
        switch letter {
        case "A+", "A": .green
        case "B", "C": .yellow
        case "D": .orange
        case "F": .red
        default: .gray
        }
    }

    private static func lossTint(_ percent: Double?) -> Color {
        guard let percent else { return .gray }
        if percent <= 0.5 { return .green }
        if percent <= 2 { return .yellow }
        if percent <= 5 { return .orange }
        return .red
    }

    private static func statusTint(_ word: String?) -> Color {
        switch word {
        case "Excellent": .green
        case "Good": .yellow
        case "Fair": .orange
        case "Poor": .red
        default: .gray
        }
    }
}

// MARK: - One card (pure subview)

/// Presentational metric tile: label row, big value, supporting detail.
/// No state, no store access — everything arrives through the initializer.
struct MetricCard: View {
    let title: String
    let icon: String
    let value: String?
    let unit: String?
    let tint: Color
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(displayValue)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
    }

    private var displayValue: String {
        guard let value else { return "—" }
        return unit.map { "\(value) \($0)" } ?? value
    }

    private var accessibilityValue: String {
        guard let value else { return "not measured yet" }
        return unit.map { "\(value) \($0)" } ?? value
    }
}

// MARK: - Empty state

/// Shown when history has no records at all — mirrors HistoryView's tone.
private struct DashboardEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No measurements yet")
                .font(.headline)
            Text("Runs you start in Mode Lab (or the menu bar) are saved locally and summarized here as cards.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(24)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
// MARK: - Offline self-checks
//
// Same convention as HistoryStoreTests: Package.swift has no test target, so
// these compile into the DEBUG build as plain static checks (never executed
// at runtime). They convert 1:1 into XCTestCase methods if a test target is
// ever added.

enum DashboardCardsTests {
    @discardableResult
    static func runAll(now: Date = Date()) -> Int {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            failures += condition ? 0 : 1
            if !condition { print("[DashboardCardsTests] FAIL: \(name)") }
        }
        func record(_ mode: String, _ raw: String, _ secondsAgo: Double) -> HistoryRecord {
            HistoryRecord(ts: now.addingTimeInterval(-secondsAgo),
                          mode: mode, params: [:], resultRaw: raw)
        }

        // Labeled speed; boost's last Mbps wins (headline multi-stream).
        let boost = record("boost",
                           "single-stream  1 stream(s)   940.5 Mbps\n"
                           + "multi-stream  8 stream(s)   1201.3 Mbps", 60)
        check(MetricExtractor.latestSpeedMbps(in: boost.resultRaw) == 1201.3, "boost last mbps")

        // Compact JSON payload.
        check(MetricExtractor.latestSpeedMbps(in: #"{"mbps": 87.4}"#) == 87.4, "json mbps")

        // Packet loss: prose and JSON shapes, clamped to 0...100.
        check(MetricExtractor.latestPacketLossPercent(in: "packet loss: 0.0%") == 0.0, "prose loss")
        check(MetricExtractor.latestPacketLossPercent(in: #"{"loss": 1.5}"#) == 1.5, "json loss")

        // Grade letter + signed delta; invalid letters rejected.
        let bloat = MetricExtractor.latestBloatGrade(in: "loaded increase:   +12.0 ms   grade: B")
        check(bloat?.letter == "B", "grade letter")
        check((bloat?.deltaMs ?? 0) == 12.0, "positive delta")
        check(MetricExtractor.latestBloatGrade(in: #"{"grade": "A+"}"#)?.letter == "A+", "json grade")
        check(MetricExtractor.latestBloatGrade(in: "no grades here") == nil, "absent grade")

        // Bare-number fallback skips ms/%/MB annotations.
        check(MetricExtractor.latestSpeedMbps(in: "avg 146.9 ms, 12% lost, 115.0 MB moved") == nil,
              "annotated numbers skipped")

        // Status word: worst of speed/loss tiers; nil when nothing measurable.
        check(DashboardMetrics.statusWord(speedMbps: 431, lossPercent: 0.2) == "Excellent", "excellent")
        check(DashboardMetrics.statusWord(speedMbps: 30, lossPercent: 0.2) == "Fair", "fair")
        check(DashboardMetrics.statusWord(speedMbps: nil, lossPercent: 7) == "Poor", "poor loss only")
        check(DashboardMetrics.statusWord(speedMbps: nil, lossPercent: nil) == nil, "nothing measured")

        // Per-metric sourcing: newer loss-only run keeps the older speed alive.
        let mixed = DashboardMetrics.extract(from: [
            record("turbo", "multi-stream  8 stream(s)   431.2 Mbps", 600),
            record("loss", "packet loss: 0.4%", 60),
        ])
        check(mixed.speed?.value == 431.2 && mixed.speed?.mode == "turbo", "stale speed retained")
        check(mixed.loss?.value == 0.4 && mixed.loss?.mode == "loss", "fresh loss wins")
        check(mixed.bloatGrade == nil, "grade untouched")
        check(mixed.statusWord == "Excellent", "mixed status")

        // Empty history extracts to an all-nil dashboard.
        let empty = DashboardMetrics.extract(from: [])
        check(empty == DashboardMetrics(speed: nil, bloatGrade: nil, loss: nil, statusWord: nil),
              "empty extract")

        // Wave-3 speed trend: last ≤20 Mbps values, oldest-first for the
        // sparkline (left → right = past → now), same reader as the cards.
        check(DashboardMetrics.speedTrend(from: []).isEmpty, "trend empty history")
        check(DashboardMetrics.speedTrend(from: [record("loss", "packet loss: 0.4%", 30)]).isEmpty,
              "trend skips non-speed runs")
        let trendRuns = (1...25).map { i in
            record("turbo", "{\"mbps\": \(100 + i)}", Double(26 - i) * 60)
        }
        let trend = DashboardMetrics.speedTrend(from: trendRuns)
        check(trend.count == 20, "trend capped at 20")
        check(trend.count == 20 && trend.first == 106 && trend.last == 125,
              "trend keeps newest 20, oldest-first")

        return failures
    }
}
#endif
