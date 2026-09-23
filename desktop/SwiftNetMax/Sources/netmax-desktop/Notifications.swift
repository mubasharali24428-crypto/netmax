import Foundation
import UserNotifications

// MARK: - Degradation rules (pure functions, no UN framework)

/// Pure rule layer for the notification mission: everything that decides
/// *whether* something is worth alerting about and *what it should say*
/// lives here as free-standing, side-effect-free code touching no
/// `UserNotifications` types. The `UNUserNotificationCenter` glue sits in
/// `NotificationCoordinator` below. This separation keeps the rules
/// unit-testable offline (`/tmp` snippets, no authorization prompts).

/// One degradation signal found between two consecutive history records.
struct DegradationAlert: Equatable {
    enum Kind: String {
        case bloatGradeDrop
        case packetLossSpike
        case successToFailure
    }

    let kind: Kind
    /// Index of the NEWER record (the one whose result triggered the alert)
    /// within the record array passed to `evaluateDegradation`.
    let newerIndex: Int
    /// Human-readable alert text, ready to post verbatim.
    let text: String
}

// MARK: - Result-payload extraction (tolerant)

private extension HistoryRecord {
    /// Parse `result_raw` as JSON; non-JSON payloads fall back to a synthetic
    /// wrapper so the regex fallbacks below still see the raw text.
    var payload: [String: Any] {
        if let data = resultRaw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let dict = obj as? [String: Any] {
            return dict
        }
        return ["_raw": resultRaw]
    }

    /// Bufferbloat grade letter ("A+" … "F") from the engine's pretty-printed
    /// payload (`grade: A`) or raw text (`grade: B`). Nil when absent.
    var bloatGrade: String? {
        if let g = payload["grade"] as? String { return g }
        return firstMatch(of: "grade:?\\s*\\b([A-F]\\+?)\\b")
    }

    /// Packet-loss percent from `"loss": 1.2` / `"packet_loss"` keys or a
    /// `packet loss: 0.0%` text line. Nil when absent.
    var packetLossPercent: Double? {
        for key in ["loss", "packet_loss", "packetLoss"] {
            if let n = Self.number(payload[key]) { return n }
        }
        if let m = firstMatch(of: "packet loss:?\\s*([0-9.]+)\\s*%") {
            return Double(m)
        }
        return nil
    }

    /// Success flag. The engine envelope's `success` is not persisted by P2,
    /// so absence of any explicit flag means "succeeded" (a run that produced
    /// a stored record completed; failures surface as engine error text).
    var isSuccess: Bool {
        if let b = payload["success"] as? Bool { return b }
        if let s = payload["status"] as? String {
            let lowered = s.lowercased()
            if lowered == "failed" || lowered == "error" || lowered == "failure" {
                return false
            }
            return true
        }
        if let e = payload["error"] as? String { return e.isEmpty }
        // Raw-text fallbacks: engine failure banners look like "Engine failed:".
        let lower = resultRaw.lowercased()
        if lower.contains("engine failed") || lower.contains("run failed") {
            return false
        }
        return true
    }

    /// First capture group of `pattern` in `resultRaw`, if any.
    func firstMatch(of pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(resultRaw.startIndex..., in: resultRaw)
        guard let m = re.firstMatch(in: resultRaw, range: range),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: resultRaw) else { return nil }
        return String(resultRaw[r])
    }

    /// Accept numbers that JSON decoded as Int or Double (or numeric strings).
    static func number(_ any: Any?) -> Double? {
        switch any {
        case let n as Int: return Double(n)
        case let n as Double: return n
        case let s as String: return Double(s)
        default: return nil
        }
    }
}

// MARK: - Grade helpers

enum NotificationRules {
    /// Waveform/DSLReports rubric used by the engine (`netmax.py:BLOAT_GRADES`):
    /// best → worst. "A+" is two characters but one step above "A".
    static let gradeOrder = ["A+", "A", "B", "C", "D", "F"]

    /// Number of rubric steps between two grades (negative when `to` improved).
    static func gradeDrop(from: String, to: String) -> Int? {
        guard let i = gradeOrder.firstIndex(of: from),
              let j = gradeOrder.firstIndex(of: to) else { return nil }
        return j - i
    }
}

// MARK: - Degradation evaluation

/// Evaluate a history record set (oldest-first, as returned by
/// `HistoryStore.loadAll()`) and return one alert per degradation found,
/// in chronological order. Consecutive same-kind degradations collapse into
/// the latest pair only when they repeat back-to-back (no alert spam).
func evaluateDegradation(_ records: [HistoryRecord]) -> [DegradationAlert] {
    guard records.count >= 2 else { return [] }
    var alerts: [DegradationAlert] = []

    for i in 1..<records.count {
        let older = records[i - 1]
        let newer = records[i]

        // 1) Bloat grade drop ≥ 2 letters between consecutive runs.
        if let g0 = older.bloatGrade, let g1 = newer.bloatGrade,
           let drop = NotificationRules.gradeDrop(from: g0, to: g1), drop >= 2 {
            alerts.append(DegradationAlert(
                kind: .bloatGradeDrop, newerIndex: i,
                text: "Bufferbloat grade dropped from \(g0) to \(g1). "
                    + "Latency under load got much worse — check router SQM/QoS settings."
            ))
            continue
        }

        // 2) Loss > 3% on the newer run (previous ≤ 3% or unknown).
        if let loss = newer.packetLossPercent, loss > 3.0 {
            alerts.append(DegradationAlert(
                kind: .packetLossSpike, newerIndex: i,
                text: String(
                    format: "Packet loss is %.1f%% — above the healthy 3%% threshold. "
                        + "Connections may stutter or drop.", loss)
            ))
            continue
        }

        // 3) Success → failure transition between consecutive runs.
        if older.isSuccess, !newer.isSuccess {
            alerts.append(DegradationAlert(
                kind: .successToFailure, newerIndex: i,
                text: "The latest measurement failed after a successful run "
                    + "(mode \(newer.mode)). Check your connection and try again."
            ))
            continue
        }
    }
    return alerts
}

// MARK: - UNUserNotificationCenter glue

/// Thin async wrapper around `UNUserNotificationCenter`: lazy authorization,
/// posting of rule-derived alerts, quiet-hours respect. All decision logic
/// lives in the pure layer above.
@MainActor
final class NotificationCoordinator {
    static let shared = NotificationCoordinator()

    /// Quiet hours (local time); notifications due inside the window are held
    /// until its end. M6: hardcoded defaults 22:00–07:30 — NOT user-tunable
    /// (no AppPreferences keys / Settings UI yet).
    var quietHoursStart: (hour: Int, minute: Int) = (22, 0)
    var quietHoursEnd: (hour: Int, minute: Int) = (7, 30)

    private let center = UNUserNotificationCenter.current()

    /// Request notification authorization lazily — call right before the
    /// first meaningful post (per UX blueprint: opt-in during onboarding).
    /// Never prompts twice; repeated calls are cheap no-ops.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default:
            return false // denied
        }
    }

    /// Evaluate the given record set and post one notification per alert.
    /// - Returns: the alerts actually posted (authorization granted + not suppressed).
    @discardableResult
    func process(records: [HistoryRecord], now: Date = Date()) async -> [DegradationAlert] {
        await process(alerts: evaluateDegradation(records), now: now)
    }

    /// Post pre-computed alerts (pair-scoped / preference-filtered upstream).
    /// Callers MUST NOT pass full-history `evaluateDegradation` output — that
    /// re-posts every historical drop. Use RunPostProcessor's pair scoping.
    @discardableResult
    func process(alerts: [DegradationAlert], now: Date = Date()) async -> [DegradationAlert] {
        guard !alerts.isEmpty else { return [] }
        // W7-1 digest: opted-in ⇒ queue instead of posting each alert; the
        // ScheduleRunner tick folds the queue into ONE daily summary.
        if NotifyDigest.isEnabled {
            for alert in alerts { NotifyDigest.consider(alert: alert) }
            return []
        }
        guard await requestAuthorizationIfNeeded() else { return [] }

        var posted: [DegradationAlert] = []
        for (i, alert) in alerts.enumerated() {
            let content = UNMutableNotificationContent()
            content.title = Self.title(for: alert.kind)
            content.body = alert.text
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "netmax.degradation.\(alert.kind.rawValue).\(i)",
                content: content,
                trigger: Self.trigger(respectingQuietHoursFrom: now)
            )
            do {
                try await center.add(request)
                posted.append(alert)
            } catch {
                #if DEBUG
                print("[Notifications] post failed: \(error.localizedDescription)")
                #endif
            }
        }
        return posted
    }

    /// Post the folded daily-digest string (W7-1 flush path — called from
    /// ScheduleRunner's tick with `NotifyDigest.flushIfDue()`'s output).
    /// Same authorization + quiet-hours policy as individual alerts.
    @discardableResult
    func postDigest(_ text: String, now: Date = Date()) async -> Bool {
        guard await requestAuthorizationIfNeeded() else { return false }
        let content = UNMutableNotificationContent()
        content.title = "NetMax daily digest"
        content.body = text
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "netmax.degradation.digest",
            content: content,
            trigger: Self.trigger(respectingQuietHoursFrom: now)
        )
        do {
            try await center.add(request)
            return true
        } catch {
            #if DEBUG
            print("[Notifications] digest post failed: \(error.localizedDescription)")
            #endif
            return false
        }
    }

    private static func title(for kind: DegradationAlert.Kind) -> String {
        switch kind {
        case .bloatGradeDrop: return "Bufferbloat warning"
        case .packetLossSpike: return "Packet loss detected"
        case .successToFailure: return "Measurement failed"
        }
    }

    /// Deliver immediately, or at the end of the quiet-hours window when
    /// `date` falls inside it.
    static func trigger(respectingQuietHoursFrom date: Date,
                        window: (start: (hour: Int, minute: Int),
                                 end: (hour: Int, minute: Int))? = nil) -> UNNotificationTrigger? {
        let shared = NotificationCoordinator.shared
        let w = window ?? (shared.quietHoursStart, shared.quietHoursEnd)
        if let end = endOfQuietHours(after: date, start: w.start, end: w.end) {
            return UNCalendarNotificationTrigger(dateMatching: end, repeats: false)
        }
        return nil // deliver now
    }

    /// Calendar components for the next quiet-hours exit, or nil when `date`
    /// is outside the `[start, end)` local-time window (may wrap midnight).
    static func endOfQuietHours(after date: Date,
                                start: (hour: Int, minute: Int),
                                end: (hour: Int, minute: Int)) -> DateComponents? {
        var cal = Calendar.current
        cal.timeZone = .current
        let comps = cal.dateComponents([.hour, .minute], from: date)
        guard let h = comps.hour, let m = comps.minute else { return nil }
        let startMins = start.hour * 60 + start.minute
        let endMins = end.hour * 60 + end.minute
        let nowMins = h * 60 + m

        let inWindow: Bool
        if startMins <= endMins {
            inWindow = nowMins >= startMins && nowMins < endMins
        } else {
            inWindow = nowMins >= startMins || nowMins < endMins // wraps midnight
        }
        guard inWindow else { return nil }

        // Resolve the NEXT wall-clock occurrence of the window end (handles
        // past-midnight windows and DST via the calendar, not manual math).
        var match = DateComponents()
        match.hour = end.hour
        match.minute = end.minute
        guard let fireDate = cal.nextDate(after: date, matching: match,
                                          matchingPolicy: .nextTime) else { return nil }
        return cal.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
    }
}
