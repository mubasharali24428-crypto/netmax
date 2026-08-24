//
//  TimelineModel.swift
//  netmax-desktop
//
//  W5-S1 (mission W5, X1 QoE timeline) — timeline data model, contract TC1.
//
//  Public surface:
//      TimelineRow              — one unified timeline point (contract TC1):
//                                 { ts, mbps?, lossPct?, jitterMs?, eventId? }
//      WifiEvent                — one WiFi event decoded from wifi_events.jsonl
//      WifiEventKind            — roam / rssi_drop / channel_change (wire names)
//      WifiEventsReader         — tolerant JSONL reader for the event store
//      TimelineModel.build(records:events:)
//                               — samples + events -> ts-sorted [TimelineRow]
//      TimelineModel.build(historyFileURL:eventsFileURL:)
//                               — disk convenience with injectable URLs (tests)
//
//  CONTRACTS THIS FILE IMPLEMENTS:
//    - TC1 — TimelineRow = {ts, mbps?, lossPct?, jitterMs?, eventId?}; merge
//      is by ts sort; missing metrics = nil (HONEST GAPS: a metric the
//      payload did not carry is nil, never zero-filled).
//    - TC3 — the event store lives at
//      ~/Library/Application Support/NetMaxDesktop/wifi_events.jsonl (E2's
//      Python writer owns the wire format; this reader is deliberately
//      tolerant: corrupt/partial lines are skipped silently; timestamps are
//      accepted as ISO8601 — with or without fractional seconds — or as
//      numeric epoch seconds).
//
//  LAWS:
//    - HONEST GAPS — rows carry exactly what their source carried. An
//      unreadable payload contributes NO row (matching AnomalyEngine /
//      DashboardMetrics "skip silently, never zero-fill"); a readable payload
//      that lacks jitter leaves jitterMs nil. Nothing is invented.
//    - PARSER UNITY — metric extraction reuses AnomalyEngine.metricValue (the
//      internal parser that follows DashboardCardsView's MetricExtractor
//      patterns) so a dashboard card, the trend sparkline, and this timeline
//      can never disagree about the same result_raw.
//    - DETERMINISM — no Date(), no randomness, no locale-dependent
//      formatting anywhere in the decision path. Identical inputs produce
//      identical row arrays, forever.
//
//  Wiring notes for sibling lanes:
//    - S2 (TimelineCorrelation.swift) consumes TimelineRow.eventId + ts.
//    - U1/U2 (timeline views/markers) consume the sorted rows; an event whose
//      ts coincides exactly with a sample merges INTO that sample's row (the
//      marker rides the sample); further same-ts events become their own
//      marker-only rows (metrics nil — honest).
//    - D1 (TimelineTests.swift) drives TimelineModel.build(records:events:)
//      and the injectable-URL loaders with offline fixtures;
//      TimelineModelTests.runAll() below carries the same assertions in
//      self-check form.
//

import Foundation

// MARK: - Row model (contract TC1)

/// One unified timeline point: either a measurement sample, a WiFi event
/// marker, or both when their timestamps coincide (contract TC1).
///
/// All metric fields are optional ON PURPOSE: the timeline shows gaps as
/// gaps. A row with `eventId == nil` came from history alone; a row with
/// `eventId != nil` carries (at least) a WiFi event; a row carrying both is
/// an event coincident with a sample.
struct TimelineRow: Equatable {
    /// Sample/event timestamp (ISO8601 on the wire, per contract P2/TC3).
    let ts: Date
    /// Throughput in Mbps, when the payload carried a recognizable figure.
    let mbps: Double?
    /// Packet-loss percentage (clamped to 0...100 by the shared parser).
    let lossPct: Double?
    /// Jitter in milliseconds, when present.
    let jitterMs: Double?
    /// Identity of the WiFi event attached to this row, when one is present.
    /// Wire `"id"` when the event store provided one, otherwise a load-order
    /// synthetic id ("ev-N"; see `WifiEventsReader`).
    let eventId: String?
}

// MARK: - WiFi events

/// Wire-level event kinds the X1 capture pipeline emits today (mission W5,
/// squad 1). Raw wire spellings live in `rawValue`; unknown kinds coming off
/// disk are preserved verbatim by `WifiEvent.kind` and simply read as
/// `knownKind == nil` — never dropped, never guessed into a wrong bucket.
enum WifiEventKind: String, CaseIterable {
    case roam
    case rssiDrop = "rssi_drop"
    case channelChange = "channel_change"

    /// Short human label for markers/tooltips (UI lanes may re-style).
    var displayName: String {
        switch self {
        case .roam: return "Roam"
        case .rssiDrop: return "RSSI drop"
        case .channelChange: return "Channel change"
        }
    }
}

/// One WiFi event decoded from `wifi_events.jsonl`.
///
/// Expected line shape (written by squad 1's Python store):
///     {"ts": "2026-08-24T09:41:03Z", "kind": "roam",
///      "id": "e-17", "details": {...}}
/// `ts` may instead be numeric epoch seconds; `id` is optional and extra
/// keys (e.g. `details`) are ignored. Anything unparseable makes the LINE
/// skipped, never the app sad.
struct WifiEvent: Equatable {
    /// Event timestamp (parsed from ISO8601 or epoch seconds).
    let ts: Date
    /// Raw `kind` string exactly as written on the wire.
    let kind: String
    /// Wire `"id"` when present; otherwise a synthetic "ev-N" assigned in
    /// file order by the reader. Always non-empty after loading.
    var id: String

    /// Typed kind; nil when the wire carried a kind this build doesn't know.
    var knownKind: WifiEventKind? { WifiEventKind(rawValue: kind) }
}

extension WifiEvent: Decodable {
    enum CodingKeys: String, CodingKey {
        case ts, kind, id
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // Timestamps: ISO8601 string (fractional seconds optional) or epoch.
        if let text = try? c.decode(String.self, forKey: .ts) {
            guard let date = Self.date(fromString: text) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .ts, in: c,
                    debugDescription: "unparseable timestamp string \(text)")
            }
            ts = date
        } else if let epoch = try? c.decode(Double.self, forKey: .ts) {
            ts = Date(timeIntervalSince1970: epoch)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .ts, in: c,
                debugDescription: "missing or non-timestamp 'ts'")
        }

        kind = try c.decode(String.self, forKey: .kind)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
    }

    /// ISO8601 with or without fractional seconds ("...T09:41:03Z" and
    /// "...T09:41:03.512Z" both parse); nil when neither form fits.
    static func date(fromString text: String) -> Date? {
        if let d = fractionalSecondsFormatter.date(from: text) { return d }
        return wholeSecondsFormatter.date(from: text)
    }

    private static let wholeSecondsFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let fractionalSecondsFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// Read-only, tolerant reader for the WiFi event store (contract TC3).
///
/// Mirrors `HistoryStore`'s conventions — same directory family, JSON Lines,
/// corrupt lines skipped silently, missing file reads as empty — minus the
/// lock: this reader performs no writes, and a torn trailing line (writer
/// mid-append) is handled by the same skip-silently tolerance.
final class WifiEventsReader {

    /// Process-wide reader pointed at the standard Application Support path.
    static let shared = WifiEventsReader()

    /// Contract TC3 location:
    /// ~/Library/Application Support/NetMaxDesktop/wifi_events.jsonl
    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("NetMaxDesktop", isDirectory: true)
            .appendingPathComponent("wifi_events.jsonl")
    }

    private let fileURL: URL

    /// - Parameter fileURL: overrides the store path (tests / self-checks);
    ///   production callers use `shared` (or the default initializer).
    init(fileURL: URL = WifiEventsReader.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// Load every readable event, OLDEST-FIRST (ts-sorted regardless of
    /// file order; equal timestamps keep file order).
    ///
    /// Missing file -> []. Corrupt/partial lines are skipped silently, so a
    /// truncated last line (crash mid-append) costs nothing.
    func loadAll() -> [WifiEvent] {
        Self.readEvents(from: fileURL)
    }

    /// Line-by-line tolerant decode, ts-sorted on the way out. Internal so
    /// the DEBUG self-checks can exercise it against arbitrary fixtures.
    static func readEvents(from url: URL) -> [WifiEvent] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        struct LoadedLine {
            var event: WifiEvent
            let fileOrder: Int
        }
        var decoded: [LoadedLine] = []
        var lineNo = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            lineNo += 1
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let event = try? decoder.decode(WifiEvent.self, from: data)
            else { continue } // corrupt line: skip silently (TC3 tolerance)
            decoded.append(LoadedLine(event: event, fileOrder: lineNo))
        }
        // Oldest-first, independent of how orderly the writer has been;
        // ties keep file order (explicit tiebreak — sort stability is not
        // guaranteed).
        decoded.sort { $0.event.ts == $1.event.ts
            ? $0.fileOrder < $1.fileOrder
            : $0.event.ts < $1.event.ts }
        // Synthetic ids numbered in ts order. Wire ids always win; ordinals
        // shift as the file grows — ids identify rows within one loaded
        // timeline, not across eternity.
        var unnamed = 0
        var events: [WifiEvent] = []
        events.reserveCapacity(decoded.count)
        for i in decoded.indices {
            if decoded[i].event.id.trimmingCharacters(in: .whitespaces).isEmpty {
                unnamed += 1
                decoded[i].event.id = "ev-\(unnamed)"
            }
            events.append(decoded[i].event)
        }
        return events
    }
}

// MARK: - Builder

/// Builds the unified QoE timeline (contract TC1) from history samples and
/// WiFi events. Pure functions only — callers own I/O through whichever
/// overload suits them (typed stores for production, injected URLs for tests).
enum TimelineModel {

    /// Merge measurement samples with WiFi events -> ts-sorted `[TimelineRow]`.
    ///
    /// Merge rules (all deterministic):
    /// 1. Samples come from `HistoryRecord.resultRaw`, parsed by
    ///    `AnomalyEngine.metricValue` (parser unity with dashboard/sparkline).
    ///    Payloads yielding no recognizable metric contribute NO row (silent
    ///    skip — same behavior as `AnomalyEngine.extractSeries`).
    /// 2. Rows are keyed by exact `ts`. Two samples at the identical ts merge
    ///    into one row, first-parsed-value-wins per metric.
    /// 3. Each event attaches its `eventId` to the row at its exact ts (the
    ///    marker rides a coincident sample); additional events at an already
    ///    claimed ts get their own marker-only rows (metrics nil — honest).
    /// 4. Output is sorted by `ts`; ties break by construction order
    ///    (metrics-bearing row first, then its extra event rows), so the
    ///    array is stable for identical inputs.
    static func build(records: [HistoryRecord],
                      events: [WifiEvent]) -> [TimelineRow] {
        var rows: [PendingRow] = []
        var rowIndexByTs: [Date: Int] = [:]

        // Pass 1 — samples, oldest-first.
        for record in records.sorted(by: { $0.ts < $1.ts }) {
            let mbps = AnomalyEngine.metricValue(in: record.resultRaw, metric: .mbps)
            let loss = AnomalyEngine.metricValue(in: record.resultRaw, metric: .loss)
            let jitter = AnomalyEngine.metricValue(in: record.resultRaw, metric: .jitter)
            guard mbps != nil || loss != nil || jitter != nil else { continue }
            if let i = rowIndexByTs[record.ts] {
                if rows[i].mbps == nil { rows[i].mbps = mbps }
                if rows[i].lossPct == nil { rows[i].lossPct = loss }
                if rows[i].jitterMs == nil { rows[i].jitterMs = jitter }
            } else {
                rowIndexByTs[record.ts] = rows.count
                rows.append(PendingRow(ts: record.ts, seq: rows.count,
                                       mbps: mbps, lossPct: loss, jitterMs: jitter,
                                       eventId: nil))
            }
        }

        // Pass 2 — events, oldest-first; exact-ts merge onto the sample row.
        for event in events.sorted(by: { $0.ts < $1.ts }) {
            if let i = rowIndexByTs[event.ts], rows[i].eventId == nil {
                rows[i].eventId = event.id
            } else {
                rowIndexByTs[event.ts] = rows.count
                rows.append(PendingRow(ts: event.ts, seq: rows.count,
                                       mbps: nil, lossPct: nil, jitterMs: nil,
                                       eventId: event.id))
            }
        }

        // Contract TC1: merge is by ts sort (stable via the explicit seq
        // tiebreak — Swift's sort is not documented as stable).
        return rows
            .sorted { $0.ts == $1.ts ? $0.seq < $1.seq : $0.ts < $1.ts }
            .map { TimelineRow(ts: $0.ts, mbps: $0.mbps, lossPct: $0.lossPct,
                               jitterMs: $0.jitterMs, eventId: $0.eventId) }
    }

    /// Disk convenience with injectable URLs (offline tests / previews):
    /// loads history + events from the given files and builds the timeline.
    /// Production callers rely on the defaults (contract P2 + TC3 paths).
    static func build(historyFileURL: URL = HistoryStore.defaultFileURL,
                      eventsFileURL: URL = WifiEventsReader.defaultFileURL) -> [TimelineRow] {
        let records = HistoryStore(fileURL: historyFileURL).loadAll()
        let events = WifiEventsReader(fileURL: eventsFileURL).loadAll()
        return build(records: records, events: events)
    }

    /// Mutable accumulator used while merging; never leaves this file.
    private struct PendingRow {
        let ts: Date
        let seq: Int
        var mbps: Double?
        var lossPct: Double?
        var jitterMs: Double?
        var eventId: String?
    }
}

// MARK: - Offline self-checks
//
// Same convention as HistoryStoreTests / AnomalyEngineTests: Package.swift
// has no test target, so these compile into the DEBUG build as plain static
// checks (never executed at runtime) and convert 1:1 into XCTestCase methods.
// The standalone harness exercises the same assertions offline.

#if DEBUG
enum TimelineModelTests {

    @discardableResult
    static func runAll(now: Date = Date(timeIntervalSinceReferenceDate: 900_000_000)) -> Int {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            failures += condition ? 0 : 1
            if !condition { print("[TimelineModelTests] FAIL: \(name)") }
        }
        func record(_ raw: String, _ offset: TimeInterval) -> HistoryRecord {
            HistoryRecord(ts: now.addingTimeInterval(offset),
                          mode: "baseline", params: [:], resultRaw: raw)
        }
        func event(_ kind: WifiEventKind, _ offset: TimeInterval, id: String) -> WifiEvent {
            WifiEvent(ts: now.addingTimeInterval(offset), kind: kind.rawValue, id: id)
        }

        // -- empty inputs ------------------------------------------------------
        check(TimelineModel.build(records: [], events: []).isEmpty,
              "build: empty inputs -> empty output")
        let sampleOnly = TimelineModel.build(
            records: [record(#"{"mbps": 100}"#, 0)], events: [])
        check(sampleOnly.count == 1 && sampleOnly[0].mbps == 100
              && sampleOnly[0].eventId == nil,
              "build: sample-only input yields one plain row")

        // -- interleaved merge order --------------------------------------------
        // Inputs arrive shuffled (t+300,t+100,t+500 samples; t+400,t+200
        // events); output MUST come out strictly ts-sorted.
        let shuffledRecords = [
            record(#"{"mbps": 300}"#, 300),
            record(#"{"mbps": 100}"#, 100),
            record(#"{"mbps": 500}"#, 500),
        ]
        let shuffledEvents = [
            event(.channelChange, 400, id: "wire-ch-400"),
            event(.roam, 200, id: "wire-roam-200"),
        ]
        let merged = TimelineModel.build(records: shuffledRecords, events: shuffledEvents)
        check(merged.map { $0.ts.timeIntervalSince(now) } == [100, 200, 300, 400, 500],
              "merge: interleaved inputs come out ts-sorted")
        check(merged.compactMap(\.eventId) == ["wire-roam-200", "wire-ch-400"],
              "merge: eventIds land on their own rows in ts order")

        // -- honest gaps: missing metrics stay nil, never zero ------------------
        let lossOnly = TimelineModel.build(
            records: [record("packet loss: 0.4%", 0)], events: [])
        check(lossOnly.count == 1 && lossOnly[0].lossPct == 0.4,
              "gaps: loss-only payload parses loss")
        check(lossOnly[0].mbps == nil && lossOnly[0].jitterMs == nil,
              "gaps: absent metrics are nil (honest), not 0")

        let jitterOnly = TimelineModel.build(
            records: [record("jitter: 7.5 ms", 0)], events: [])
        check(jitterOnly[0].jitterMs == 7.5 && jitterOnly[0].mbps == nil,
              "gaps: jitter-only payload keeps mbps nil")

        // -- unreadable payloads contribute nothing -----------------------------
        let silent = TimelineModel.build(
            records: [record("not a payload at all", 0),
                      record(#"{"mbps": 42}"#, 60)],
            events: [])
        check(silent.count == 1 && silent[0].mbps == 42,
              "gaps: unreadable payload skipped silently (never a zero row)")

        // -- exact-ts coincidence: marker rides the sample ----------------------
        let coincident = TimelineModel.build(
            records: [record(#"{"mbps": 120}"#, 90)],
            events: [event(.roam, 90, id: "e-coincide")])
        check(coincident.count == 1,
              "coincide: one row for sample+event at the same ts")
        check(coincident[0].mbps == 120 && coincident[0].eventId == "e-coincide",
              "coincide: row carries BOTH metrics and eventId")

        // -- several events at one ts: first rides the sample, rest own rows ----
        let crowded = TimelineModel.build(
            records: [record(#"{"mbps": 80}"#, 0)],
            events: [event(.rssiDrop, 0, id: "e1"), event(.roam, 0, id: "e2")])
        check(crowded.count == 2, "crowd: extra same-ts event gets its own row")
        check(crowded[0].mbps == 80 && crowded[0].eventId == "e1",
              "crowd: first event merged onto the sample row")
        check(crowded[1].eventId == "e2" && crowded[1].mbps == nil,
              "crowd: second event is a marker-only row (honest nils)")

        // -- determinism ----------------------------------------------------------
        check(TimelineModel.build(records: shuffledRecords, events: shuffledEvents) == merged,
              "determinism: identical input -> identical rows")

        return failures
    }

    /// File-based checks (tolerant reader + injectable-URL disk convenience).
    @discardableResult
    static func runFileChecks(now: Date = Date(timeIntervalSinceReferenceDate: 900_000_000)) -> Int {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            failures += condition ? 0 : 1
            if !condition { print("[TimelineModelTests] FAIL: \(name)") }
        }

        let eventsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("netmax-events-tests-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: eventsURL) }

        // Mixed fixture: good line, junk line, fractional ISO8601, epoch
        // seconds with an unknown kind, then a blank line.
        let lines = [
            #"{"ts":"2026-08-24T09:00:00Z","kind":"roam","id":"w1"}"#,
            "garbage line",
            #"{"ts":"2026-08-24T09:01:00.250Z","kind":"rssi_drop"}"#,
            #"{"ts": 1770000000, "kind": "mystery_kind"}"#,
            "",
        ]
        do {
            try lines.joined(separator: "\n").write(to: eventsURL, atomically: true, encoding: .utf8)
        } catch {
            print("[TimelineModelTests] FAIL: fixture write error \(error)")
            return 1
        }
        let loaded = WifiEventsReader(fileURL: eventsURL).loadAll()
        check(loaded.count == 3,
              "reader: corrupt lines skipped — 3 survive (got \(loaded.count))")
        guard loaded.count == 3 else { return failures }

        // Oldest-first even though the FILE mixes ISO8601 + epoch out of
        // order (the Feb epoch line sits after Aug ISO8601 lines on disk).
        check(loaded.map(\.ts) == loaded.map(\.ts).sorted(),
              "reader: loadAll returns oldest-first regardless of file order")

        let byId = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        check(byId["w1"]?.kind == "roam"
              && byId["w1"]?.ts == WifiEvent.date(fromString: "2026-08-24T09:00:00Z"),
              "reader: wire id kept; whole-second ISO8601 parsed")
        check(byId["ev-1"]?.kind == "mystery_kind"
              && byId["ev-1"]?.knownKind == nil
              && byId["ev-1"]?.ts == Date(timeIntervalSince1970: 1_770_000_000),
              "reader: epoch ts parsed; unknown kind preserved verbatim")
        check(byId["ev-2"]?.kind == "rssi_drop"
              && byId["ev-2"]?.ts == WifiEvent.date(fromString: "2026-08-24T09:01:00.250Z"),
              "reader: missing ids synthesized in ts order; fractional ISO8601 parsed")

        let missing = WifiEventsReader(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("netmax-nope-\(UUID().uuidString).jsonl"))
        check(missing.loadAll().isEmpty, "reader: missing file behaves as empty")

        // End-to-end through the injectable-URL disk convenience.
        let histURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("netmax-history-tests-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: histURL) }
        let historyLines = [
            #"{"ts":"2026-08-24T09:00:05Z","mode":"baseline","params":{},"result_raw":"{\"mbps\": 940.5}"}"#,
            #"{"ts":"2026-08-24T09:02:00Z","mode":"turbo","params":{},"result_raw":"packet loss: 1.5%"}"#,
        ]
        do {
            try historyLines.joined(separator: "\n").write(to: histURL, atomically: true, encoding: .utf8)
        } catch {
            print("[TimelineModelTests] FAIL: history fixture write error \(error)")
            return failures + 1
        }
        let diskRows = TimelineModel.build(historyFileURL: histURL, eventsFileURL: eventsURL)
        check(diskRows.count == 5,
              "disk: 2 samples + 3 events -> 5 rows (got \(diskRows.count))")
        check(diskRows.map(\.ts) == diskRows.map(\.ts).sorted(),
              "disk: end-to-end output is ts-sorted")

        let sampleTs = WifiEvent.date(fromString: "2026-08-24T09:00:05Z")
        let sampleRow = diskRows.first { $0.ts == sampleTs }
        check(sampleRow?.mbps == 940.5 && sampleRow?.eventId == nil,
              "disk: sample row intact")
        let w1Row = diskRows.first { $0.eventId == "w1" }
        check(w1Row != nil && w1Row?.mbps == nil,
              "disk: event 5s off the sample keeps its own row (no forced merge)")

        return failures
    }

    private static func isoDate(_ text: String) -> Date? {
        WifiEvent.date(fromString: text)
    }
}
#endif
