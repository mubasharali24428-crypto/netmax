//
//  StatusBarController.swift
//  netmax-desktop
//
//  ALPHA-A1-09 — menu-bar quick-status helper (wave-1).
//
//  Turns the newest HistoryStore record into a concise menu-bar label plus an
//  accessibility description, and publishes them through UserDefaults so the
//  MenuBarExtra label can observe changes with @AppStorage.
//
//  Contract notes:
//  - Reads HistoryRecord values ONLY through the P2 API surface
//    (HistoryStore.shared.loadAll() / HistoryRecord fields); never touches the
//    history file directly.
//  - Writes ONLY the `netmax.status.*` keys below. This namespace is separate
//    from the P1 `netmax.prefs.*` keys owned by L3-C (AppPreferences); no
//    overlap, no bypass.
//  - Pure-value formatting functions are static and side-effect free so they
//    can be exercised offline (see StatusBarControllerSelfCheck at bottom).
//
//  ── ONE-LINE INTEGRATION FOR App.swift (owner: ATLAS — do not edit here) ──
//
//  Replace the static image label in the MenuBarExtra…
//
//      MenuBarExtra {
//          RootView() …
//      } label: {
//          Image(systemName: "bolt.horizontal.circle")        // ← replace this
//      }
//
//  …with a tiny observing view (label closures cannot hold @AppStorage
//  themselves, but any View can):
//
//      } label: {
//          StatusBarController.LabelView()                    // ← with this
//      }
//
//  and refresh after every completed run by calling, on any queue:
//
//      StatusBarController.publish()                          // reads newest record
//      // …or push an already-loaded record:
//      StatusBarController.publish(record: someHistoryRecord)
//
//  LabelView renders the cached label text (falling back to the plain bolt
//  glyph when no measurement exists yet) and updates live because it observes
//  the `netmax.status.label` key. If ATLAS prefers zero new views, calling
//  publish() is still required for anything to appear — nothing here hooks
//  engine completion callbacks by itself.
//

import SwiftUI

/// Formats and publishes the menu-bar quick-status line (wave-1, ALPHA-A1-09).
///
/// Label shape (mission sample): `⚡ 29 Mbps · B · 12m ago`
///   ⚡  ·  headline metric from the record's result payload
///      ·  single-letter mode tag  ·  compact relative age.
///
/// The metric is extracted defensively: the engine's pretty-printed payload is
/// either a numeric JSON object (`{"mbps": 42.5}`) or the wrapped-text form
/// (`{"raw": "single-stream … 29.3 Mbps"}`), and older/future engines may emit
/// either — so lookup order is named JSON keys, then tagged text patterns,
/// then a bare first-number scan (mirroring HistoryView's trend heuristic).
enum StatusBarController {

    // MARK: Published keys (@AppStorage-compatible)

    /// Concise menu-bar label text, e.g. `⚡ 29 Mbps · B · 12m ago`.
    /// Empty string means "nothing published yet / history cleared".
    static let labelKey = "netmax.status.label"

    /// Longer accessibility description spoken by VoiceOver, e.g.
    /// `NetMax: last measurement 29.3 megabits per second, baseline mode, 12 minutes ago`.
    static let detailKey = "netmax.status.detail"

    /// Convenience for non-view consumers: the currently cached label.
    static var cachedLabel: String {
        UserDefaults.standard.string(forKey: labelKey) ?? ""
    }

    // MARK: Publishing

    /// Format `record` and write the results through UserDefaults.
    ///
    /// Thread-safe (UserDefaults is). Pass `nil` (or call `clear()`) when
    /// history is emptied so a stale speed never lingers in the menu bar.
    /// - Parameters:
    ///   - record: newest history record, or nil for "no data".
    ///   - now: injectable clock for tests; production callers omit it.
    ///   - defaults: injectable backing store for tests/self-checks.
    static func publish(record: HistoryRecord?,
                        now: Date = Date(),
                        defaults: UserDefaults = .standard) {
        if let record {
            defaults.set(
                labelText(for: record, now: now),
                forKey: labelKey)
            defaults.set(
                accessibilityDescription(for: record, now: now),
                forKey: detailKey)
        } else {
            clear(defaults: defaults)
        }
    }

    /// Republish from the store: picks up the newest record, or clears the
    /// keys when history is empty. Call after each completed run and after
    /// Clear History.
    static func publish(store: HistoryStore = .shared,
                        now: Date = Date(),
                        defaults: UserDefaults = .standard) {
        publish(record: store.loadAll().max { $0.ts < $1.ts },
                now: now, defaults: defaults)
    }

    /// Remove both keys (used when history is cleared).
    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: labelKey)
        defaults.removeObject(forKey: detailKey)
    }

    // MARK: Label formatting

    /// The concise one-line status: `⚡ 29 Mbps · B · 12m ago`.
    static func labelText(for record: HistoryRecord, now: Date = Date()) -> String {
        // Bolt and metric read as one token ("⚡ 29 Mbps"); mode and age are
        // separated by middots. Sub-minute ages render bare ("now", no "ago").
        let metric = Self.metricSummary(in: record.resultRaw).map { " \($0)" } ?? ""
        let age = relativeAge(from: record.ts, to: now)
        return ["⚡\(metric)", modeTag(for: record.mode),
                age == "now" ? age : "\(age) ago"].joined(separator: " · ")
    }

    /// VoiceOver-friendly sentence describing the same information.
    static func accessibilityDescription(for record: HistoryRecord,
                                         now: Date = Date()) -> String {
        let metric = Self.metricSummary(in: record.resultRaw)
            .map { ", \($0)" } ?? ""
        let age = spelledOutAge(from: record.ts, to: now)
        return "NetMax: last measurement\(metric), "
            + "\(record.mode) mode, \(age)"
    }

    // MARK: Piecewise formatters (internal for self-checks)

    /// Short mode tag: known C1 modes get stable tags (baseline → "B"),
    /// unknown modes fall back to their capitalized prefix.
    static func modeTag(for mode: String) -> String {
        switch mode.lowercased() {
        case "baseline": return "B"
        case "turbo":    return "T"
        case "boost":    return "Bo"
        case "dns":      return "DNS"
        case "bloat":    return "BL"
        case "full":     return "F"
        case "upload":   return "U"
        case "loss":     return "L"
        case "jitter":   return "J"
        case "wifi":     return "W"
        default:
            let prefix = mode.prefix(2)
            return prefix.isEmpty
                ? "?"
                : prefix.capitalized
        }
    }

    /// Compact age: `12m`, `3h`, `2d`; anything under ~a minute reads as `now`.
    /// Clock skew (future timestamps) clamps to `now`.
    static func relativeAge(from date: Date, to now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 0 else { return "now" }           // future-dated record
        if seconds < 75 { return "now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    /// Same age in words for the accessibility description.
    static func spelledOutAge(from date: Date, to now: Date) -> String {
        let age = relativeAge(from: date, to: now)
        if age == "now" { return "just now" }
        let (unit, singular) = age.hasSuffix("m") ? ("minutes", "minute")
            : age.hasSuffix("h") ? ("hours", "hour")
            : ("days", "day")
        let n = Int(age.dropLast()) ?? 0
        return n == 1 ? "1 \(singular) ago" : "\(n) \(unit) ago"
    }

    /// Headline metric from the raw payload: `29 Mbps`, `87 ms`, `3% loss`…
    /// nil when nothing numeric can be found (label then shows mode + age).
    static func metricSummary(in raw: String) -> String? {
        // 1) Named keys in the pretty-printed JSON object form.
        if let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let dict = obj as? [String: Any] {
            for (keys, unit, scale) in keyedMetricPatterns {
                for key in keys {
                    if let value = keyValue(in: dict, key: key) {
                        return format(value * scale) + unit
                    }
                }
            }
        }
        // 2) Tagged patterns inside wrapped stdout text: `29.3 Mbps`, `84.1 ms`, `2 %`.
        if let match = raw.range(of: #"(\d+(?:\.\d+)?)\s*(Mbps|ms|%)"#,
                                 options: .regularExpression) {
            let token = String(raw[match])
            let number = token.prefix { $0.isNumber || $0 == "." }
            let unit = token.drop { $0.isNumber || $0 == "." }
                .trimmingCharacters(in: .whitespaces)
            switch unit {
            case "Mbps": return trim(number) + " Mbps"
            case "ms":   return trim(number) + " ms"
            default:     return trim(number) + "% loss"
            }
        }
        // 3) Bare first number anywhere (same lenient heuristic as trends).
        if let match = raw.range(of: #"\d+(?:\.\d+)?"#, options: .regularExpression) {
            return trim(String(raw[match]))
        }
        return nil
    }

    /// (candidate keys, unit suffix, multiplier) in display-priority order.
    /// `scale` normalizes e.g. fractional loss stored as 0.03 → "3%".
    private static let keyedMetricPatterns: [(keys: [String], unit: String, scale: Double)] = [
        (["mbps", "throughput_mbps", "download_mbps", "speed_mbps", "upload_mbps"], " Mbps", 1),
        (["delta_ms", "latency_ms", "idle_ms", "loaded_ms", "rtt_ms"], " ms", 1),
        (["jitter_ms"], " ms jitter", 1),
        (["loss_pct", "packet_loss_pct", "loss_percent"], "% loss", 1),
        (["loss", "packet_loss"], "% loss", 100)   // fraction → percent
    ]

    /// First Double found for `key`, accepting Int/Double/numeric-string.
    private static func keyValue(in dict: [String: Any], key: String) -> Double? {
        guard let value = dict[key] else { return nil }
        switch value {
        case let n as Double: return n.isFinite ? n : nil
        case let n as Int:    return Double(n)
        case let s as String: return Double(s)
        default:              return nil
        }
    }

    /// Number formatting: whole values stay whole ("29"), otherwise one decimal.
    private static func format(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%.1f", value)
    }

    private static func trim(_ text: some StringProtocol) -> String {
        guard let value = Double(text) else { return String(text) }
        return format(value)
    }
}

// MARK: - Menu-bar label view (the piece App.swift's label closure hosts)

extension StatusBarController {

    /// Drop-in MenuBarExtra label: shows the published quick-status text and
    /// live-updates whenever `publish` writes the key. Falls back to the bolt
    /// glyph before the first measurement (empty label state).
    struct LabelView: View {
        @AppStorage(StatusBarController.labelKey) private var label = ""

        var body: some View {
            if label.isEmpty {
                Image(systemName: "bolt.horizontal.circle")
                    .accessibilityLabel("NetMax")
            } else {
                Text(label)
                    .accessibilityLabel(
                        UserDefaults.standard.string(
                            forKey: StatusBarController.detailKey) ?? label)
            }
        }
    }
}

#if DEBUG
/// Offline self-checks, house style (see HistoryStoreTests): plain enum with
/// static checks compiled into DEBUG builds; returns failure count (0 == pass).
enum StatusBarControllerSelfCheck {
    @discardableResult
    static func runAll(now: Date = Date()) -> Int {
        var failures = 0

        // Mission sample shape: mbps payload, baseline, 12 minutes old.
        do {
            let record = HistoryRecord(
                ts: now.addingTimeInterval(-12 * 60), mode: "baseline",
                params: ["streams": 1], resultRaw: #"{"mbps": 29}"#)
            let label = StatusBarController.labelText(for: record, now: now)
            failures += (label == "⚡ 29 Mbps · B · 12m ago") ? 0 : 1
        }

        // Wrapped-text payload picks up "Mbps" from stdout text.
        do {
            let record = HistoryRecord(
                ts: now.addingTimeInterval(-30), mode: "turbo",
                params: ["streams": 8],
                resultRaw: #"{"raw": "multi-stream 8 stream(s)   940.5 Mbps   (1,176 MB in 10s)"}"#)
            let label = StatusBarController.labelText(for: record, now: now)
            failures += (label == "⚡ 940.5 Mbps · T · now") ? 0 : 1
        }

        // Latency-style payload routes to ms; loaded latency (delta_ms)
        // outranks idle_ms; unknown mode falls back to prefix.
        do {
            let record = HistoryRecord(
                ts: now.addingTimeInterval(-3 * 3600), mode: "bloat",
                params: [:], resultRaw: #"{"idle_ms": 18.2, "delta_ms": 87.4}"#)
            let label = StatusBarController.labelText(for: record, now: now)
            failures += (label == "⚡ 87.4 ms · BL · 3h ago") ? 0 : 1
        }

        // Non-numeric payload degrades to mode + age only.
        do {
            let record = HistoryRecord(
                ts: now.addingTimeInterval(2 * 24 * 3600 * -1), mode: "dns",
                params: [:], resultRaw: #"{"note": "no numbers here"}"#)
            let label = StatusBarController.labelText(for: record, now: now)
            failures += (label == "⚡ · DNS · 2d ago") ? 0 : 1
        }

        // Future timestamp (clock skew) clamps to "now".
        do {
            let record = HistoryRecord(
                ts: now.addingTimeInterval(300), mode: "turbo",
                params: [:], resultRaw: #"{"mbps": 50}"#)
            let label = StatusBarController.labelText(for: record, now: now)
            failures += (label.hasSuffix("· now")) ? 0 : 1
        }

        // Accessibility sentence carries mode, value and spelled-out age.
        do {
            let record = HistoryRecord(
                ts: now.addingTimeInterval(-150), mode: "turbo",
                params: [:], resultRaw: #"{"mbps": 29.34}"#)
            let spoken = StatusBarController.accessibilityDescription(for: record, now: now)
            let expected = "NetMax: last measurement, 29.3 Mbps, turbo mode, 2 minutes ago"
            failures += (spoken == expected) ? 0 : 1
        }

        // publish() writes both keys; publish(nil)/clear() removes them.
        do {
            let suite = "netmax.status.selfcheck"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let record = HistoryRecord(
                ts: now, mode: "boost", params: [:], resultRaw: #"{"mbps": 120}"#)
            StatusBarController.publish(record: record, now: now, defaults: defaults)
            failures += (defaults.string(forKey: StatusBarController.labelKey) != nil) ? 0 : 1
            failures += (defaults.string(forKey: StatusBarController.detailKey) != nil) ? 0 : 1
            StatusBarController.publish(record: nil, now: now, defaults: defaults)
            failures += (defaults.string(forKey: StatusBarController.labelKey) == nil) ? 0 : 1
        }

        return failures
    }
}
#endif
