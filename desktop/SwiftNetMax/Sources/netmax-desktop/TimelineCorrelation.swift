//
//  TimelineCorrelation.swift
//  netmax-desktop
//
//  W5-S2 (mission W5, X1 QoE timeline) — event↔sample correlation engine,
//  contract TC2.
//
//  Public surface:
//      TimelineRow                 — (TimelineModel.swift, S1; consumed here)
//      WifiEvent                   — (TimelineModel.swift, S1; consumed here)
//      CorrelatedEvent             — one event + its honest verdict:
//                                    { event, beforeMean?, afterMean?,
//                                      deltaText }
//      CorrelationMetric           — mbps · loss · jitter (which timeline
//                                    lane to correlate against)
//      TimelineCorrelation.correlationToleranceSeconds
//                                  — ±90 s match window (contract TC2,
//                                    deliberately a constant, not a setting)
//      TimelineCorrelation.maxSamplesPerSide
//                                  — ≤3 samples feed each side's mean
//      TimelineCorrelation.correlate(rows:events:metric:)
//                                  — [TimelineRow] + [WifiEvent] →
//                                    [CorrelatedEvent], one per event
//      TimelineCorrelation.deltaText(before:after:metric:thing:)
//                                  — the comparative sentence builder
//                                    (driven directly by D1's law battery;
//                                    thin/no-sample sentences live in
//                                    correlate)
//
//  CONTRACT THIS FILE IMPLEMENTS:
//    • TC2 — correlation tolerance = ±90 s default (constant here);
//      CONFIDENCE WORDING LAW applies: produced prose may say "suggests"
//      and "coincides", NEVER "caused"/"broke" (nor cause/causes/breakage/
//      because — the engine reports timing coincidences between readings,
//      never verdicts about equipment). Events with no sample inside the
//      window get nil means and a plain "no measurements nearby" text;
//      events that match but lack usable readings on both sides keep
//      whichever mean exists and say plainly that a comparison isn't
//      possible. Honest gaps, never speculation.
//
//  LAWS:
//    • HONEST GAPS — a row whose metric is nil for the selected lane is not
//      a sample (marker-only rows never masquerade as measurements); a
//      matched event without comparable readings on both sides declines to
//      compare while keeping what WAS found. Nothing is invented, nothing
//      is zero-filled, nothing found is discarded.
//    • DETERMINISM — no Date(), no randomness, no locale-dependent
//      formatting anywhere in the decision path. Identical inputs yield
//      byte-identical [CorrelatedEvent], forever.
//    • BOUNDARY RULE — the matched (boundary) sample — the lane sample
//      nearest the event, ties to the EARLIER one — belongs to NEITHER
//      mean. Before side = up to 3 lane samples strictly before it; after
//      side = up to 3 strictly after it. The event's own anchor reading
//      therefore cannot dilute or dominate either side of its comparison.
//
//  Wiring notes for sibling lanes:
//    • U2 (TimelineEventMarkers.swift) renders deltaText in the event
//      detail popover; the wording here is final — restyle, don't rewrite.
//    • D1 (TimelineTests.swift) drives correlate(rows:events:metric:) and
//      deltaText(before:after:metric:thing:) with offline fixtures;
//      TimelineCorrelationTests.runAll() below asserts the same cases
//      (match / no-match / boundary-tolerance / thin-match / lane gaps /
//      ordering) in self-check form, per the HistoryStoreTests /
//      AnomalyEngineTests convention.
//

import Foundation

// MARK: - Result model

/// One WiFi event plus what the timeline can honestly say around it.
///
/// Exactly the TC2 shape: identity, optional before/after means, and the
/// human sentence for the popover. `beforeMean`/`afterMean` are nil
/// whenever no usable sample existed on that side of the boundary; both
/// are nil when the event matched nothing (`deltaText` says so plainly).
struct CorrelatedEvent: Equatable {
    /// The event being correlated (identity + timestamp + kind).
    let event: WifiEvent
    /// Mean of up to `TimelineCorrelation.maxSamplesPerSide` lane samples
    /// STRICTLY BEFORE the matched boundary sample, or nil when none existed.
    let beforeMean: Double?
    /// Mean of up to `maxSamplesPerSide` lane samples STRICTLY AFTER the
    /// boundary sample (the boundary itself is excluded), or nil when none
    /// existed.
    let afterMean: Double?
    /// Popover-ready sentence obeying the CONFIDENCE WORDING LAW.
    let deltaText: String
}

/// Which timeline lane an event is correlated against. Mirrors the three
/// numeric lanes of `TimelineRow` (TC1) — deliberately a separate enum from
/// `AnomalyMetric`'s spelling so the correlation API reads standalone while
/// staying trivially convertible.
enum CorrelationMetric: String, CaseIterable {
    case mbps
    case loss
    case jitter

    /// The row field this lane reads (nil = honest gap, not a sample).
    func value(in row: TimelineRow) -> Double? {
        switch self {
        case .mbps: return row.mbps
        case .loss: return row.lossPct
        case .jitter: return row.jitterMs
        }
    }

    var unit: String {
        switch self {
        case .mbps: return "Mbps"
        case .loss: return "%"
        case .jitter: return "ms"
        }
    }

    /// Capitalized lane name used at the head of generated sentences.
    var label: String {
        switch self {
        case .mbps: return "Speed"
        case .loss: return "Packet loss"
        case .jitter: return "Jitter"
        }
    }
}

// MARK: - Engine

/// Correlates WiFi events against timeline samples (contract TC2).
///
/// Algorithm, per event:
/// 1. Find the sample of the chosen lane nearest in time (binary search;
///    ties resolve to the EARLIER sample).
/// 2. If it lies outside ±`correlationToleranceSeconds` → no-match result:
///    nil means, "no measurements nearby" text.
/// 3. Otherwise the matched sample becomes the BOUNDARY: before side =
///    up to 3 samples strictly before it (nearest first), after side =
///    up to 3 samples strictly after it (nearest first). Means are plain
///    arithmetic means; a side with zero samples stays nil.
/// 4. deltaText states the direction ("suggests a lower/higher reading")
///    or near-equality ("essentially unchanged") when both sides exist,
///    framed as coincidence within the tolerance window — never causation.
///    A match too thin to compare keeps the existing side's mean and says
///    so instead of comparing.
///
/// Pure function of its inputs; events come back oldest-first regardless
/// of input order.
enum TimelineCorrelation {

    /// Contract TC2: an event must sit within this many seconds of a sample
    /// for any correlation to be claimed. Constant on purpose — the honesty
    /// of the wording depends on this window meaning exactly one thing.
    static let correlationToleranceSeconds: TimeInterval = 90

    /// How many samples at most feed each side's mean (mission spec: ≤3).
    static let maxSamplesPerSide = 3

    /// Relative threshold under which before/after counts as "essentially
    /// unchanged" (5% of the larger magnitude).
    static let negligibleRelativeDelta = 0.05

    /// Absolute floor for the unchanged verdict (covers percent/ms-scale
    /// lanes where a 5% shift is still numerically noise).
    static let negligibleAbsoluteDelta = 0.1

    // MARK: Entry point

    /// Correlate every event against the timeline's rows, one result per
    /// event, oldest-first.
    ///
    /// Rows and events may arrive in ANY order — both are sorted here, so
    /// shuffled inputs cannot perturb results. Rows whose metric is nil for
    /// the selected lane (marker-only rows, honest gaps) simply aren't
    /// samples for this lane.
    static func correlate(rows: [TimelineRow],
                          events: [WifiEvent],
                          metric: CorrelationMetric = .mbps) -> [CorrelatedEvent] {
        var samples: [LaneSample] = []
        samples.reserveCapacity(rows.count)
        for row in rows {
            if let value = metric.value(in: row) {
                samples.append(LaneSample(ts: row.ts, value: value))
            }
        }
        samples.sort { $0.ts < $1.ts }
        return events
            .sorted { $0.ts < $1.ts }
            .map { correlate(event: $0, samples: samples, metric: metric) }
    }

    // MARK: Per-event correlation

    /// Correlate one event against an ASCENDING-by-ts sample series drawn
    /// from `metric`'s lane. Internal so the DEBUG self-checks can drive it
    /// directly.
    static func correlate(event: WifiEvent, samples: [LaneSample],
                          metric: CorrelationMetric = .mbps) -> CorrelatedEvent {
        guard let boundaryIndex = nearestIndex(to: event.ts, in: samples) else {
            return CorrelatedEvent(event: event, beforeMean: nil,
                                   afterMean: nil,
                                   deltaText: noSamplesText(for: event))
        }
        let boundary = samples[boundaryIndex]
        let distance = boundary.ts.timeIntervalSince(event.ts)
        guard abs(distance) <= correlationToleranceSeconds else {
            return CorrelatedEvent(event: event, beforeMean: nil,
                                   afterMean: nil,
                                   deltaText: noSamplesText(for: event))
        }

        // BEFORE: strictly earlier samples, nearest first (series is
        // ascending, so a reversed prefix-suffix gives the closest ≤3).
        let beforeValues = samples[..<boundaryIndex].suffix(maxSamplesPerSide)
            .reversed()
            .map(\.value)
        // AFTER: strictly later samples, nearest first. The boundary sample
        // itself is deliberately part of NEITHER side (see BOUNDARY RULE in
        // the file header).
        let afterValues = samples[(boundaryIndex + 1)...].prefix(maxSamplesPerSide)
            .map(\.value)

        let bMean = mean(of: beforeValues)
        let aMean = mean(of: afterValues)

        // Matched within tolerance: if both sides have readings, the
        // comparative sentence comes from deltaText (the single wording
        // surface). Otherwise — thin match — keep whichever side exists
        // (honest gaps: never discard what was found) and say plainly that
        // a comparison isn't possible, naming the matched anchor reading.
        guard let b = bMean, let a = aMean else {
            let seconds = String(Int(distance.rounded()))
            let side = distance <= 0 ? "before" : "after"
            return CorrelatedEvent(
                event: event, beforeMean: bMean, afterMean: aMean,
                deltaText: "Matched a measurement \(seconds) s \(side) this "
                    + "\(thingName(for: event)) (\(format(boundary.value)) \(metric.unit)), "
                    + "but there are not enough readings on both sides to compare.")
        }

        return CorrelatedEvent(
            event: event,
            beforeMean: bMean,
            afterMean: aMean,
            deltaText: deltaText(before: b, after: a,
                                 metric: metric, thing: thingName(for: event)))
    }

    /// Builds the comparative popover sentence for a computed pair of
    /// means. Called only when BOTH means exist (thin matches never reach
    /// here); the single wording surface D1's law battery drives directly.
    static func deltaText(before: Double, after: Double,
                          metric: CorrelationMetric, thing: String) -> String {
        let difference = after - before
        let unchanged = difference == 0
            || abs(difference) < max(negligibleAbsoluteDelta,
                                     negligibleRelativeDelta * max(abs(before), abs(after)))
        if unchanged {
            return "\(metric.label) essentially unchanged around this \(thing) "
                + "(\(format(before)) → \(format(after)) \(metric.unit); "
                + "coincides within ±\(toleranceText))."
        }
        let direction = difference > 0 ? "higher" : "lower"
        return "\(metric.label) suggests a \(direction) reading just after this \(thing) "
            + "(\(format(before)) → \(format(after)) \(metric.unit); "
            + "coincides within ±\(toleranceText))."
    }

    // MARK: Internals

    /// Ascending-series sample: the only shape the math touches.
    ///
    /// Internal (not private) so the DEBUG self-checks can build fixtures.
    struct LaneSample {
        let ts: Date
        let value: Double
    }

    /// Index of the sample nearest in time to `t`; ties resolve EARLIER
    /// (so an equidistant pair counts the before-side one as the boundary).
    /// Binary search over the ascending series; nil only when empty.
    static func nearestIndex(to t: Date, in samples: [LaneSample]) -> Int? {
        guard !samples.isEmpty else { return nil }
        var lo = 0
        var hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].ts < t { lo = mid + 1 } else { hi = mid }
        }
        // lo = first index with ts >= t (or count when t is past the end).
        if lo == samples.count { return samples.count - 1 }
        if lo == 0 { return 0 }
        let distanceToEarlier = t.timeIntervalSince(samples[lo - 1].ts)
        let distanceToLater = samples[lo].ts.timeIntervalSince(t)
        return distanceToEarlier <= distanceToLater ? lo - 1 : lo
    }

    private static func mean(of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Human name for the event ("roam", "RSSI drop", …) used mid-sentence;
    /// unknown wire kinds fall back to their raw string, verbatim.
    private static func thingName(for event: WifiEvent) -> String {
        let name = event.knownKind?.displayName ?? event.kind
        return name.lowercased()
    }

    /// "±90" — whole seconds; the constant is integral so the text is stable.
    private static var toleranceText: String {
        String(Int(correlationToleranceSeconds))
    }

    private static func noSamplesText(for event: WifiEvent) -> String {
        noSamplesText(thing: thingName(for: event))
    }

    private static func noSamplesText(thing: String) -> String {
        "No measurements nearby — nothing within ±\(toleranceText) s of this \(thing)."
    }

    /// Locale-independent number rendering, mirroring AnomalyEngine's style:
    /// integral values print bare, everything else one decimal.
    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

// MARK: - Offline self-checks
//
// Same convention as HistoryStoreTests / AnomalyEngineTests /
// TimelineModelTests / TimelineTests: Package.swift has no test target, so
// these compile into the DEBUG build as plain static checks (never executed
// at runtime) and convert 1:1 into XCTestCase methods. Required coverage per
// mission W5-S2: MATCH FOUND, NO-MATCH, and BOUNDARY-TOLERANCE cases — plus
// thin matches, ≤3 caps, per-lane gaps, ordering, determinism, and the
// CONFIDENCE WORDING LAW sweep over every produced sentence.

#if DEBUG
enum TimelineCorrelationTests {

    @discardableResult
    static func runAll(now: Date = Date(timeIntervalSinceReferenceDate: 950_000_000)) -> Int {
        var failures = 0
        var producedTexts: [String] = []
        func check(_ condition: Bool, _ name: String) {
            failures += condition ? 0 : 1
            if !condition { print("[TimelineCorrelationTests] FAIL: \(name)") }
        }
        /// Sample row `offset` seconds from `now` carrying explicit metrics.
        func row(_ offset: TimeInterval, mbps: Double? = nil,
                 loss: Double? = nil, jitter: Double? = nil) -> TimelineRow {
            TimelineRow(ts: now.addingTimeInterval(offset),
                        mbps: mbps, lossPct: loss, jitterMs: jitter, eventId: nil)
        }
        func event(_ kind: WifiEventKind, _ offset: TimeInterval,
                   id: String = "") -> WifiEvent {
            WifiEvent(ts: now.addingTimeInterval(offset),
                      kind: kind.rawValue,
                      id: id.isEmpty ? "e-\(kind.rawValue)-\(Int(offset))" : id)
        }
        @discardableResult
        func track(_ result: CorrelatedEvent) -> CorrelatedEvent {
            producedTexts.append(result.deltaText)
            return result
        }

        // -- MATCH FOUND: boundary 30 s before the event ----------------------
        // Minute-spaced samples; roam at t+150 sits between t+120 and t+180
        // → t+120 (100 Mbps) is the boundary and belongs to NEITHER mean.
        do {
            let rows = [
                row(60, mbps: 98), row(120, mbps: 100),
                row(180, mbps: 62), row(240, mbps: 58),
            ]
            let result = track(TimelineCorrelation.correlate(
                rows: rows, events: [event(.roam, 150)]).first!)
            check(result.beforeMean == 98,
                  "match: before = strictly-before samples (98), boundary excluded")
            check(result.afterMean == 60, "match: after mean = (62+58)/2")
            check(result.beforeMean != nil && result.afterMean != nil,
                  "match: both sides produced means")
            check(result.deltaText.contains("suggests") && result.deltaText.contains("lower"),
                  "match: falling means → \"suggests … lower\" wording")
        }

        // -- NO-MATCH: nearest sample 91+ s away → honest nils -----------------
        do {
            let rows = [row(0, mbps: 100), row(300, mbps: 100)]
            let result = track(TimelineCorrelation.correlate(
                rows: rows, events: [event(.channelChange, 191)]).first!) // 91 s from both
            check(result.beforeMean == nil && result.afterMean == nil,
                  "no-match: means stay nil outside the window")
            check(result.deltaText.lowercased().contains("no measurements nearby"),
                  "no-match: text admits no measurements nearby")
        }
        check(TimelineCorrelation.correlate(rows: [], events: [event(.roam, 0)])
            .first?.deltaText.lowercased().contains("no measurements nearby") == true,
              "no-match: empty timeline → no measurements nearby")

        // -- BOUNDARY TOLERANCE: exactly ±90 s matches, past that doesn't ------
        do {
            let rows = [row(0, mbps: 100)]
            let atPlus90 = track(TimelineCorrelation.correlate(
                rows: rows, events: [event(.roam, 90)]).first!)
            check(atPlus90.beforeMean == nil && atPlus90.afterMean == nil,
                  "tolerance: exact +90 s MATCH yields an honest result, not silence")
            check(!atPlus90.deltaText.lowercased().contains("no measurements"),
                  "tolerance: matched event never told \"no measurements nearby\"")
            check(atPlus90.deltaText.contains("Matched a measurement"),
                  "tolerance: thin-match text names the matched anchor reading")

            let atMinus90 = track(TimelineCorrelation.correlate(
                rows: rows, events: [event(.roam, -90)]).first!)
            check(atMinus90.beforeMean == nil && atMinus90.afterMean == nil,
                  "tolerance: exact −90 s match, boundary out of both means")
            check(atMinus90.deltaText.contains("Matched a measurement"),
                  "tolerance: −90 s thin match names its anchor too")

            let justOutside = track(TimelineCorrelation.correlate(
                rows: rows, events: [event(.roam, 91)]).first!)
            check(justOutside.beforeMean == nil && justOutside.afterMean == nil,
                  "tolerance: 91 s away does NOT match (strict window edge)")
            check(justOutside.deltaText.lowercased().contains("no measurements nearby"),
                  "tolerance: just-outside event gets the honest no-sample sentence")

            // Tie-break: equidistant neighbors resolve to the EARLIER sample.
            let tied = TimelineCorrelation.correlate(
                rows: [row(-10, mbps: 111), row(10, mbps: 222)],
                events: [event(.roam, 0)]).first!
            check(tied.beforeMean == nil,
                  "tie: equidistant pair → earlier sample is the boundary (empty before)")
        }

        // -- ≤3 CAP: five dense samples per side, means use nearest three ------
        // Boundary sits at t0 (200); five samples flank it on both sides.
        // Nearest three before: 101,102,103 → 102; nearest three after:
        // 49,48,47 → 48. The boundary's 200 must appear nowhere.
        do {
            let beforeRows = (1...5).map { row(Double(-10 * $0), mbps: Double(100 + $0)) } // −10…−50
            let afterRows = (1...5).map { row(Double(10 * $0), mbps: Double(50 - $0)) }    // +10…+50
            let rows = beforeRows + [row(0, mbps: 200)] + afterRows
            let result = track(TimelineCorrelation.correlate(
                rows: rows, events: [event(.rssiDrop, 5)]).first!)
            check(result.beforeMean == 102, "cap: before = NEAREST 3 (101+102+103)/3")
            check(result.afterMean == 48, "cap: after = NEAREST 3 (49+48+47)/3")
            check(result.deltaText.contains("suggests") && result.deltaText.contains("lower"),
                  "cap: 102 → 48 reads as \"suggests … lower\"")
        }

        // -- THIN MATCHES: single sample / one-sided timelines -------------------
        do {
            let beforeOnly = track(TimelineCorrelation.correlate(
                rows: [row(-30, mbps: 90), row(-60, mbps: 88)],
                events: [event(.roam, 0)]).first!)
            check(beforeOnly.beforeMean == 88 && beforeOnly.afterMean == nil,
                  "thin: before-only timeline leaves afterMean nil (boundary 90 excluded)")
            check(beforeOnly.deltaText.contains("Matched a measurement")
                  && beforeOnly.deltaText.contains("not enough"),
                  "thin: before-only text names the anchor and declines to compare")

            let afterOnly = track(TimelineCorrelation.correlate(
                rows: [row(30, mbps: 95), row(60, mbps: 93)],
                events: [event(.roam, 0)]).first!)
            check(afterOnly.beforeMean == nil && afterOnly.afterMean == 93,
                  "thin: after-only timeline leaves beforeMean nil (boundary 95 excluded)")
            check(afterOnly.deltaText.contains("Matched a measurement")
                  && afterOnly.deltaText.contains("not enough"),
                  "thin: after-only text names the anchor and declines to compare")

            let single = track(TimelineCorrelation.correlate(
                rows: [row(10, mbps: 50)], events: [event(.rssiDrop, 0)]).first!)
            check(single.beforeMean == nil && single.afterMean == nil,
                  "thin: lone matched sample → nil means (it is the boundary)")
            check(single.deltaText.contains("Matched a measurement"),
                  "thin: lone-match text still reports the anchor finding")
            check(!single.deltaText.lowercased().contains("no measurements"),
                  "thin: lone-match text never claims \"no measurements\"")
        }

        // -- UNCHANGED: near-equal sides get the neutral coincidence sentence ---
        do {
            let rows = [row(-60, mbps: 100), row(-30, mbps: 100),
                        row(30, mbps: 101)]
            let result = track(TimelineCorrelation.correlate(
                rows: rows, events: [event(.roam, 0)]).first!)
            check(result.beforeMean == 100 && result.afterMean == 101,
                  "unchanged: 100 → 101 within the noise floor")
            check(result.deltaText.contains("essentially unchanged"),
                  "unchanged: neutral wording for flat deltas")
            check(result.deltaText.contains("coincides"),
                  "unchanged: still framed as coincidence")
        }

        // -- LANES: marker-only rows are not samples; loss/jitter independent ----
        do {
            let markerRow = TimelineRow(ts: now.addingTimeInterval(-30), mbps: nil,
                                        lossPct: nil, jitterMs: nil, eventId: "m1")
            let lossRows = [
                TimelineRow(ts: now.addingTimeInterval(-60), mbps: nil,
                            lossPct: 2.0, jitterMs: nil, eventId: nil),
                markerRow,
                TimelineRow(ts: now.addingTimeInterval(30), mbps: nil,
                            lossPct: 4.5, jitterMs: nil, eventId: nil),
                TimelineRow(ts: now.addingTimeInterval(90), mbps: nil,
                            lossPct: 6.5, jitterMs: nil, eventId: nil),
            ]
            let mbpsLane = track(TimelineCorrelation.correlate(
                rows: lossRows, events: [event(.roam, 0)], metric: .mbps).first!)
            check(mbpsLane.beforeMean == nil && mbpsLane.afterMean == nil
                  && mbpsLane.deltaText.lowercased().contains("no measurements"),
                  "lanes: rows without the lane's metric are honest gaps (mbps empty here)")

            let lossLane = track(TimelineCorrelation.correlate(
                rows: lossRows, events: [event(.roam, 0)], metric: .loss).first!)
            check(lossLane.beforeMean == 2.0 && lossLane.afterMean == 6.5,
                  "lanes: loss lane correlates independently (boundary 4.5 excluded → after = 6.5)")
            check(lossLane.deltaText.contains("Packet loss")
                  && lossLane.deltaText.contains("%"),
                  "lanes: sentence names the lane and its unit")

            // Marker-only row alone: not a sample on ANY lane.
            let markerOnly = TimelineCorrelation.correlate(
                rows: [markerRow], events: [event(.channelChange, 0)],
                metric: .jitter).first!
            check(markerOnly.beforeMean == nil && markerOnly.afterMean == nil,
                  "lanes: marker-only row never masquerades as a measurement")
        }

        // -- ORDER-INDEPENDENCE: shuffled inputs, stable output ------------------
        do {
            let orderedRows = [row(60, mbps: 100), row(120, mbps: 90)]
            let shuffledRows = [orderedRows[1], orderedRows[0]]
            let events = [event(.roam, 90, id: "a"), event(.rssiDrop, 240, id: "b")]
            let shuffledEvents = Array(events.reversed())
            let fromOrdered = TimelineCorrelation.correlate(rows: orderedRows, events: events)
            let fromShuffled = TimelineCorrelation.correlate(rows: shuffledRows, events: shuffledEvents)
            check(fromShuffled == fromOrdered,
                  "order: shuffled inputs give identical, oldest-first results")
            track(fromOrdered[0]); track(fromOrdered[1])
            check(fromOrdered.map(\.event.id) == ["a", "b"],
                  "order: results are oldest-first regardless of input order")
        }

        // -- DETERMINISM ----------------------------------------------------------
        do {
            let rows = [row(0, mbps: 100), row(60, mbps: 96), row(140, mbps: 61)]
            let events = [event(.roam, 130)]
            let first = TimelineCorrelation.correlate(rows: rows, events: events)
            let second = TimelineCorrelation.correlate(rows: rows, events: events)
            check(first == second, "determinism: identical input → identical output")
            check(first.count == 1, "determinism: one result per event")
        }

        // -- CONFIDENCE WORDING LAW ------------------------------------------------
        // Every sentence this engine produced above is swept: causal verbs
        // are banned outright; directional comparisons carry "suggests" AND
        // "coincides"; flat comparisons carry "coincides"; thin/no-sample
        // sentences own their ignorance instead of implying causation.
        check(!producedTexts.isEmpty, "wording: self-checks above produced text to audit")
        for text in producedTexts {
            let lowered = text.lowercased()
            check(!lowered.contains("caus"), "wording law: no caused/causes/cause (\(text))")
            check(!lowered.contains("broke"), "wording law: no broke/broken (\(text))")
            check(!lowered.contains("breakage"), "wording law: no breakage (\(text))")
            check(!lowered.contains("because"), "wording law: no because (\(text))")
        }
        let directional = producedTexts.filter { $0.contains("suggests") }
        let flats = producedTexts.filter { $0.contains("essentially unchanged") }
        check(!directional.isEmpty, "wording: directional fixtures exercised \"suggests\"")
        check(!flats.isEmpty, "wording: flat fixtures exercised \"essentially unchanged\"")
        for text in directional + flats {
            check(text.contains("coincides"),
                  "wording law: comparisons say \"coincides\" (\(text))")
        }
        for text in producedTexts where text.contains("not enough")
            || text.lowercased().contains("no measurements") {
            let lowered = text.lowercased()
            check(lowered.contains("not enough") || lowered.contains("no measurements"),
                  "wording law: thin sentences admit the gap explicitly")
        }
        // Direct drive of the comparative deltaText surface × every metric
        // (mirrors D1's public-surface sweep).
        for metric in CorrelationMetric.allCases {
            let up = TimelineCorrelation.deltaText(before: 100, after: 140,
                                                   metric: metric, thing: "roam")
            check(up.contains("suggests") && up.contains("higher") && up.contains("coincides"),
                  "wording[\(metric.rawValue)]: up-comparison phrased per law")
            producedTexts.append(up)
            let down = TimelineCorrelation.deltaText(before: 140, after: 100,
                                                     metric: metric, thing: "roam")
            check(down.contains("suggests") && down.contains("lower") && down.contains("coincides"),
                  "wording[\(metric.rawValue)]: down-comparison phrased per law")
            producedTexts.append(down)
        }

        return failures
    }
}
#endif
