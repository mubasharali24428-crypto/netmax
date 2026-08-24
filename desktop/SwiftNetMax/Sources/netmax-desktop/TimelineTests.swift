//
//  TimelineTests.swift
//  netmax-desktop
//
//  W5-D1 (mission W5, X1 QoE timeline) — offline unit-test battery for the
//  timeline data model (S1, TimelineModel.swift) and correlation engine
//  (S2, TimelineCorrelation.swift).
//
//  Same convention as HistoryStoreTests / AnomalyEngineTests: Package.swift
//  has no test target, so these compile into the DEBUG build as plain static
//  checks (never executed at runtime) and convert 1:1 into XCTestCase
//  methods. Real offline verification runs via a standalone /tmp harness:
//
//    swiftc -DDEBUG Sources/netmax-desktop/{HistoryStore,AnomalyEngine,
//      TimelineModel,TimelineCorrelation,TimelineTests}.swift main.swift
//      -o /tmp/w5d1_harness && /tmp/w5d1_harness
//
//  WHAT THIS BATTERY COVERS (independent of the lanes' own self-checks —
//  driven through the PUBLIC API only, fixtures built from the contracts):
//    1. Merge ordering (TC1): shuffled samples+events come out strictly
//       ts-sorted; exact-ts coincidence merges the marker onto the sample;
//       extra same-ts events become honest marker-only rows; deterministic.
//    2. Corrupt wifi_events.jsonl lines are skipped silently (TC3): junk,
//       torn trailing writes, wrong-typed fields, blanks — survivors load
//       oldest-first; a missing file behaves as empty.
//    3. Correlation tolerance boundary (TC2): a sample exactly ±90 s away
//       MATCHES, 89 s matches, 91 s does not (strict window edge).
//    4. CONFIDENCE WORDING LAW: every user-facing string the timeline
//       surface can produce (all deltaText branches × all metrics × known
//       + unknown event kinds, lane labels, kind display names) is swept —
//       causal verbs are banned; comparative sentences say "suggests" and
//       "coincides".
//    5. Quiet inputs: empty records/events, unreadable payloads, and
//       missing files produce empty/honest results — never zeros, never
//       invented rows, never a crash.
//

import Foundation

#if DEBUG
enum TimelineTests {

    /// Run the whole battery; returns number of failures (0 == pass).
    @discardableResult
    static func runAll(now: Date = Date(timeIntervalSinceReferenceDate: 1_000_000_000)) -> Int {
        var failures = 0
        failures += mergeOrderingChecks(now: now)
        failures += toleranceBoundaryChecks(now: now)
        failures += wordingLawChecks(now: now)
        failures += emptyInputChecks(now: now)
        failures += corruptEventFileChecks(now: now)
        if failures > 0 {
            print("[TimelineTests] FAILURES TOTAL: \(failures)")
        }
        return failures
    }

    // MARK: - 1. Merge ordering correctness (contract TC1)

    private static func mergeOrderingChecks(now: Date) -> Int {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            failures += condition ? 0 : 1
            if !condition { print("[TimelineTests] FAIL: \(name)") }
        }
        func record(_ raw: String, _ offset: TimeInterval) -> HistoryRecord {
            HistoryRecord(ts: now.addingTimeInterval(offset),
                          mode: "baseline", params: [:], resultRaw: raw)
        }
        func event(_ kind: WifiEventKind, _ offset: TimeInterval, id: String) -> WifiEvent {
            WifiEvent(ts: now.addingTimeInterval(offset), kind: kind.rawValue, id: id)
        }

        // Shuffled inputs (samples out of order, events out of order, both
        // interleaved on the time axis) MUST emerge strictly ts-sorted.
        let shuffledRecords = [
            record(#"{"mbps": 300}"#, 300),
            record(#"{"mbps": 100}"#, 100),
            record("packet loss: 0.4%", 500),
            record(#"{"mbps": 700}"#, 700),
        ]
        let shuffledEvents = [
            event(.channelChange, 600, id: "ch-600"),
            event(.roam, 200, id: "roam-200"),
            event(.rssiDrop, 400, id: "drop-400"),
        ]
        let merged = TimelineModel.build(records: shuffledRecords, events: shuffledEvents)
        check(merged.map { $0.ts.timeIntervalSince(now) } == [100, 200, 300, 400, 500, 600, 700],
              "merge: interleaved samples+events emerge strictly ts-sorted")
        check(merged.count == 7, "merge: every readable input contributes exactly one row")
        check(merged.compactMap(\.eventId) == ["roam-200", "drop-400", "ch-600"],
              "merge: eventIds land in ts order regardless of input order")

        // Exact-ts coincidence: the marker rides the sample's row (TC1).
        let coincident = TimelineModel.build(
            records: [record(#"{"mbps": 120}"#, 90)],
            events: [event(.roam, 90, id: "ride-along")])
        check(coincident.count == 1
              && coincident[0].mbps == 120
              && coincident[0].eventId == "ride-along",
              "merge: event at a sample's exact ts merges INTO that row")

        // Two events at one ts: the first rides the sample, the second gets
        // its own marker-only row whose metrics stay nil (honest gaps).
        let crowded = TimelineModel.build(
            records: [record(#"{"mbps": 80}"#, 0)],
            events: [event(.rssiDrop, 0, id: "e1"), event(.roam, 0, id: "e2")])
        check(crowded.count == 2, "merge: second same-ts event gets its own row")
        check(crowded[0].eventId == "e1" && crowded[0].mbps == 80,
              "merge: first same-ts event rides the sample row")
        check(crowded[1].eventId == "e2" && crowded[1].mbps == nil
              && crowded[1].lossPct == nil && crowded[1].jitterMs == nil,
              "merge: extra event row is marker-only (metrics honestly nil)")

        // Honest gaps: a loss-prose payload parses loss only — absent
        // metrics stay nil, never zero-filled.
        let lossOnly = TimelineModel.build(records: [record("packet loss: 0.4%", 0)], events: [])
        check(lossOnly.count == 1 && lossOnly[0].lossPct == 0.4
              && lossOnly[0].mbps == nil && lossOnly[0].jitterMs == nil,
              "merge: loss-only payload keeps mbps/jitter nil (honest, not 0)")

        // Determinism: byte-identical output for identical inputs.
        check(TimelineModel.build(records: shuffledRecords, events: shuffledEvents) == merged,
              "merge: identical inputs rebuild identical rows")

        return failures
    }

    // MARK: - 3. Correlation tolerance boundary (contract TC2)

    /// Fixture: sparse samples at −400 / 0 / +400 carrying distinct values,
    /// so the NEAREST sample to any probe is unambiguous.
    private static func boundaryRows(now: Date) -> [TimelineRow] {
        [TimelineRow(ts: now.addingTimeInterval(-400), mbps: 50, lossPct: nil,
                     jitterMs: nil, eventId: nil),
         TimelineRow(ts: now, mbps: 100, lossPct: nil, jitterMs: nil, eventId: nil),
         TimelineRow(ts: now.addingTimeInterval(400), mbps: 150, lossPct: nil,
                     jitterMs: nil, eventId: nil)]
    }
    private static func roamEvent(at offset: TimeInterval, now: Date, id: String) -> WifiEvent {
        WifiEvent(ts: now.addingTimeInterval(offset), kind: WifiEventKind.roam.rawValue, id: id)
    }

    private static func toleranceBoundaryChecks(now: Date) -> Int {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            failures += condition ? 0 : 1
            if !condition { print("[TimelineTests] FAIL: \(name)") }
        }
        check(TimelineCorrelation.correlationToleranceSeconds == 90,
              "tolerance: contract TC2 constant is ±90 s")

        let rows = boundaryRows(now: now)

        // 89 s away → MATCHES (inside the window): means exist around the
        // boundary sample at t0, and the boundary itself never dilutes its
        // own AFTER side (afterMean reads the strictly-later 150 sample,
        // not ~(100+150)/2).
        let at89 = TimelineCorrelation.correlate(
            rows: rows, events: [roamEvent(at: 89, now: now, id: "in-89")]).first!
        check(at89.beforeMean != nil && at89.afterMean == 150,
              "tolerance: 89 s correlates; boundary sample stays out of AFTER")
        check(at89.deltaText.contains("suggests"),
              "tolerance: in-window verdict speaks comparatively")

        // Exactly +90 s → still MATCHES (window is inclusive).
        let atPlus90 = TimelineCorrelation.correlate(
            rows: rows, events: [roamEvent(at: 90, now: now, id: "edge-p90")]).first!
        check(atPlus90.beforeMean != nil && atPlus90.afterMean == 150,
              "tolerance: exactly +90 s matches (inclusive edge)")

        // Exactly −90 s → MATCHES too (symmetric edge).
        let atMinus90 = TimelineCorrelation.correlate(
            rows: rows, events: [roamEvent(at: -90, now: now, id: "edge-m90")]).first!
        check(atMinus90.beforeMean != nil && atMinus90.afterMean != nil,
              "tolerance: exactly −90 s matches (inclusive edge)")

        // Shipped law (reconciled by S2 mid-flight): the boundary sample —
        // here the t0 reading of 100 — belongs to NEITHER mean, so an
        // event's anchor reading can never dominate its own comparison.
        // beforeMean reads the strictly-earlier 50, never 100.
        check(at89.beforeMean == 50 && atPlus90.beforeMean == 50,
              "boundary membership: boundary sample belongs to NEITHER mean")

        // 91 s away → does NOT match: strict window edge means nil means
        // and the honest no-measurements sentence (the next sample is 309 s
        // further out, so NOTHING qualifies).
        let at91 = TimelineCorrelation.correlate(
            rows: rows, events: [roamEvent(at: 91, now: now, id: "out-91")]).first!
        check(at91.beforeMean == nil && at91.afterMean == nil,
              "tolerance: 91 s does NOT correlate (strict window edge)")
        check(at91.deltaText.lowercased().contains("no measurements nearby"),
              "tolerance: outside-window event admits no measurements nearby")

        return failures
    }

    // MARK: - 4. Confidence wording law

    private static func wordingLawChecks(now: Date) -> Int {
        var failures = 0
        var produced: [(text: String, comparative: Bool)] = []
        func check(_ condition: Bool, _ name: String) {
            failures += condition ? 0 : 1
            if !condition { print("[TimelineTests] FAIL: \(name)") }
        }
        // Banned anywhere in user-facing copy (TC2): causal verbs. "caus"
        // also catches "because"/"causes".
        let banned = ["caus", "broke", "breakage"]

        func sweep(_ text: String, comparative: Bool, context: String) {
            produced.append((text, comparative))
            let lowered = text.lowercased()
            for word in banned {
                check(!lowered.contains(word),
                      "wording[\(context)]: no \"\(word)\" in \"\(text)\"")
            }
            if comparative {
                check(text.contains("suggests") && text.contains("coincides"),
                      "wording[\(context)]: comparison says \"suggests\"+\"coincides\"")
            }
        }

        // Comparative branch × every metric × known + unknown event kinds,
        // driven through the public deltaText(before:after:metric:thing:)
        // surface (post-reconciliation this API covers the comparative
        // sentence only; one-sided/thin sentences are exercised end-to-end
        // through correlate() below).
        let things = WifiEventKind.allCases.map { $0.displayName.lowercased() } + ["mystery_kind"]
        for metric in CorrelationMetric.allCases {
            for thing in things {
                sweep(TimelineCorrelation.deltaText(before: 100, after: 140,
                                                    metric: metric, thing: thing),
                      comparative: true, context: "\(metric.rawValue)/up/\(thing)")
                sweep(TimelineCorrelation.deltaText(before: 140, after: 100,
                                                    metric: metric, thing: thing),
                      comparative: true, context: "\(metric.rawValue)/down/\(thing)")
                sweep(TimelineCorrelation.deltaText(before: 100, after: 101,
                                                    metric: metric, thing: thing),
                      comparative: false, context: "\(metric.rawValue)/flat/\(thing)")
            }
        }

        // Sentences produced END-TO-END by correlate(): matched-comparative,
        // thin-match (one side only), matched-but-nothing-comparable, and
        // no-sample — across all three metrics and known + unknown kinds.
        for metric in CorrelationMetric.allCases {
            // Lane fixture mirroring boundaryRows' shape on THIS lane.
            func laneRow(_ off: Double, _ v: Double?) -> TimelineRow {
                TimelineRow(ts: now.addingTimeInterval(off),
                            mbps: metric == .mbps ? v : nil,
                            lossPct: metric == .loss ? v : nil,
                            jitterMs: metric == .jitter ? v : nil,
                            eventId: nil)
            }
            let laneRows = [laneRow(-400, 50), laneRow(0, 100), laneRow(400, 150)]

            for (i, kind) in WifiEventKind.allCases.enumerated() {
                let result = TimelineCorrelation.correlate(
                    rows: laneRows,
                    events: [WifiEvent(ts: now.addingTimeInterval(60),
                                       kind: kind.rawValue, id: "k\(i)")],
                    metric: metric).first!
                sweep(result.deltaText, comparative: true,
                      context: "correlate/\(metric.rawValue)/\(kind.rawValue)")
            }

            // THIN MATCH, one side only: two samples just after the event →
            // afterMean exists, beforeMean stays honestly nil.
            let thin = TimelineCorrelation.correlate(
                rows: [laneRow(40, 90), laneRow(80, 96)],
                events: [WifiEvent(ts: now, kind: "roam", id: "thin")],
                metric: metric).first!
            check(thin.beforeMean == nil && thin.afterMean != nil,
                  "thin[\(metric.rawValue)]: one-sided window keeps the honest gap")
            check(thin.deltaText.contains("Matched a measurement")
                  && thin.deltaText.contains("not enough"),
                  "thin[\(metric.rawValue)]: thin-match text admits it cannot compare")
            sweep(thin.deltaText, comparative: false,
                  context: "correlate/\(metric.rawValue)/thin")

            // MATCHED but nothing comparable on EITHER side (boundary is the
            // only sample): still no invention — nils plus the plain sentence.
            let bare = TimelineCorrelation.correlate(
                rows: [laneRow(60, 120)],
                events: [WifiEvent(ts: now.addingTimeInterval(30), kind: "roam", id: "bare")],
                metric: metric).first!
            check(bare.beforeMean == nil && bare.afterMean == nil
                  && bare.deltaText.contains("Matched a measurement"),
                  "bare[\(metric.rawValue)]: matched-but-empty stays nil, says so")
            sweep(bare.deltaText, comparative: false,
                  context: "correlate/\(metric.rawValue)/bare")

            // NO samples anywhere near.
            let none = TimelineCorrelation.correlate(
                rows: laneRows,
                events: [WifiEvent(ts: now.addingTimeInterval(2000),
                                   kind: "mystery_kind", id: "far")],
                metric: metric).first!
            sweep(none.deltaText, comparative: false,
                  context: "correlate/\(metric.rawValue)/none")
        }

        // Static labels shown beside markers must obey the law too.
        for kind in WifiEventKind.allCases {
            sweep(kind.displayName, comparative: false, context: "displayName")
            sweep(kind.rawValue, comparative: false, context: "rawKind")
        }
        for metric in CorrelationMetric.allCases {
            sweep(metric.label, comparative: false, context: "laneLabel")
            sweep(metric.unit, comparative: false, context: "laneUnit")
        }

        check(produced.count >= 3 * 3 * 4 + 3 * 5 + 8,
              "wording: swept a meaningful body of copy (\(produced.count) strings)")
        return failures
    }

    // MARK: - 5. Quiet behavior on empty/degenerate inputs

    private static func emptyInputChecks(now: Date) -> Int {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            failures += condition ? 0 : 1
            if !condition { print("[TimelineTests] FAIL: \(name)") }
        }

        // Nothing in, nothing out.
        check(TimelineModel.build(records: [], events: []).isEmpty,
              "quiet: empty records + events → empty timeline")

        // Unreadable payloads contribute NO rows (never zero-filled).
        let garbage = TimelineModel.build(
            records: [HistoryRecord(ts: now, mode: "baseline", params: [:],
                                    resultRaw: "not a payload at all")],
            events: [])
        check(garbage.isEmpty, "quiet: unreadable payload → no row at all")

        // Correlating against an empty timeline stays calm: one honest
        // verdict per event, nil means, plain admission text.
        let lone = TimelineCorrelation.correlate(
            rows: [],
            events: [WifiEvent(ts: now, kind: WifiEventKind.roam.rawValue, id: "lonely")])
        check(lone.count == 1 && lone[0].beforeMean == nil && lone[0].afterMean == nil,
              "quiet: event vs empty timeline → one honest nil-nil verdict")
        check(lone[0].deltaText.lowercased().contains("no measurements nearby"),
              "quiet: empty-timeline verdict owns its ignorance")

        // Events without rows and rows without events are both quiet.
        let noEvents = TimelineCorrelation.correlate(
            rows: boundaryRows(now: now), events: [])
        check(noEvents.isEmpty, "quiet: zero events → zero verdicts")

        return failures
    }

    // MARK: - 2. Corrupt wifi_events.jsonl handling (contract TC3)

    private static func corruptEventFileChecks(now: Date) -> Int {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            failures += condition ? 0 : 1
            if !condition { print("[TimelineTests] FAIL: \(name)") }
        }

        let eventsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("netmax-w5d1-events-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: eventsURL) }

        // Good lines mixed with every corruption mode the writer can emit:
        // pure junk, a torn trailing write (crash mid-append), a JSON object
        // whose ts field is garbage, and a blank line.
        let lines = [
            #"{"ts":"2026-08-24T09:00:00Z","kind":"roam","id":"good-iso"}"#,
            "not json at all {{{",
            #"{"ts":"2026-08-24T09:00:30.750Z","kind":"channel_change"}"#,
            #"{"ts":"2026-08-24T09:01:00Z","kind":"rssi_dr"#,
            #"{"ts":"yesterday","kind":"roam"}"#,
            #"{"ts": 1779000000, "kind": "mystery_kind"}"#,
            "",
        ]
        do {
            try lines.joined(separator: "\n").write(to: eventsURL, atomically: true,
                                                    encoding: .utf8)
        } catch {
            print("[TimelineTests] FAIL: fixture write error \(error)")
            return 1
        }

        let loaded = WifiEventsReader(fileURL: eventsURL).loadAll()
        check(loaded.count == 3,
              "events: corrupt lines skipped silently — 3 of 6 survive (got \(loaded.count))")
        guard loaded.count == 3 else { return failures }
        check(loaded.map(\.ts) == loaded.map(\.ts).sorted(),
              "events: survivors load oldest-first regardless of file order")

        let byId = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        check(byId["good-iso"]?.kind == "roam",
              "events: wire id preserved on the good ISO8601 line")
        // Synthetic ids number in TS order: the epoch line (May 2026) sorts
        // BEFORE the August ISO lines, so it takes ev-1, the fractional
        // August line ev-2.
        check(byId["ev-1"]?.knownKind == nil && byId["ev-1"]?.kind == "mystery_kind"
              && byId["ev-1"]?.ts == Date(timeIntervalSince1970: 1_779_000_000),
              "events: epoch-ts line survives as ev-1; unknown kind kept verbatim")
        check(byId["ev-2"]?.kind == "channel_change"
              && byId["ev-2"]?.ts == WifiEvent.date(fromString: "2026-08-24T09:00:30.750Z"),
              "events: fractional-ISO line survives with synthesized id")

        // Missing file behaves as empty — never throws, never invents.
        let missing = WifiEventsReader(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("netmax-w5d1-missing-\(UUID().uuidString).jsonl"))
        check(missing.loadAll().isEmpty, "events: missing file reads as empty")

        // End-to-end: corrupt event file + real history file through the
        // injectable-URL disk convenience.
        let histURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("netmax-w5d1-history-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: histURL) }
        let historyLines = [
            #"{"ts":"2026-08-24T09:00:05Z","mode":"baseline","params":{},"result_raw":"{\"mbps\": 940.5}"}"#,
            "{\"ts\":\"2026-08-24T09:02:00Z\",\"mode\":\"turbo\",\"params\":{},\"result_raw\":\"packet loss: 1.5%\"}",
        ]
        do {
            try historyLines.joined(separator: "\n").write(to: histURL, atomically: true,
                                                           encoding: .utf8)
        } catch {
            print("[TimelineTests] FAIL: history fixture write error \(error)")
            return failures + 1
        }
        let diskRows = TimelineModel.build(historyFileURL: histURL, eventsFileURL: eventsURL)
        check(diskRows.count == 5,
              "disk: 2 samples + 3 surviving events → 5 rows (got \(diskRows.count))")
        check(diskRows.map(\.ts) == diskRows.map(\.ts).sorted(),
              "disk: end-to-end timeline comes out ts-sorted")
        let sampleTs = WifiEvent.date(fromString: "2026-08-24T09:00:05Z")
        let sampleRow = diskRows.first { $0.ts == sampleTs }
        check(sampleRow?.mbps == 940.5 && sampleRow?.eventId == nil,
              "disk: sample row carries its parsed mbps, untouched by events")

        return failures
    }
}
#endif
