//
//  NotifyDigest.swift
//  netmax-desktop
//
//  W7-1 — Notification digest batching (opt-in).
//
//  Degradation alerts are not posted one-by-one; they accumulate as short
//  summaries under the "netmax.notify.pending" UserDefaults array key. Once at
//  least 24h have passed since the last digest ("netmax.notify.lastDigest"),
//  `flushIfDue()` folds the pending entries into ONE summary string
//  ("<N> degradations in the last 24h: …"), clears the queue, stamps the
//  timestamp, and hands the string back to the caller to post.
//
//  Preference gate: the whole feature is inert unless
//  "netmax.notify.digest" == true (UserDefaults.bool default is false, i.e.
//  opt-in). Gate off ⇒ nothing is stored, nothing flushes.
//
//  ScheduleRunner integration: call `NotifyDigest.flushIfDue()` inside tick()
//  and post the returned string via the normal notification path (nil ⇒ skip).
//

import Foundation

/// Opt-in daily digest for degradation notifications (W7-1).
enum NotifyDigest {

    private static let pendingKey = "netmax.notify.pending"
    private static let lastFlushKey = "netmax.notify.lastDigest"
    static let digestGateKey = "netmax.notify.digest"

    /// Minimum interval between two digests.
    private static let digestInterval: TimeInterval = 24 * 60 * 60

    /// True only when the user opted in ("netmax.notify.digest"); default false.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: digestGateKey)
    }

    // MARK: - API

    /// Queue one alert's summary for the next digest. No-op while the gate is
    /// off ("netmax.notify.digest" false/absent ⇒ opt-in, nothing is stored).
    ///
    /// Pending layout: an array of two-string entries
    /// `[kind-title, grade-or-value summary]` under "netmax.notify.pending",
    /// so each queued item survives round-trips as a plist-compatible pair.
    static func consider(alert: DegradationAlert, defaults: UserDefaults = .standard) {
        guard defaults.bool(forKey: digestGateKey) else { return }
        var pending = (defaults.array(forKey: pendingKey) as? [[String]]) ?? []
        pending.append([Self.title(for: alert.kind), Self.summaryLine(for: alert)])
        defaults.set(pending, forKey: pendingKey)
    }

    /// Fold the pending queue into ONE digest string when one is due:
    /// pending non-empty AND ≥ 24h since the last flush (missing stamp counts
    /// as never-flushed ⇒ due immediately). Clears the queue, stamps
    /// "netmax.notify.lastDigest", and returns the string for the caller to
    /// post; nil when the gate is off, the queue is empty, or it's not yet due.
    @discardableResult
    static func flushIfDue(
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> String? {
        guard defaults.bool(forKey: digestGateKey) else { return nil }
        guard let entries = defaults.array(forKey: pendingKey) as? [[String]],
              !entries.isEmpty else { return nil }

        if let last = defaults.object(forKey: lastFlushKey) as? Date,
           now.timeIntervalSince(last) < digestInterval {
            return nil
        }

        let noun = entries.count == 1 ? "degradation" : "degradations"
        let lines = entries.map { entry in
            entry.count >= 2 ? "\(entry[0]): \(entry[1])" : entry.joined(separator: ": ")
        }
        let digest = "\(entries.count) \(noun) in the last 24h: "
            + lines.joined(separator: "; ")

        defaults.removeObject(forKey: pendingKey)
        defaults.set(now, forKey: lastFlushKey)
        return digest
    }

    // MARK: - Entry formatting

    /// Display title for a kind — mirrors NotificationCoordinator's private
    /// `title(for:)` so digest rows match the live notifications verbatim.
    private static func title(for kind: DegradationAlert.Kind) -> String {
        switch kind {
        case .bloatGradeDrop:   return "Bufferbloat warning"
        case .packetLossSpike:  return "Packet loss detected"
        case .successToFailure: return "Measurement failed"
        }
    }

    /// Grade-or-value summary pulled out of the alert's ready-to-post text:
    /// the two grades for drops, the measured percent for loss spikes, the
    /// engine mode for failures. Falls back to a plain description when the
    /// expected phrasing ever changes.
    private static func summaryLine(for alert: DegradationAlert) -> String {
        switch alert.kind {
        case .bloatGradeDrop:
            if let g = capturePair(of: alert.text, pattern: #"from\s+([A-F]\+?)\s+to\s+([A-F]\+?)"#) {
                return "grade \(g.0)→\(g.1)"
            }
            return "bufferbloat grade drop"
        case .packetLossSpike:
            if let p = firstCapture(of: alert.text, pattern: #"is\s+([0-9.]+)%"#) {
                return "\(p)% packet loss"
            }
            return "packet loss spike"
        case .successToFailure:
            if let mode = firstCapture(of: alert.text, pattern: #"\([Mm]ode\s+([^)]+)\)"#) {
                return "failure after success (mode \(mode))"
            }
            return "failure after success"
        }
    }

    /// First capture group of `pattern` in `text`, if any.
    private static func firstCapture(of text: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// First two capture groups of `pattern` in `text`, if any.
    private static func capturePair(of text: String, pattern: String) -> (String, String)? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range),
              m.numberOfRanges > 2,
              let r1 = Range(m.range(at: 1), in: text),
              let r2 = Range(m.range(at: 2), in: text) else { return nil }
        return (String(text[r1]), String(text[r2]))
    }
}

#if DEBUG
extension NotifyDigest {
    /// Self-checks (DEBUG only), against an isolated defaults suite:
    /// 1. gate off  ⇒ consider() never stores;
    /// 2. gate on   ⇒ pending accumulates one entry per alert;
    /// 3. first due flush ⇒ returns the digest, clears pending, stamps time;
    /// 4. re-arm then flush < 24h later ⇒ nil, pending untouched.
    /// Returns the number of checks passed (0...4).
    @discardableResult
    static func runAll() -> Int {
        var passed = 0
        let suite = "netmax.notifydigest.selfcheck.\(UUID().uuidString)"
        guard let d = UserDefaults(suiteName: suite) else { return passed }
        defer { d.removePersistentDomain(forName: suite) }

        // 1) Gate off: nothing is ever stored.
        d.set(false, forKey: digestGateKey)
        consider(alert: Self.sampleGradeDrop, defaults: d)
        if ((d.array(forKey: pendingKey) as? [[String]])?.isEmpty ?? true) { passed += 1 }

        // 2) Gate on: pending accumulates.
        d.set(true, forKey: digestGateKey)
        consider(alert: Self.sampleGradeDrop, defaults: d)
        consider(alert: Self.sampleLossSpike, defaults: d)
        if (d.array(forKey: pendingKey) as? [[String]])?.count == 2 { passed += 1 }

        // 3) Due flush: digest comes back, queue clears, stamp recorded.
        let epoch = Date(timeIntervalSince1970: 1_000_000_000)
        if let digest = flushIfDue(now: epoch, defaults: d),
           digest.hasPrefix("2 degradations in the last 24h: "),
           ((d.array(forKey: pendingKey) as? [[String]])?.isEmpty ?? true), // absent ⇒ cleared
           (d.object(forKey: lastFlushKey) as? Date) == epoch {
            passed += 1
        }

        // 4) Not yet due (< 24h): nil, pending kept for later.
        consider(alert: Self.sampleFailure, defaults: d)
        if flushIfDue(now: epoch.addingTimeInterval(60 * 60), defaults: d) == nil,
           (d.array(forKey: pendingKey) as? [[String]])?.count == 1 {
            passed += 1
        }
        return passed
    }

    // Fixtures shaped like evaluateDegradation()'s output.
    private static let sampleGradeDrop = DegradationAlert(
        kind: .bloatGradeDrop, newerIndex: 1,
        text: "Bufferbloat grade dropped from B to D. "
            + "Latency under load got much worse — check router SQM/QoS settings.")
    private static let sampleLossSpike = DegradationAlert(
        kind: .packetLossSpike, newerIndex: 2,
        text: String(format: "Packet loss is %.1f%% — above the healthy 3%% threshold. "
            + "Connections may stutter or drop.", 4.5))
    private static let sampleFailure = DegradationAlert(
        kind: .successToFailure, newerIndex: 3,
        text: "The latest measurement failed after a successful run "
            + "(mode auto). Check your connection and try again.")
}
#endif
