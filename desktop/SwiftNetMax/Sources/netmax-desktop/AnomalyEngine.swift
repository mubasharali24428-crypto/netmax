//
//  AnomalyEngine.swift
//  netmax-desktop
//
//  TEAM-2 T2-a (W4 X5 oracle lane) — offline trend analysis over local
//  history (contract P2). Pure Foundation port of the ideas in
//  netmax_trends.py (rolling median + MAD outlier detection); the Swift
//  side reuses the payload-parsing patterns already proven by
//  DashboardMetrics/MetricExtractor so a card, the trend sparkline, and an
//  anomaly flag can never disagree about the same result_raw.
//
//  Public surface:
//      Anomaly                     — one flagged point (index/ts/value/
//                                    expected/severity)
//      AnomalyMetric               — mbps · loss · jitter
//      MetricSample                — (ts, value) pair, oldest-first series
//      AnomalyEngine.extractSeries(_:metric:)
//                                  — records → [MetricSample], tolerant
//      AnomalyEngine.rollingMedian(_:window:)
//                                  — trailing-window median (prefix edges)
//      AnomalyEngine.anomalies(in:k:minimumSamples:window:)
//                                  — MAD flags over a sample series
//      AnomalyEngine.recentAnomalies(records:metric:lookback:...)
//                                  — one-call dashboard/history query
//
//  LAWS THIS FILE IMPLEMENTS (mission W4, TEAM-2):
//    • CONFIDENCE WORDING LAW — every human-readable string produced here
//      describes readings as "unusual" / "differs from your typical …".
//      The words "broken" and "problem" (and near-synonyms implying
//      failure) must never appear; the engine reports observations about
//      data, never verdicts about equipment. `SelfChecks` enforces this.
//    • QUIET GATE — fewer than `minimumSamples` (default 10) usable
//      samples → [] . Thin data is never interpreted; no speculation.
//    • DETERMINISM — no Date(), no randomness, no locale-dependent
//      formatting anywhere in the decision path. Timestamps flow in with
//      the records; callers inject "now" if they ever need one.
//
//  Wiring notes for sibling lanes live in AnomalyAnnotationsView.swift
//  (T2-b owns the UI half: markers, tooltips, dashboard badge).
//

import Foundation

// MARK: - Model

/// Metric kinds the engine can analyze.
///
/// Only metrics with a physically comparable scale across runs qualify;
/// bufferbloat grades (letters) are excluded deliberately.
enum AnomalyMetric: String, CaseIterable, Identifiable {
    case mbps
    case loss
    case jitter

    var id: String { rawValue }

    /// Human unit suffix used in generated descriptions.
    var unit: String {
        switch self {
        case .mbps: return "Mbps"
        case .loss: return "%"
        case .jitter: return "ms"
        }
    }

    /// Spoken name for accessibility strings ("packet loss", not "loss").
    var displayName: String {
        switch self {
        case .mbps: return "speed"
        case .loss: return "packet loss"
        case .jitter: return "jitter"
        }
    }
}

/// One extracted measurement: the record's timestamp plus its metric value.
/// Series built from these are OLDEST-FIRST (file order semantics).
struct MetricSample: Equatable {
    let ts: Date
    let value: Double
}

/// One flagged point in a series.
///
/// - `index` points into the analyzed sample array (0-based, oldest-first).
/// - `expected` is the rolling median at that index — what the link had
///   been doing right before/around the reading, not a promise.
/// - `severity` is a purely descriptive tier (how many multiples of the
///   typical spread the reading sits at); it never implies breakage.
struct Anomaly: Equatable {
    enum Severity: String, Equatable {
        /// Reading sits between k and 2k typical spreads from the norm.
        case notable
        /// Reading sits beyond 2k typical spreads from the norm.
        case pronounced
    }

    let index: Int
    let ts: Date
    let value: Double
    let expected: Double
    let severity: Severity
}

// MARK: - Engine

/// Offline anomaly detection over `HistoryStore` records.
///
/// Algorithm (ported conceptually from netmax_trends.py):
/// 1. Extract the metric series, oldest-first, skipping unreadable payloads
///    silently (same tolerance as the rest of the app).
/// 2. Compute a trailing-window rolling median (default window 7; short
///    prefixes use whatever exists).
/// 3. Residuals = value − rolling median. MAD = median of |residual|.
/// 4. Flag points whose |residual| exceeds the flag threshold
///    max(k × MAD, MINIMUM_RESIDUAL_FRACTION × |typical level|,
///    MINIMUM_RESIDUAL_FLOOR). The two floor terms exist because MAD
///    collapses on smooth low-jitter data (MAD ≈ 0.3 on a clean ±2%
///    link makes k·MAD ≈ 1, which routine wobble would exceed); the
///    fraction term scales "unusual" with the link's own level and the
///    absolute term keeps ultra-tight spreads from flagging sub-wobble
///    departures. Genuine spikes (a 3× jump) clear the floored
///    threshold by an order of magnitude and still fire.
enum AnomalyEngine {

    /// Quiet gate: below this many usable samples, say nothing at all.
    static let minimumReliableSamples = 10

    /// Flag-threshold floor, absolute term: no reading is reported as
    /// unusual over a departure smaller than this many metric units, no
    /// matter how tight the observed spread. Keeps smooth low-jitter
    /// series quiet instead of grading their wobble against itself.
    static let minimumResidualFloor = 5.0

    /// Flag-threshold floor, scale term: the flag threshold never drops
    /// below this fraction of the typical reading level, so what counts
    /// as "unusual" scales with the link rather than with its jitter.
    static let minimumResidualFraction = 0.05

    // MARK: Extraction

    /// Pull one metric out of history records → oldest-first `[MetricSample]`.
    ///
    /// Records are sorted oldest-first internally regardless of input order,
    /// so the returned indices are stable across reloads. Records whose
    /// payload carries no recognizable value for `metric` are skipped
    /// silently — never zero-filled — matching `DashboardMetrics` behavior.
    ///
    /// Parsing follows the patterns already proven by `MetricExtractor`
    /// (DashboardCardsView.swift): labeled key/value shapes first (JSON
    /// quoting or prose), then unit-suffixed CLI text, then a conservative
    /// bare-number fallback for compact payloads.
    static func extractSeries(_ records: [HistoryRecord],
                              metric: AnomalyMetric) -> [MetricSample] {
        let oldestFirst = records.sorted { $0.ts < $1.ts }
        var series: [MetricSample] = []
        for record in oldestFirst {
            guard let value = Self.metricValue(in: record.resultRaw, metric: metric) else {
                continue
            }
            series.append(MetricSample(ts: record.ts, value: value))
        }
        return series
    }

    // MARK: Trend math

    /// Trailing-window median at each point (same length as the input).
    ///
    /// Edges use the available prefix (window i+1 at index i). `window = 1`
    /// returns the values unchanged numerically. Empty in → empty out.
    static func rollingMedian(_ values: [Double], window: Int = 7) -> [Double] {
        precondition(window >= 1, "window must be >= 1")
        guard !values.isEmpty else { return [] }
        var out: [Double] = []
        out.reserveCapacity(values.count)
        for i in values.indices {
            let lo = max(0, i + 1 - window)
            out.append(median(Array(values[lo...i])))
        }
        return out
    }

    /// Flag points deviating more than `k` MADs from their rolling median.
    ///
    /// QUIET GATE: fewer than `minimumSamples` usable samples → []
    /// (never speculate on thin data). Deterministic: same input, same
    /// output, forever.
    static func anomalies(in samples: [MetricSample],
                          k: Double = 3.0,
                          minimumSamples: Int = AnomalyEngine.minimumReliableSamples,
                          window: Int = 7) -> [Anomaly] {
        guard samples.count >= minimumSamples else { return [] }
        let values = samples.map(\.value)
        let rolled = rollingMedian(values, window: window)
        let residuals = zip(values, rolled).map { $0 - $1 }
        let mad = median(residuals.map(abs))

        // Flag threshold per point: k·MAD, but never below a floor that
        // scales with the link (fraction of the typical level) and never
        // below an absolute minimum. On smooth low-jitter data MAD
        // collapses and k·MAD alone flags routine wobble; the floor keeps
        // such series quiet while genuine spikes clear it many times over.
        var flagged: [Anomaly] = []
        for i in samples.indices {
            let residual = residuals[i]
            let magnitude = abs(residual)
            let typical = abs(rolled[i])
            // Combined threshold: k·MAD (0 on a flat signal — the floors
            // then decide, preserving "an exact departure from a steady
            // link IS the observation"), floored by the scale term and
            // the absolute term.
            let threshold = max(k * mad,
                                Self.minimumResidualFraction * typical,
                                Self.minimumResidualFloor)
            guard magnitude >= threshold else { continue }
            // Severity grades against the same combined threshold.
            let severity: Anomaly.Severity = magnitude >= 2 * threshold
                ? .pronounced : .notable
            flagged.append(Anomaly(index: i,
                                   ts: samples[i].ts,
                                   value: values[i],
                                   expected: rolled[i],
                                   severity: severity))
        }
        return flagged
    }

    /// Convenience for pure-value series (self-checks, previews): indices of
    /// the flagged points. Applies the same quiet gate.
    static func anomalyIndices(_ values: [Double],
                               k: Double = 3.0,
                               minimumSamples: Int = AnomalyEngine.minimumReliableSamples,
                               window: Int = 7) -> [Int] {
        let stamps = (0..<values.count).map { i in
            Date(timeIntervalSinceReferenceDate: Double(i))
        }
        let samples = zip(stamps, values).map { MetricSample(ts: $0, value: $1) }
        return anomalies(in: samples, k: k, minimumSamples: minimumSamples, window: window)
            .map(\.index)
    }

    /// One-call query for surfaces: analyze `records` for `metric` and hand
    /// back only anomalies inside the most recent `lookback` SAMPLES of the
    /// extracted series (the last 5 runs, by default). The quiet gate sees
    /// the FULL series length, so a spike inside the first 10 ever-recorded
    /// runs stays quiet — exactly as designed.
    static func recentAnomalies(records: [HistoryRecord],
                                metric: AnomalyMetric,
                                lookback: Int = 5,
                                k: Double = 3.0,
                                window: Int = 7) -> [Anomaly] {
        let series = extractSeries(records, metric: metric)
        let all = anomalies(in: series, k: k, window: window)
        let cutoff = series.count - max(0, lookback)
        return all.filter { $0.index >= cutoff }
    }

    // MARK: Confidence-law wording

    /// Tooltip/detail text for one anomaly. CONFIDENCE WORDING LAW: frames
    /// the reading as unusual relative to the user's own typical range —
    /// never as damage, failure, or a problem.
    static func describe(_ anomaly: Anomaly, metric: AnomalyMetric) -> String {
        let direction = anomaly.value > anomaly.expected ? "higher" : "lower"
        let intensity = anomaly.severity == .pronounced ? "well " : ""
        return "This run read "
            + "\(Self.trimmed(anomaly.value)) \(metric.unit) — "
            + "your typical reading around here is about "
            + "\(Self.trimmed(anomaly.expected)) \(metric.unit). "
            + "That's \(intensity)\(direction) than usual and differs from "
            + "your typical results, so it stands out as unusual."
    }

    /// Compact badge line (row annotations): "unusual · 262 vs ~102 Mbps".
    static func brief(_ anomaly: Anomaly, metric: AnomalyMetric) -> String {
        "unusual · \(Self.trimmed(anomaly.value)) vs "
            + "~\(Self.trimmed(anomaly.expected)) \(metric.unit)"
    }

    // MARK: Payload parsing (same patterns as DashboardMetrics.MetricExtractor)

    /// Best-effort metric pull from one raw payload; nil when absent.
    /// Internal (not private) so the DEBUG self-checks can exercise the
    /// parsers directly, same as DashboardCardsTests does for MetricExtractor.
    static func metricValue(in raw: String, metric: AnomalyMetric) -> Double? {
        switch metric {
        case .mbps:
            // 1. Labeled number ("mbps": 87.4 / speed = 42.1), rejecting
            //    occurrences that are really latency/percent/volume figures.
            if let token = labeledNumberToken(labels: ["mbps", "throughput", "speed", "download"],
                                              in: raw,
                                              rejectAfter: ["ms", "%", "mb", "kb", "gb"]),
               let value = Double(token), value >= 0 {
                return value
            }
            // 2. Unit suffix AFTER the number — engine's _print_speed shape
            //    ("multi-stream  8 stream(s)   1201.3 Mbps"); LAST wins so
            //    boost's headline beats its baseline line.
            if let token = lastRegexGroup(#"([+-]?\d+(?:\.\d+)?)\s*(?i:mbps)\b"#, in: raw),
               let value = Double(token), value >= 0 {
                return value
            }
            // 3. Conservative bare-number fallback (nothing annotated ms/%/MB…).
            return firstUnannotatedNumber(in: raw)

        case .loss:
            // Ping's statistics block first — "3 packets transmitted,
            // 33.3% packet loss" puts the VALUE before the words.
            if let token = lastRegexGroup(#"(\d+(?:\.\d+)?)\s*%\s*packet\s*loss"#, in: raw),
               let value = Double(token) {
                return max(0, min(100, value))
            }
            // Then labeled shapes ("packet loss: 0.0%" / "loss": 0) —
            // clamped to physical 0…100.
            guard let token = labeledNumberToken(labels: ["packet loss", "loss"], in: raw),
                  let value = Double(token) else { return nil }
            return max(0, min(100, value))

        case .jitter:
            // "jitter: 7.5 ms" / "jitter": 3.2 first.
            if let token = labeledNumberToken(labels: ["jitter"], in: raw),
               let value = Double(token) {
                return max(0, value)
            }
            // Ping's tail line next: "rtt min/avg/max/mdev =
            // 1.0/2.0/3.0/4.810 ms" (slash-separated) or the same four
            // statistics space-separated — the jitter figure is the FOURTH.
            if let token = lastRegexGroup(
                #"(?i:mdev|stddev)\s*=\s*\d+(?:\.\d+)?[/\s]+\d+(?:\.\d+)?[/\s]+\d+(?:\.\d+)?[/\s]+(\d+(?:\.\d+)?)"#,
                in: raw),
               let value = Double(token) {
                return max(0, value)
            }
            // Plain tagged mdev/stddev ("mdev = 4.8") last.
            if let token = labeledNumberToken(labels: ["mdev", "stddev"], in: raw),
               let value = Double(token) {
                return max(0, value)
            }
            return nil
        }
    }

    /// Last `<label> … [:|=] <signed number>` occurrence across the given
    /// labels (case-insensitive); returns the captured number token.
    /// Handles JSON quoting ("loss": 0) and prose (packet loss: 0.0%).
    /// Occurrences whose number is followed by a `rejectAfter` unit prefix
    /// are skipped (e.g. "download: 115.0 MB" is volume, not Mbps).
    private static func labeledNumberToken(labels: [String],
                                           in text: String,
                                           rejectAfter: [String] = []) -> String? {
        for label in labels {
            let escaped = NSRegularExpression.escapedPattern(for: label)
            let pattern = "(?<![A-Za-z])(?i:" + escaped
                + ")\\s*(?:\\([^)]*\\))?\\s*[\"']?\\s*[:=]?\\s*[\"']?\\s*([+-]?\\d+(?:\\.\\d+)?)"
            guard let regex = try? NSRegularExpression(pattern: pattern,
                                                       options: [.caseInsensitive]) else { continue }
            let nsText = text as NSString
            let hits = regex.matches(in: text, options: [],
                                     range: NSRange(location: 0, length: nsText.length))
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

    /// First bare number whose suffix is not ms/%/MB/KB/GB (fallback).
    private static func firstUnannotatedNumber(in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"-?\d+(?:\.\d+)?"#,
                                                   options: [.caseInsensitive]) else { return nil }
        let nsText = text as NSString
        let hits = regex.matches(in: text, options: [],
                                 range: NSRange(location: 0, length: nsText.length))
        for hit in hits {
            guard let wholeRange = Range(hit.range, in: text) else { continue }
            let after = text[wholeRange.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if after.hasPrefix("ms") || after.hasPrefix("%")
                || after.hasPrefix("mb") || after.hasPrefix("kb") || after.hasPrefix("gb") {
                continue
            }
            if let value = Double(String(text[wholeRange])), value >= 0 {
                return value
            }
        }
        return nil
    }

    // MARK: Shared math helpers

    /// Median of `values` ([] → 0). Sorted-copy based, fully deterministic.
    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1
            ? sorted[mid]
            : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Locale-independent number rendering ("1201.3", "102").
    static func trimmed(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(format: "%.1f", value)
    }
}

// MARK: - Offline self-checks
//
// Same convention as DashboardCardsTests / HistoryStoreTests: Package.swift
// has no test target, so these compile into the DEBUG build as plain static
// checks (never executed at runtime). They convert 1:1 into XCTestCase
// methods. The standalone /tmp harness exercises the same assertions.

#if DEBUG
enum AnomalyEngineTests {

    @discardableResult
    static func runAll(now: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)) -> Int {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            failures += condition ? 0 : 1
            if !condition { print("[AnomalyEngineTests] FAIL: \(name)") }
        }
        func record(_ mode: String, _ raw: String, _ secondsAgo: Double) -> HistoryRecord {
            HistoryRecord(ts: now.addingTimeInterval(-secondsAgo),
                          mode: mode, params: [:], resultRaw: raw)
        }

        // -- extraction ----------------------------------------------------
        let mixed = [
            record("turbo", #"{"mbps": 100}"#, 200),
            record("loss", "packet loss: 0.4%", 160),          // skipped for mbps
            record("baseline", "not a payload at all", 120),    // skipped silently
            record("turbo", #"{"mbps": 104}"#, 80),
        ]
        let speeds = AnomalyEngine.extractSeries(mixed, metric: .mbps)
        check(speeds.count == 2 && speeds.first?.value == 100 && speeds.last?.value == 104,
              "extractSeries: skips foreign/silent payloads, oldest-first")

        check(AnomalyEngine.extractSeries([], metric: .loss).isEmpty, "extractSeries: empty")
        check(AnomalyEngine.metricValue(in: "packet loss: 12.5%", metric: .loss) == 12.5,
              "parse loss prose")
        check(AnomalyEngine.metricValue(in: "3 packets transmitted, 33.3% packet loss",
                                        metric: .loss) == 33.3,
              "parse ping statistics block")
        check(AnomalyEngine.metricValue(in: "jitter: 7.5 ms", metric: .jitter) == 7.5,
              "parse jitter prose")
        check(AnomalyEngine.metricValue(in: "rtt min/avg/max/mdev = 1.0 2.0 3.0 4.810",
                                        metric: .jitter) == 4.81,
              "parse jitter mdev fallback")

        // -- rolling median --------------------------------------------------
        check(AnomalyEngine.rollingMedian([], window: 7).isEmpty, "rollingMedian: empty")
        check(AnomalyEngine.rollingMedian([4, 1, 3, 2], window: 7) == [4, 2.5, 3, 2.5],
              "rollingMedian: prefix edges")
        check(AnomalyEngine.rollingMedian([9, 7, 8, 6, 10, 5, 11], window: 3).count == 7,
              "rollingMedian: same length")

        // -- quiet gate -------------------------------------------------------
        let nineFlat = (1...9).map { MetricSample(ts: now.addingTimeInterval(Double($0)),
                                                  value: 100) }
        var nineSpiky = nineFlat
        nineSpiky[4] = MetricSample(ts: nineSpiky[4].ts, value: 900)
        check(AnomalyEngine.anomalies(in: nineSpiky).isEmpty,
              "quiet gate: 9 samples even with a wild reading → []")
        check(AnomalyEngine.anomalies(in: []).isEmpty, "quiet gate: empty series → []")

        // -- injected spike is flagged, exactly once, near its index ----------
        var spikeValues = [Double](repeating: 100, count: 20)
        spikeValues[14] = 260
        let spikeStamps = (0..<20).map { now.addingTimeInterval(Double($0) * 60) }
        let spikeSeries = zip(spikeStamps, spikeValues).map { MetricSample(ts: $0, value: $1) }
        let spikeFlags = AnomalyEngine.anomalies(in: spikeSeries)
        check(spikeFlags.count == 1, "spike: exactly 1 flag (got \(spikeFlags.count))")
        check(spikeFlags.first?.index == 14, "spike: flagged at index 14")
        check(spikeFlags.first?.expected == 100, "spike: expected = rolling median 100")
        check(spikeFlags.first?.ts == spikeStamps[14], "spike: carries the record's ts")
        check(spikeFlags.first?.severity == .pronounced, "spike: flat-series severity")

        // -- clean series stays silent ----------------------------------------
        let cleanValues: [Double] = [
            98.5, 101.2, 99.8, 100.4, 97.9, 100.9, 99.3, 101.8, 98.8, 100.1,
            99.6, 102.3, 98.2, 100.7, 99.9, 101.5, 98.9, 100.3, 99.4, 100.8,
        ]
        let cleanStamps = (0..<cleanValues.count).map { now.addingTimeInterval(Double($0) * 60) }
        let cleanSeries = zip(cleanStamps, cleanValues).map { MetricSample(ts: $0, value: $1) }
        check(AnomalyEngine.anomalies(in: cleanSeries).isEmpty,
              "clean noisy series → []")
        let ramp = (0..<20).map { MetricSample(ts: now.addingTimeInterval(Double($0) * 60),
                                               value: Double(10 + $0)) }
        check(AnomalyEngine.anomalies(in: ramp).isEmpty, "steady ramp → []")

        // -- recent window query -----------------------------------------------
        // Fixture: 20 samples, spike at idx 2 (OLD) and idx 17 (RECENT).
        // lookback 5 covers the most recent 5 SAMPLES → indices ≥ 15,
        // so idx 17 qualifies and idx 2 does not.
        var twoSpikes = [Double](repeating: 100, count: 20)
        twoSpikes[2] = 300  // anomaly OUTSIDE the last 5 samples (idx < 15)
        twoSpikes[17] = 260 // anomaly INSIDE the last 5 samples (idx ≥ 15)
        let twoSpikeSeries = zip(spikeStamps, twoSpikes).map { MetricSample(ts: $0, value: $1) }
        // Both spikes are flagged over the full series…
        let allFlags = AnomalyEngine.anomalies(in: twoSpikeSeries)
        check(allFlags.map(\.index) == [2, 17], "double spike: both flagged")
        // …but only the one inside the most-recent-5-SAMPLES window counts
        // for the badge (documented semantics: cutoff = 20 − lookback = 15).
        let recent = AnomalyEngine.recentAnomalies(
            records: twoSpikeSeries.enumerated().map { i, s in
                record("turbo", "{\"mbps\": \(s.value)}", Double(twoSpikeSeries.count - i) * 60)
            },
            metric: .mbps, lookback: 5)
        check(recent.count == 1 && recent.first?.index == 17,
              "recentAnomalies: lookback 5 keeps only the recent (idx 17) spike")

        // -- confidence wording law ----------------------------------------------
        let described = (allFlags + spikeFlags).map { AnomalyEngine.describe($0, metric: .mbps) }
            + allFlags.map { AnomalyEngine.brief($0, metric: .mbps) }
        for text in described {
            let lowered = text.lowercased()
            check(!lowered.contains("broken"), "wording law: no 'broken'")
            check(!lowered.contains("problem"), "wording law: no 'problem'")
            check(lowered.contains("usual") || lowered.contains("typical"),
                  "wording law: framed against the user's typical readings")
        }

        // -- determinism ------------------------------------------------------------
        let again = AnomalyEngine.anomalies(in: twoSpikeSeries)
        check(again == allFlags, "determinism: identical input → identical output")

        return failures
    }
}
#endif
