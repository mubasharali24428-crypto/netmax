//
//  Scheduler.swift
//  netmax-desktop
//
//  ALPHA-A1-01 (wave-1): scheduler core.
//
//  Owns the schedule persistence under the lane-private key prefix
//  `netmax.schedule.*` — deliberately NOT part of contract P1's
//  `netmax.prefs.*` namespace, which belongs to AppPreferences.
//
//      netmax.schedule.enabled          Bool    default false
//      netmax.schedule.intervalMinutes  Int     default 60, clamped 5...1440
//      netmax.schedule.lastFire         Double  epoch seconds of last recorded
//                                               fire (0 == never fired)
//
//  Layout (testability first):
//  - `ScheduleConfig`, `ScheduleLimits`, and `ScheduleMath` are PURE value
//    logic: no SwiftUI, no clock reads, no UserDefaults access unless a store
//    is explicitly passed in. Everything interesting (next-fire math, due
//    checks, clamping) lives here and can be exercised headless.
//  - `Scheduler` is the thin observable shell the app binds to: loads/saves
//    config, exposes `tick()` for `.onAppear` / Timer callbacks, and publishes
//    the computed next-fire date for display.
//
//  Threading: follow the AppPreferences convention — mutate on the main
//  thread; reads are safe anywhere.
//

import Foundation
import Combine

// MARK: - Limits & fallbacks

/// Sane bounds for the schedule, enforced on every set regardless of source
/// (settings UI, restored backup, future importer) — same policy as P1.
enum ScheduleLimits {
    /// Interval range in minutes: 5 minutes … 24 hours.
    /// [UNCERTAIN] Exact bounds are this lane's choice; the wave docs fix the
    /// key names but not the numeric range.
    static let intervalMinutes = 5...1440
}

/// Fallbacks used when a key was never written.
enum ScheduleFallbacks {
    static let enabled          = false
    static let intervalMinutes  = 60
    static let lastFireEpoch: Double = 0   // 0 sentinel == never fired
}

// MARK: - Keys

/// Key spellings for `netmax.schedule.*`. Owned by this file; other lanes
/// must go through `Scheduler.shared`, not touch UserDefaults directly.
enum ScheduleKeys {
    static let enabled         = "netmax.schedule.enabled"
    static let intervalMinutes = "netmax.schedule.intervalMinutes"
    static let lastFire        = "netmax.schedule.lastFire"
}

// MARK: - Pure configuration value

/// The persisted schedule settings as a plain value type.
struct ScheduleConfig: Equatable {
    /// Whether scheduled runs are active at all.
    var isEnabled: Bool
    /// Minutes between runs (always kept inside `ScheduleLimits.intervalMinutes`).
    var intervalMinutes: Int

    static func clampedInterval(_ minutes: Int) -> Int {
        let r = ScheduleLimits.intervalMinutes
        return min(max(minutes, r.lowerBound), r.upperBound)
    }

    /// The interval as a `TimeInterval` (seconds), ready for date math.
    var interval: TimeInterval { TimeInterval(intervalMinutes) * 60 }
}

// MARK: - Pure scheduling math

/// Stateless next-fire arithmetic. No clocks, no storage — pass everything in.
/// This is the part most worth unit-testing; it never touches the process.
enum ScheduleMath {

    /// When should the schedule next fire?
    ///
    /// Rules:
    /// - Never fired yet (`lastRun == nil`): the first fire is one full
    ///   interval from `now` — enabling the schedule does NOT fire instantly.
    /// - Otherwise: `lastRun + interval`.
    /// - Overdue (candidate already in the past): fires "now" — the schedule
    ///   catches up rather than skipping ahead.
    /// - Clock skew guard: a `lastRun` in the future (clock rolled back /
    ///   synced) is treated as `now` so the wait is always ≥ one interval.
    ///
    /// - Parameters:
    ///   - lastRun: epoch date of the previous fire, or nil if never fired.
    ///   - interval: cadence in seconds (> 0 expected; callers clamp upstream).
    ///   - now: reference instant supplied by the caller (injectable in tests).
    static func nextFire(lastRun: Date?, interval: TimeInterval, now: Date) -> Date {
        // Total function: a non-positive interval falls back to the default
        // cadence rather than producing a zero/negative wait.
        let effectiveInterval = interval > 0
            ? interval
            : TimeInterval(ScheduleFallbacks.intervalMinutes) * 60
        switch lastRun {
        case nil:
            return now.addingTimeInterval(effectiveInterval)
        case .some(let run):
            let anchor = run > now ? now : run      // skew guard
            let candidate = anchor.addingTimeInterval(effectiveInterval)
            return candidate <= now ? now : candidate
        }
    }

    /// Should the schedule fire right now?
    /// Due ⇔ enabled AND (overdue OR exactly on the boundary `>=`).
    static func isDue(enabled: Bool, lastRun: Date?, interval: TimeInterval, now: Date) -> Bool {
        guard enabled else { return false }
        guard let lastRun else { return false }     // first cycle waits one interval
        let anchor = lastRun > now ? now : lastRun  // skew guard, matches nextFire
        return now >= anchor.addingTimeInterval(interval)
    }
}

// MARK: - Tick outcome

/// What `Scheduler.tick()` decided. The scheduler performs ONLY the bookkeeping
/// (stamping `lastFire`); actually running the engine is the caller's job —
/// call `EngineClient.run(...)` when you get `.fire`.
enum TickDecision: Equatable {
    /// Schedule is switched off; nothing happened.
    case disabled
    /// Not yet due; carries the instant of the next fire.
    case waiting(nextFire: Date)
    /// DUE NOW — `lastFire` has already been stamped, so repeated ticks
    /// (onAppear + Timer racing) cannot double-fire. Run the engine.
    case fire(scheduledFor: Date)
}

// MARK: - Observable shell

/// Observable scheduler facade. Production code uses `Scheduler.shared`;
/// tests may construct instances over a throwaway `UserDefaults` suite.
final class Scheduler: ObservableObject {

    /// Process-wide scheduler backed by `UserDefaults.standard`.
    static let shared = Scheduler()

    // MARK: Published state

    /// Current schedule settings. Assignments persist immediately and are
    /// re-clamped via `didSet` (mirrors the AppPreferences pattern).
    @Published private(set) var config: ScheduleConfig {
        didSet {
            let clamped = ScheduleConfig(isEnabled: config.isEnabled,
                                         intervalMinutes: ScheduleConfig.clampedInterval(config.intervalMinutes))
            if clamped != config {
                config = clamped            // converges after one re-entry
            } else if oldValue != config {
                persist(config)
            }
            recomputeNextFire()
        }
    }

    /// Convenience flag mirrored from `config.isEnabled` for toggle bindings.
    var isEnabled: Bool {
        get { config.isEnabled }
        set { config.isEnabled = newValue }
    }

    /// Minutes between runs, clamped on assignment.
    var intervalMinutes: Int {
        get { config.intervalMinutes }
        set { config.intervalMinutes = newValue }
    }

    /// Latest computed instant of the next fire (nil while disabled).
    /// Recomputed by `recomputeNextFire()` on every config change and tick;
    /// callers wanting wall-clock freshness can call `tick()` or `refresh()`.
    @Published private(set) var nextFireDate: Date?

    // MARK: Storage

    private let defaults: UserDefaults

    /// Injectable backing store for tests/proof snippets; production uses
    /// `shared`, which reads `UserDefaults.standard`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let enabled = (defaults.object(forKey: ScheduleKeys.enabled) as? Bool)
            ?? ScheduleFallbacks.enabled
        let interval = (defaults.object(forKey: ScheduleKeys.intervalMinutes) as? Int)
            .map(ScheduleConfig.clampedInterval) ?? ScheduleFallbacks.intervalMinutes
        _config = Published(initialValue: ScheduleConfig(isEnabled: enabled,
                                                         intervalMinutes: interval))
        _nextFireDate = Published(initialValue: nil)
        recomputeNextFire()
    }

    // MARK: Reading persisted state

    /// Last recorded fire time, or nil if the schedule never fired.
    var lastFireDate: Date? {
        let epoch = defaults.double(forKey: ScheduleKeys.lastFire)
        return epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil
    }

    /// Recompute `nextFireDate` from current config + stored last-fire using
    /// the real clock. Cheap; safe to call often.
    func refresh() {
        recomputeNextFire()
    }

    // MARK: The tick/check entry point

    /// Call this from `.onAppear` and from your recurring Timer.
    ///
    /// Decision table (all evaluated against `now`):
    /// - disabled                       → `.disabled`
    /// - enabled, no anchor yet         → arm (`lastFire = now`), then
    ///                                    `.waiting(nextFire: now + interval)`
    /// - enabled, before the boundary   → `.waiting(nextFire: last + interval)`
    /// - enabled, at/after the boundary → `.fire(...)` and stamp `lastFire`
    ///
    /// Arming matters because the schedule may be switched on by an external
    /// writer (the onboarding step persists enabled/interval directly) with
    /// no `lastFire` on record; without an anchor the due check can never
    /// succeed. Anchoring on first tick preserves the "enabling does NOT
    /// fire instantly" rule while guaranteeing the first fire lands.
    ///
    /// On `.fire` the bookkeeping is done BEFORE returning, so back-to-back
    /// ticks (onAppear racing the Timer) see the fresh stamp and won't
    /// double-fire. The caller still owns triggering the actual measurement
    /// (e.g. `EngineClient().run(mode)`).
    @discardableResult
    func tick(now: Date = Date()) -> TickDecision {
        guard config.isEnabled else {
            nextFireDate = nil
            return .disabled
        }
        var last = lastFireDate
        if last == nil {
            // First cycle ever (or after clearLastFire): anchor it now.
            stampFire(at: now)
            last = now
        }
        if ScheduleMath.isDue(enabled: true, lastRun: last, interval: config.interval, now: now) {
            stampFire(at: now)
            nextFireDate = ScheduleMath.nextFire(lastRun: now, interval: config.interval, now: now)
            return .fire(scheduledFor: now)
        }
        let upcoming = ScheduleMath.nextFire(lastRun: last, interval: config.interval, now: now)
        nextFireDate = upcoming
        return .waiting(nextFire: upcoming)
    }

    /// Record that a fire happened at `at` (epoch seconds; 0 sentinel means
    /// "never"). Exposed so a completed engine run can align the stamp with
    /// reality instead of the tick instant — optional refinement.
    func stampFire(at: Date = Date()) {
        defaults.set(at.timeIntervalSince1970, forKey: ScheduleKeys.lastFire)
    }

    /// Forget the last-fire record (schedule starts a fresh first cycle).
    func clearLastFire() {
        defaults.set(0, forKey: ScheduleKeys.lastFire)
        recomputeNextFire()
    }

    // MARK: Private

    private func persist(_ cfg: ScheduleConfig) {
        defaults.set(cfg.isEnabled, forKey: ScheduleKeys.enabled)
        defaults.set(cfg.intervalMinutes, forKey: ScheduleKeys.intervalMinutes)
    }

    private func recomputeNextFire() {
        guard config.isEnabled else {
            if nextFireDate != nil { nextFireDate = nil }
            return
        }
        let computed = ScheduleMath.nextFire(lastRun: lastFireDate,
                                             interval: config.interval,
                                             now: Date())
        if nextFireDate != computed { nextFireDate = computed }
    }
}
