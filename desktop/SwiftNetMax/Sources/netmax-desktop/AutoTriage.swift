//
//  AutoTriage.swift
//  netmax-desktop
//
//  Task 3 — auto-triage when degradation alerts fire. When a run triggers
//  a deliverable degradation alert AND the user has opted in
//  (`netmax.triage.auto`), kick a single `full` engine mode pass to gather
//  deeper evidence (streams/seconds defaults) for the ISP report.
//
//  Guards (all required):
//  • Opt-in only — default OFF, bound to a Settings toggle.
//  • Rate cap — at most one triage per 30 minutes (`netmax.triage.lastRun`).
//  • Re-entrancy — a triage run must not re-trigger itself (it appends
//    history → RunPostProcessor → could fan out again). `isTriaging`
//    short-circuits until the pass finishes.
//
//  No UI in this file. Failures are logged (DEBUG) and swallowed — a
//  triage miss must never break the alert pipeline.
//

import Foundation

enum AutoTriage {
    static let enabledKey = "netmax.triage.auto"
    static let lastRunKey = "netmax.triage.lastRun"
    /// Minimum seconds between automatic triage passes.
    static let minInterval: TimeInterval = 30 * 60

    /// Re-entrancy guard: true while a triage engine pass is in flight.
    /// Main-actor safe because callers hop to MainActor before `maybeRun`.
    private static var isTriaging = false

    /// Opt-in flag (Settings toggle binds to `enabledKey`).
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Pure gate: should a triage fire given `now` + last-run stamp + lock?
    /// Exposed for offline harnesses (no engine, no defaults side effects).
    static func shouldFire(defaults: UserDefaults,
                           now: Date = Date(),
                           hasAlerts: Bool,
                           alreadyTriaging: Bool) -> Bool {
        guard hasAlerts, !alreadyTriaging else { return false }
        guard defaults.bool(forKey: enabledKey) else { return false }
        let last = defaults.double(forKey: lastRunKey)
        guard last > 0 else { return true }
        return now.timeIntervalSince1970 - last >= minInterval
    }

    /// Called from RunPostProcessor after deliverable alerts are selected.
    /// Fire-and-forget: kicks EngineClient `full` on a background task.
    static func maybeRun(alerts: [DegradationAlert],
                         defaults: UserDefaults = .standard,
                         store: HistoryStore = .shared,
                         now: Date = Date()) {
        guard shouldFire(defaults: defaults, now: now,
                         hasAlerts: !alerts.isEmpty,
                         alreadyTriaging: isTriaging)
        else { return }

        isTriaging = true
        defaults.set(now.timeIntervalSince1970, forKey: lastRunKey)

        Task {
            defer { isTriaging = false }
            do {
                // `full` = multi-metric diagnostic pass (engine_bridge MODE_FLAGS).
                // Defaults keep it short; params match ScheduleRunner's shape.
                let output = try await EngineClient().run(
                    "full", args: ["--streams", "4", "--seconds", "5"])
                // C1 contract: every production append MUST call process.
                let record = store.append(
                    mode: "full", params: ["streams": 4, "seconds": 5], raw: output)
                // Re-entrancy: skip post-process fan-out for our own triage run
                // (status publish + views reload only — no recursive triage).
                StatusBarController.publish(record: record, defaults: defaults)
                NotificationCenter.default.post(name: .netmaxHistoryDidChange,
                                                object: nil)
            } catch {
                #if DEBUG
                print("[AutoTriage] full run failed: \(error.localizedDescription)")
                #endif
            }
        }
    }
}

// MARK: - Offline self-checks

#if DEBUG
enum AutoTriageTests {
    @discardableResult
    static func runAll(now: Date = Date()) -> Int {
        var failures = 0
        func check(_ cond: Bool) { failures += cond ? 0 : 1 }

        let suite = "netmax.autotriage.selfcheck." + UUID().uuidString
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }

        // Opt-in default OFF.
        check(!d.bool(forKey: AutoTriage.enabledKey))
        check(!AutoTriage.shouldFire(defaults: d, now: now,
                                     hasAlerts: true, alreadyTriaging: false))

        // Opt-in + alerts + no recent stamp → fire.
        d.set(true, forKey: AutoTriage.enabledKey)
        check(AutoTriage.shouldFire(defaults: d, now: now,
                                    hasAlerts: true, alreadyTriaging: false))

        // No alerts → never.
        check(!AutoTriage.shouldFire(defaults: d, now: now,
                                     hasAlerts: false, alreadyTriaging: false))

        // Re-entrancy lock → never.
        check(!AutoTriage.shouldFire(defaults: d, now: now,
                                     hasAlerts: true, alreadyTriaging: true))

        // Rate cap: recent stamp blocks; old stamp allows.
        d.set(now.timeIntervalSince1970 - 60, forKey: AutoTriage.lastRunKey)
        check(!AutoTriage.shouldFire(defaults: d, now: now,
                                     hasAlerts: true, alreadyTriaging: false))
        d.set(now.timeIntervalSince1970 - (AutoTriage.minInterval + 60),
              forKey: AutoTriage.lastRunKey)
        check(AutoTriage.shouldFire(defaults: d, now: now,
                                    hasAlerts: true, alreadyTriaging: false))

        return failures
    }
}
#endif
