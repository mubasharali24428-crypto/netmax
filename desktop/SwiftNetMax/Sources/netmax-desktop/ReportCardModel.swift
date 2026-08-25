import Foundation

// MARK: - Report card model (ISP verdict, contract P2 input)

/// Turns persisted measurement history (`HistoryRecord`s from HistoryStore)
/// into a graded ISP report card: one score per metric — download throughput,
/// packet loss, jitter, bufferbloat — plus an overall letter grade.
///
/// Design rules this file lives by:
///
/// **Pure.** Every function here is side-effect free: no I/O, no clock reads,
/// no singletons. Feed records in, get a value type out; identical input
/// yields identical output, so it is trivially testable and safe from any
/// thread or preview.
///
/// **Honest about sparse data** (house style). Fewer than `minRunsPerSection`
/// usable runs for a metric ⇒ that section grades `Incomplete` — never a made-
/// up number, never a guessed letter. `Incomplete` is excluded from averages
/// rather than silently counted as zero or F.
///
/// **Plan-agnostic.** The card never sees the user's advertised plan tier, so
/// throughput is scored against absolute utility bands (what a connection can
/// meaningfully do), not "% of advertised". When a plan tier becomes available
/// upstream, only `throughputScore` needs to change.
///
/// **Engine parity.** Bufferbloat letter cut-points mirror the engine's
/// `BLOAT_GRADES` rubric (netmax.py:270) and the letter set mirrors
/// `GRADE_ORDER = ["A+","A","B","C","D","F"]` (netmax.py:474), so the card and
/// the CLI can never disagree about the same measurement.
public enum ReportCardModel {

    /// Minimum usable runs before a section earns a real grade. Below this the
    /// section reports `Incomplete` — a median of 2 samples is a coin flip
    /// dressed up as statistics.
    public static let minRunsPerSection = 3

    /// Recency cap: only the newest N records are considered at all, so a
    /// years-old modem upgrade can't haunt today's card forever.
    public static let maxRunsConsidered = 60

    // MARK: Card assembly

    /// Build the report card from history records (any order; sorted here).
    ///
    /// - Parameter records: records as returned by `HistoryStore.loadAll()`.
    /// - Returns: a `ReportCard` with one section per `ReportMetric`; the
    ///   overall grade is `Incomplete` unless at least two sections carry
    ///   enough data to be scored.
    static func makeCard(from records: [HistoryRecord]) -> ReportCard {
        // Newest-first, deterministically tie-broken so equal timestamps
        // still produce a stable card.
        let considered = records
            .sorted { lhs, rhs in
                if lhs.ts != rhs.ts { return lhs.ts > rhs.ts }
                if lhs.mode != rhs.mode { return lhs.mode > rhs.mode }
                return lhs.resultRaw > rhs.resultRaw
            }
            .prefix(maxRunsConsidered)

        let windowDays: Int? = {
            guard let newest = considered.first, let oldest = considered.last else { return nil }
            return Int((newest.ts.timeIntervalSince(oldest.ts) / 86_400).rounded())
        }()

        let throughput = section(
            .throughput, from: Array(considered),
            modes: ["baseline", "turbo", "boost", "full"],
            value: { $0.mbpsDown },
            score: throughputScore(medianMbps:),
            unit: "Mbps"
        )
        let loss = section(
            .loss, from: Array(considered),
            modes: ["loss", "full"],
            value: { $0.lossPct },
            score: lossScore(medianPct:),
            unit: "% loss"
        )
        let jitter = section(
            .jitter, from: Array(considered),
            modes: ["jitter", "full"],
            value: { $0.jitterMs },
            score: jitterScore(medianMs:),
            unit: "ms jitter"
        )
        let bloat = section(
            .bufferbloat, from: Array(considered),
            modes: ["bloat", "bloat-eco", "full"],
            value: { $0.bloatDeltaMs ?? $0.bloatGrade.map(bloatDeltaProxy(for:)) },
            score: { bloatScore(deltaMs: $0) },
            unit: "ms added under load",
            format: { $0 >= 0 ? String(format: "+%.1f", $0) : String(format: "%.1f", $0) }
        )

        let sections = [throughput, loss, jitter, bloat]
        let scored = sections.compactMap(\.score)

        if scored.count >= 2 {
            let average = scored.reduce(0, +) / Double(scored.count)
            return ReportCard(
                overall: grade(forScore: average),
                score: average,
                sections: sections,
                runsConsidered: considered.count,
                windowDays: windowDays
            )
        }
        // Fewer than two graded sections: an overall letter would be theater.
        return ReportCard(
            overall: .incomplete,
            score: nil,
            sections: sections,
            runsConsidered: considered.count,
            windowDays: windowDays
        )
    }

    /// Build one section: gather usable samples, demand `minRunsPerSection`,
    /// score the median, and write a summary that cites only real numbers.
    private static func section(
        _ metric: ReportMetric,
        from records: [HistoryRecord],
        modes: Set<String>,
        value: @escaping (ParsedRunMetrics) -> Double?,
        score: (Double) -> (score: Double, grade: ReportGrade),
        unit: String,
        format: ((Double) -> String)? = nil
    ) -> ReportCardSection {
        let fmt = format ?? { String(format: "%.1f", $0) }
        let samples: [Double] = records.compactMap { record in
            guard modes.contains(record.mode) else { return nil }
            return value(parse(resultRaw: record.resultRaw))
        }
        let median = Self.median(samples)

        guard samples.count >= minRunsPerSection, let median else {
            let why = samples.isEmpty
                ? "no runs recorded for this metric yet"
                : "only \(samples.count) usable run\(samples.count == 1 ? "" : "s") — need \(minRunsPerSection)+ before grading"
            return ReportCardSection(
                metric: metric, grade: .incomplete, score: nil,
                summary: "Incomplete: \(why).", sampleCount: samples.count
            )
        }

        let result = score(median)
        return ReportCardSection(
            metric: metric,
            grade: result.grade,
            score: result.score,
            summary: "median \(fmt(median)) \(unit) over \(samples.count) runs.",
            sampleCount: samples.count
        )
    }

    // MARK: - Parsing (`result_raw` → structured metrics)

    /// Metrics extracted from one record's raw payload. Every field optional:
    /// payloads differ per engine mode and older records predate newer fields,
    /// and "this run says nothing about jitter" must stay expressible.
    public struct ParsedRunMetrics: Equatable {
        public var mbpsDown: Double?
        public var lossPct: Double?
        public var jitterMs: Double?
        public var bloatDeltaMs: Double?
        /// Letter only (`A+`…`F`) — `.incomplete` is a property of sections,
        /// never of a single run.
        public var bloatGrade: ReportGrade?

        public init() {}
    }

    /// Parse one record's `result_raw` into metrics.
    ///
    /// Two strategies, tried per-field in order:
    /// 1. **Structured:** the payload may be JSON (the bridge embeds valid
    ///    engine JSON verbatim). Known keys are looked up after flattening
    ///    nested objects — the schema is free-form, so several spellings are
    ///    accepted per field.
    /// 2. **Human text:** otherwise (or per-field when JSON lacks a key) the
    ///    engine's printed lines are matched, e.g. `940.5 Mbps`,
    ///    `packet loss: 2.0%`, `jitter: 3.4 ms`,
    ///    `loaded increase: +2144.0 ms   grade: C`.
    ///
    /// Garbage-guard: values outside physical plausibility (≤0 Mbps, loss >100%,
    /// negative jitter, non-finite anything) are discarded — treated as absent,
    /// never clamped into fake validity.
    public static func parse(resultRaw raw: String) -> ParsedRunMetrics {
        var out = ParsedRunMetrics()
        let flat = flattenedJSON(in: raw)
        // Non-JSON stdout arrives wrapped as {"raw": "..."}; match against the
        // unwrapped text so escaped newlines can't confuse the line patterns.
        let text = (flat["raw"] as? String) ?? raw

        out.mbpsDown =
            sane(number(flat, keys: ["mbps_down", "down_mbps", "download_mbps", "throughput_mbps", "mbps"]), allowZero: false)
            ?? lastCapture(pattern: #"([0-9]+(?:\.[0-9]+)?)\s*Mbps"#, in: text).flatMap { sane($0, allowZero: false) }

        out.lossPct =
            clampedPercent(number(flat, keys: ["loss_pct", "packet_loss_pct", "loss_percent", "packet_loss"]))
            ?? firstCapture(pattern: #"(?i)loss[^0-9%\n]{0,30}?([0-9]+(?:\.[0-9]+)?)\s*%"#, in: text).flatMap(clampedPercent)

        out.jitterMs =
            sane(number(flat, keys: ["jitter_ms", "jitter"]))
            ?? firstCapture(pattern: #"(?i)jitter[^0-9\n]{0,20}?([0-9]+(?:\.[0-9]+)?)\s*ms"#, in: text).flatMap { sane($0) }

        out.bloatDeltaMs =
            finite(number(flat, keys: ["bloat_delta_ms", "delta_ms", "loaded_increase_ms", "increase_ms"]))
            ?? firstCapture(pattern: #"(?i)(?:loaded\s+increase|bloat)[^0-9+\-\n]{0,16}?([+-]?[0-9]+(?:\.[0-9]+)?)\s*ms"#, in: text).flatMap(finite)

        if let letter = (flat["grade"] as? String) ?? (flat["bloat_grade"] as? String) {
            out.bloatGrade = ReportGrade(rawValue: letter.trimmingCharacters(in: .whitespaces))
        }
        if out.bloatGrade == nil {
            // First explicit grade letter in the text; `A+` must win over `A`,
            // hence longest-first alternation.
            out.bloatGrade = firstGradeLetter(in: text)
                .flatMap(ReportGrade.init(rawValue:))
        }
        return out
    }

    // MARK: - Scoring primitives

    /// Median of `values`; `nil` only for empty input. Even-length inputs
    /// average the two middle samples (standard median).
    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }

    /// Plan-agnostic download bands: what the connection can meaningfully do.
    /// (4 Mbps ≈ one HD stream; 25 ≈ 4K; 100+ ≈ whole-house headroom.)
    public static func throughputScore(medianMbps mbps: Double) -> (score: Double, grade: ReportGrade) {
        switch mbps {
        case 100...: return (100, .aPlus)
        case 50..<100: return (92, .a)
        case 25..<50: return (82, .b)
        case 10..<25: return (68, .c)
        case 4..<10: return (55, .d)
        default: return (35, .f)
        }
    }

    /// Loss bands: 0% is perfect; >5% median breaks nearly every app.
    public static func lossScore(medianPct pct: Double) -> (score: Double, grade: ReportGrade) {
        switch pct {
        case ...0: return (100, .aPlus)
        case ...0.5: return (95, .a)
        case ...1: return (85, .b)
        case ...3: return (70, .c)
        case ...5: return (50, .d)
        default: return (25, .f)
        }
    }

    /// Jitter bands (median consecutive-RTT delta): ≤1 ms is imperceptible;
    /// >40 ms makes calls unusable even on a fast line.
    public static func jitterScore(medianMs ms: Double) -> (score: Double, grade: ReportGrade) {
        switch ms {
        case ...1: return (100, .aPlus)
        case ...5: return (90, .a)
        case ...10: return (78, .b)
        case ...20: return (62, .c)
        case ...40: return (45, .d)
        default: return (25, .f)
        }
    }

    /// Bufferbloat letter → points, on the Waveform-style scale the engine
    /// already uses. F keeps nonzero points: even a flooded buffer delivers
    /// *something*.
    public static func bloatScore(letter: ReportGrade) -> (score: Double, grade: ReportGrade) {
        (bloatPoints(letter), letter)
    }

    /// Score a bloat section from the latency delta, deriving the letter with
    /// the engine's exact cut-points when the payload didn't print one.
    public static func bloatScore(deltaMs delta: Double) -> (score: Double, grade: ReportGrade) {
        bloatScore(letter: bloatLetter(deltaMs: delta))
    }

    /// Same cut-points as `BLOAT_GRADES` (netmax.py:270): the first threshold
    /// the delta falls under wins; ≥400 ms (and any negative-noise edge) maps
    /// exactly like the Python `for limit, grade in BLOAT_GRADES` loop.
    public static func bloatLetter(deltaMs delta: Double) -> ReportGrade {
        switch delta {
        case ..<5: return .aPlus
        case ..<30: return .a
        case ..<60: return .b
        case ..<200: return .c
        case ..<400: return .d
        default: return .f
        }
    }

    /// Points for a bloat letter (mirrors `bloatScore`); unknown → lowest.
    public static func bloatPoints(_ letter: ReportGrade) -> Double {
        switch letter {
        case .aPlus: return 100
        case .a: return 92
        case .b: return 80
        case .c: return 62
        case .d: return 42
        case .f: return 15
        case .incomplete: return 0
        }
    }

    /// Overall letter for an averaged 0–100 score. Bands sit slightly above
    /// the per-metric midpoints so an overall grade is never rosier than the
    /// sections feeding it.
    public static func grade(forScore score: Double) -> ReportGrade {
        switch score {
        case 93...: return .aPlus
        case 85..<93: return .a
        case 72..<85: return .b
        case 58..<72: return .c
        case 45..<58: return .d
        default: return .f
        }
    }

    // MARK: - Baseline comparison (today vs. 1–3 weeks ago)

    /// Baseline age window relative to the record being judged: samples
    /// 7–21 days old count as "your recent normal". Both ends inclusive.
    private static let baselineWindowDays: ClosedRange<Double> = 7...21

    /// Fewer usable window samples than this ⇒ `.noBaseline` — a median of
    /// four runs is a coin flip dressed up as statistics (house style).
    private static let baselineMinSamples = 5

    /// Relative dead-band around the baseline: within ±5% of it is `flat`,
    /// not improvement or regression cosplaying as signal.
    private static let baselineFlatBand = 0.05

    /// Compare `currentRecord`'s metrics against the median of the same
    /// metrics measured 7–21 days earlier.
    ///
    /// One row per metric key: `"mbps"` (download Mbps, higher is better),
    /// `"loss"` (packet-loss %, lower is better), `"bloat-delta"`
    /// (ms added under load, lower is better). Rules:
    ///
    /// - Baseline = median of that metric's usable values across window
    ///   records; fewer than `baselineMinSamples` such values ⇒
    ///   `.noBaseline` with a `nil` median, never a thin-median guess.
    /// - Within ±5% of the baseline (scaled by |baseline|, so a 0%-loss
    ///   floor stays honest: only 0-vs-0 is flat there) ⇒ `.flat`;
    ///   beyond the band the metric's direction decides better/worse.
    /// - A metric absent from `currentRecord` itself yields no row — there
    ///   is nothing honest to compare. Mode-agnostic: every prior record's
    ///   payload is parsed regardless of `mode`.
    static func baselineComparisons(
        currentRecord: HistoryRecord,
        history: [HistoryRecord]
    ) -> [BaselineComparison] {
        // (metric key, higher-is-better?, extractor from a parsed run)
        let specs: [(name: String, higherIsBetter: Bool, value: (ParsedRunMetrics) -> Double?)] = [
            ("mbps", true, { $0.mbpsDown }),
            ("loss", false, { $0.lossPct }),
            ("bloat-delta", false, { $0.bloatDeltaMs }),
        ]
        let current = parse(resultRaw: currentRecord.resultRaw)
        let inWindow = history.filter { record in
            let days = currentRecord.ts.timeIntervalSince(record.ts) / 86_400
            return baselineWindowDays.contains(days)
        }

        return specs.compactMap { spec in
            guard let now = spec.value(current) else { return nil }
            let samples = inWindow.compactMap { spec.value(parse(resultRaw: $0.resultRaw)) }
            guard samples.count >= baselineMinSamples,
                  let baseline = median(samples) else {
                return BaselineComparison(
                    metric: spec.name, current: now,
                    baselineMedian: nil, trend: .noBaseline
                )
            }
            let band = baselineFlatBand * abs(baseline)
            let trend: BaselineTrend =
                abs(now - baseline) <= band ? .flat
                : (spec.higherIsBetter == (now > baseline)) ? .better : .worse
            return BaselineComparison(
                metric: spec.name, current: now,
                baselineMedian: baseline, trend: trend
            )
        }
    }

    // MARK: - Debug self-checks (harness-only)

#if DEBUG
    /// Exercises the baseline machinery end-to-end on synthetic history.
    /// Returns the number of failed checks (0 = clean) and prints PASS/FAIL
    /// per check: the 5-sample `.noBaseline` gate, better/worse/flat
    /// classification per metric direction, the loss 0-floor, and the window
    /// boundary (a 6-day-old sample is excluded, an 8-day-old one included).
    @discardableResult
    static func runAll() -> Int {
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            print("\(condition ? "PASS" : "FAIL"): \(name)")
            if !condition { failures += 1 }
        }
        let day = 86_400.0
        func record(ageDays: Double, mbps: Double? = nil, loss: Double? = nil, bloat: Double? = nil) -> HistoryRecord {
            var fields: [String] = []
            if let mbps = mbps { fields.append("\"mbps_down\": \(mbps)") }
            if let loss = loss { fields.append("\"loss_pct\": \(loss)") }
            if let bloat = bloat { fields.append("\"bloat_delta_ms\": \(bloat)") }
            return HistoryRecord(
                ts: Date(timeIntervalSince1970: 1_800_000_000 - ageDays * day),
                mode: "full",
                params: [:],
                resultRaw: "{" + fields.joined(separator: ",") + "}"
            )
        }
        func trends(currentMb: Double, currentLoss: Double, currentBloat: Double) -> [String: BaselineTrend] {
            let cur = record(ageDays: 0, mbps: currentMb, loss: currentLoss, bloat: currentBloat)
            let window = [
                record(ageDays: 9, mbps: 98, loss: 2, bloat: 50),
                record(ageDays: 11, mbps: 99, loss: 2, bloat: 50),
                record(ageDays: 13, mbps: 100, loss: 2, bloat: 50),
                record(ageDays: 15, mbps: 101, loss: 2, bloat: 50),
                record(ageDays: 17, mbps: 102, loss: 2, bloat: 50),
            ]
            var byName: [String: BaselineTrend] = [:]
            for row in baselineComparisons(currentRecord: cur, history: window) {
                byName[row.metric] = row.trend
            }
            return byName
        }

        // Gate: five usable window samples ⇒ a real baseline for exactly the
        // metric those samples carry; four ⇒ noBaseline for every metric.
        let fiveMbps = (1...5).map { record(ageDays: 10 + Double($0), mbps: 100 + Double($0)) }
        let mixedCurrent = record(ageDays: 0, mbps: 120, loss: 1, bloat: 30)
        let gatedFive = baselineComparisons(currentRecord: mixedCurrent, history: fiveMbps)
        check("gate: 5 window samples ⇒ baseline for mbps, noBaseline for absent metrics",
              gatedFive.count == 3
              && gatedFive.first { $0.metric == "mbps" }?.baselineMedian == 103
              && gatedFive.first { $0.metric == "loss" }?.trend == .noBaseline
              && gatedFive.first { $0.metric == "bloat-delta" }?.trend == .noBaseline)
        let gatedFour = baselineComparisons(currentRecord: mixedCurrent, history: Array(fiveMbps.prefix(4)))
        check("gate: 4 window samples ⇒ noBaseline everywhere",
              gatedFour.count == 3
              && gatedFour.allSatisfy { $0.trend == .noBaseline && $0.baselineMedian == nil })

        // Classification: direction rules per metric.
        let improved = trends(currentMb: 110, currentLoss: 1, currentBloat: 40)
        check("classify: improvements are better (all metrics)",
              improved == ["mbps": .better, "loss": .better, "bloat-delta": .better])
        let regressed = trends(currentMb: 90, currentLoss: 3, currentBloat: 60)
        check("classify: regressions are worse (all metrics)",
              regressed == ["mbps": .worse, "loss": .worse, "bloat-delta": .worse])
        let steady = trends(currentMb: 103, currentLoss: 2.05, currentBloat: 52)
        check("classify: within ±5% is flat (all metrics)",
              steady == ["mbps": .flat, "loss": .flat, "bloat-delta": .flat])

        // Loss floor: baseline 0% leaves no relative band to hide in.
        let zeroWindow = (1...5).map { record(ageDays: 10 + Double($0), loss: 0) }
        let stillZero = baselineComparisons(currentRecord: record(ageDays: 0, loss: 0), history: zeroWindow)
        let slippedZero = baselineComparisons(currentRecord: record(ageDays: 0, loss: 0.01), history: zeroWindow)
        check("loss 0 floor: 0→0 flat, 0→anything worse",
              stillZero.first?.trend == .flat && slippedZero.first?.trend == .worse)

        // Window boundary: 6 days old is too young, 8 days counts; the far
        // edge is inclusive at 21 days, out at 22.
        let tooYoung = (1...6).map { _ in record(ageDays: 6, mbps: 200) }
        check("boundary: 6-day-old sample excluded",
              baselineComparisons(currentRecord: record(ageDays: 0, mbps: 100), history: tooYoung)
                  .first?.trend == .noBaseline)
        let eightDays = (1...5).map { _ in record(ageDays: 8, mbps: 100) }
        check("boundary: 8-day-old sample included",
              baselineComparisons(currentRecord: record(ageDays: 0, mbps: 100), history: eightDays)
                  .first?.trend == .flat)
        let farEdgeIn = (1...5).map { _ in record(ageDays: 21, mbps: 100) }
        check("boundary: 21-day-old sample still in window",
              baselineComparisons(currentRecord: record(ageDays: 0, mbps: 100), history: farEdgeIn)
                  .first?.trend == .flat)
        let farEdgeOut = (1...5).map { _ in record(ageDays: 22, mbps: 100) }
        check("boundary: 22-day-old sample out of window",
              baselineComparisons(currentRecord: record(ageDays: 0, mbps: 100), history: farEdgeOut)
                  .first?.trend == .noBaseline)

        print(failures == 0 ? "runAll: all checks passed" : "runAll: \(failures) check(s) FAILED")
        return failures
    }
#endif

    // MARK: - Internals (pure helpers)

    /// Where a letter-only bloat payload sits on the delta scale, for the
    /// median-and-summary machinery that expects a number. Midpoint of the
    /// letter's band — used solely to describe the section, never to rescore.
    private static func bloatDeltaProxy(for letter: ReportGrade) -> Double {
        switch letter {
        case .aPlus: return 2.5
        case .a: return 17.5
        case .b: return 45
        case .c: return 130
        case .d: return 300
        default: return 500
        }
    }

    private static func flattenedJSON(in raw: String) -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return [:] }
        var flat: [String: Any] = [:]
        flatten(dict, into: &flat)
        return flat
    }

    private static func flatten(_ dict: [String: Any], into out: inout [String: Any]) {
        for (key, value) in dict {
            if let nested = value as? [String: Any] {
                flatten(nested, into: &out) // deepest value wins; keys are unique enough in practice
            } else {
                out[key] = value
            }
        }
    }

    /// First present key → Double, accepting numbers and numeric strings.
    private static func number(_ flat: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let v = flat[key] as? Double { return v }
            if let v = flat[key] as? Int { return Double(v) }
            if let v = flat[key] as? String, let d = Double(v) { return d }
        }
        return nil
    }

    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func sane(_ value: Double?, allowZero: Bool = true) -> Double? {
        guard let value = finite(value), allowZero ? value >= 0 : value > 0 else { return nil }
        return value
    }

    private static func clampedPercent(_ value: Double?) -> Double? {
        guard let value = finite(value), (0...100).contains(value) else { return nil }
        return value
    }

    /// First regex capture group (first match).
    private static func firstCapture(pattern: String, in text: String) -> Double? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        return capture(re, at: 1, in: text, occurrence: 0)
    }

    /// Last regex capture group's number: for throughput we deliberately take
    /// the FINAL `N Mbps` in the payload — `boost`/`full` print single-stream
    /// first and multi-stream last, and the aggregate is the delivered rate a
    /// household actually experiences. Single-run modes have only one match.
    private static func lastCapture(pattern: String, in text: String) -> Double? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let count = re.numberOfMatches(in: text, options: [], range: fullRange(text))
        guard count > 0 else { return nil }
        return capture(re, at: 1, in: text, occurrence: count - 1)
    }

    private static func capture(_ re: NSRegularExpression, at group: Int, in text: String, occurrence: Int) -> Double? {
        let ns = text as NSString
        let matches = re.matches(in: text, options: [], range: fullRange(text))
        guard occurrence < matches.count else { return nil }
        let range = matches[occurrence].range(at: group)
        guard range.location != NSNotFound else { return nil }
        return Double(ns.substring(with: range))
    }

    /// Longest-first so `A+` is matched before its `A` prefix could claim it.
    private static func firstGradeLetter(in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"grade[^A-Z+]{0,6}(A\+|[A-F])(?![A-Za-z])"#) else { return nil }
        let ns = text as NSString
        guard let match = re.firstMatch(in: text, options: [], range: fullRange(text)),
              match.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    private static func fullRange(_ text: String) -> NSRange {
        NSRange(location: 0, length: (text as NSString).length)
    }
}

// MARK: - Value types

/// The four graded axes of an ISP report card.
public enum ReportMetric: String, CaseIterable {
    case throughput = "Download speed"
    case loss = "Packet loss"
    case jitter = "Jitter"
    case bufferbloat = "Bufferbloat"
}

/// Letter grade for a metric or the whole card — the engine's `GRADE_ORDER`
/// plus `incomplete`, the honest "not enough data" state (house style: sparse
/// history is reported as sparse, never papered over with a guess).
public enum ReportGrade: String, Comparable {
    case aPlus = "A+"
    case a = "A"
    case b = "B"
    case c = "C"
    case d = "D"
    case f = "F"
    case incomplete = "Incomplete"

    /// Ordinal for ordering; `incomplete` sorts last and is excluded from
    /// averages by the model — it is never quietly folded in as zero/F.
    public var rank: Int {
        switch self {
        case .aPlus: return 6
        case .a: return 5
        case .b: return 4
        case .c: return 3
        case .d: return 2
        case .f: return 1
        case .incomplete: return 0
        }
    }

    public static func < (lhs: ReportGrade, rhs: ReportGrade) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// One graded row of the card.
public struct ReportCardSection: Equatable {
    public let metric: ReportMetric
    /// `.incomplete` when fewer than `ReportCardModel.minRunsPerSection`
    /// usable runs exist for this metric.
    public let grade: ReportGrade
    /// 0…100 points earned; `nil` exactly when `grade == .incomplete`.
    public let score: Double?
    /// One-line human explanation citing only measured numbers.
    public let summary: String
    /// Usable runs behind this section — the honesty counter.
    public let sampleCount: Int
}

/// The full ISP report card.
public struct ReportCard: Equatable {
    /// `.incomplete` unless at least two sections were scoreable — a letter
    /// built from a single axis would overstate what was actually measured.
    public let overall: ReportGrade
    /// 0–100 average over scored sections; `nil` iff `overall == .incomplete`.
    public let score: Double?
    /// One section per `ReportMetric`, in declaration order.
    public let sections: [ReportCardSection]
    /// Records actually considered (after the `maxRunsConsidered` recency trim).
    public let runsConsidered: Int
    /// Days between newest and oldest considered run; `nil` for empty history.
    public let windowDays: Int?

    public func section(_ metric: ReportMetric) -> ReportCardSection? {
        sections.first { $0.metric == metric }
    }
}

// MARK: - Baseline comparison value types

/// How today's number relates to its 1–3-week-old baseline, direction-aware
/// per metric: higher is better for throughput; lower is better for loss and
/// bufferbloat.
public enum BaselineTrend: Equatable {
    case better
    case worse
    case flat
    case noBaseline
}

/// One row of "how does this run's metric compare to your recent normal?" —
/// e.g. current 110 Mbps vs a baseline median of 100 ⇒ `.better`.
public struct BaselineComparison: Equatable {
    /// Metric key: `"mbps"`, `"loss"`, or `"bloat-delta"`.
    public let metric: String
    /// The current record's value for this metric.
    public let current: Double
    /// Median of window samples; `nil` exactly when `trend == .noBaseline`.
    public let baselineMedian: Double?
    /// Classification against the baseline (±5% flat band where a relative
    /// band exists; `.noBaseline` when the window held fewer than five
    /// usable samples).
    public let trend: BaselineTrend
}
