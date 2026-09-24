//
//  MetricsExtraction.swift
//  netmax-desktop
//
//  Task 4 view decomposition — Foundation-only model layer extracted from
//  DashboardCardsView so giant view files shrink and the extraction logic
//  is independently harness-testable (DashboardCardsTests still live at
//  the bottom of DashboardCardsView; MetricExtractor/DashboardMetrics move
//  here). No behavior change: same types, same names, same module.
//

import Foundation

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

    // MARK: Week-over-week deltas + hour coverage (W13B TEAM-UB / UB-3)

    /// One trailing-7d vs prior-7d comparison for a metric.
    /// `delta` is nil unless BOTH windows have usable samples (a missing
    /// prior week must say so honestly — S-051's core rule).
    struct WeekDelta: Equatable {
        enum Direction { case up, down, flat }
        let currentMedian: Double
        let previousMedian: Double?
        var delta: Double? {
            guard let previousMedian, previousMedian != 0 else { return nil }
            return (currentMedian - previousMedian) / previousMedian * 100
        }
        var direction: Direction {
            guard let delta, abs(delta) >= Self.flatBandPercent else { return .flat }
            return delta > 0 ? .up : .down
        }
        /// Within ±5% a metric counts as unchanged (documented product band).
        static let flatBandPercent = 5.0

        /// The honest one-line form shown on the cards. Lower-is-better for
        /// loss: an increase there reads "▲" but the wording never implies
        /// better/worse — the number speaks for itself.
        var text: String {
            guard let delta else {
                return "no prior week to compare"
            }
            let arrow = direction == .up ? "▲" : direction == .down ? "▼" : "•"
            let magnitude = Int(abs(delta).rounded())
            return "\(arrow) \(magnitude)% vs last week"
        }
    }

    /// Median of a numeric series (average of middle two on even counts).
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[mid] }
        return (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Trailing-window vs previous-window medians over records carrying
    /// `read`. Windows are [now−w, now) and [now−2w, now−w); `now` injectable
    /// for determinism. Current window empty → all-nil delta (honest).
    static func weekDelta(from records: [HistoryRecord],
                          read: (HistoryRecord) -> Double?,
                          windowDays: Double = 7,
                          now: Date = Date()) -> WeekDelta {
        let cutoffCurrent = now.addingTimeInterval(-windowDays * 86_400)
        let cutoffPrevious = now.addingTimeInterval(-2 * windowDays * 86_400)
        let current = records.filter { $0.ts >= cutoffCurrent }.compactMap(read)
        let previous = records.filter { $0.ts < cutoffCurrent && $0.ts >= cutoffPrevious }
            .compactMap(read)
        guard let currentMedian = median(current) else {
            // Nothing measurable this week; still surface the prior median
            // when it exists so the line can say why it stays quiet.
            return WeekDelta(currentMedian: median(previous) ?? 0,
                             previousMedian: median(previous))
        }
        return WeekDelta(currentMedian: currentMedian,
                         previousMedian: median(previous))
    }

    /// Convenience readers for the three delta lines under the cards.
    static func speedWeekDelta(from records: [HistoryRecord], now: Date = Date()) -> WeekDelta {
        weekDelta(from: records,
                  read: { MetricExtractor.latestSpeedMbps(in: $0.resultRaw) },
                  now: now)
    }

    static func lossWeekDelta(from records: [HistoryRecord], now: Date = Date()) -> WeekDelta {
        weekDelta(from: records,
                  read: { MetricExtractor.latestPacketLossPercent(in: $0.resultRaw) },
                  now: now)
    }

    /// Bloat deltas compare the loaded-latency Δ in ms when payloads carry it.
    static func bloatWeekDelta(from records: [HistoryRecord], now: Date = Date()) -> WeekDelta {
        weekDelta(from: records,
                  read: { MetricExtractor.latestBloatGrade(in: $0.resultRaw)?.deltaMs },
                  now: now)
    }

    /// Hour-of-day test coverage (S-029 groundwork): count of runs started
    /// in each LOCAL hour, oldest-first input order irrelevant. Exactly 24
    /// buckets, index 0 = midnight–00:59 local.
    static func hourCoverage(from records: [HistoryRecord],
                             calendar: Calendar = .current) -> [Int] {
        var buckets = [Int](repeating: 0, count: 24)
        for record in records {
            let hour = calendar.component(.hour, from: record.ts)
            guard hour >= 0 && hour < 24 else { continue } // defensive; can't happen
            buckets[hour] += 1
        }
        return buckets
    }

    /// Opacity ramp for one coverage cell: zero samples stay nearly invisible
    /// (honest absence), the busiest hour is fully opaque, everything between
    /// scales linearly with a visible floor.
    static func coverageOpacity(count: Int, peak: Int) -> Double {
        guard peak > 0, count > 0 else { return 0.08 }
        return 0.25 + 0.75 * (Double(count) / Double(peak))
    }

    /// Tooltip for one cell ("2pm · 5 runs"; empty hours say so plainly).
    static func coverageHelp(hour: Int, count: Int) -> String {
        let label = "\(hour % 12 == 0 ? 12 : hour % 12)\(hour < 12 ? "am" : "pm")"
        return count == 0 ? "\(label) — no tests" : "\(label) · \(count) run\(count == 1 ? "" : "s")"
    }

    /// Spoken summary of the strip: the busiest hour(s), or honest absence.
    static func coverageSummary(_ buckets: [Int]) -> String {
        guard let peak = buckets.max(), peak > 0 else { return "No runs yet" }
        let busiest = buckets.indices.filter { buckets[$0] == peak }
        let names = busiest.map { coverageHelp(hour: $0, count: $0) }.map {
            $0.components(separatedBy: " · ").first ?? $0
        }
        return names.joined(separator: ", ") + ", most tested"
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
/// the bridge's pretty-printed JSON `data` payloads.
/// Internal since W13B TEAM-UB (UB-2): the Reports monthly-summary card and
/// History's run-comparison sheet parse payloads through these SAME readers,
/// so a card, the trend sparkline, the monthly PDF, and a diff row can never
/// disagree about the same result_raw.
enum MetricExtractor {

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
