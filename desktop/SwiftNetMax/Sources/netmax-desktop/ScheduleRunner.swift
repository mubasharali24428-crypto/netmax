//
//  ScheduleRunner.swift
//  netmax-desktop
//
//  ALPHA-A4-01 (ALEX-250 wave-3, sub-wave W3c) — the automation engine.
//
//  Owns the recurring Timer that makes schedules actually run. On each tick:
//
//      1. Scheduler.shared.tick(now:) decides (.disabled / .waiting / .fire)
//      2. on .fire → EngineClient().run("boost", ["--seconds", "10"])
//         (same mode + duration as BackgroundRunner's launchd agent, so both
//         automation paths record comparable history lines)
//      3. HistoryStore.append(mode:params:raw:) persists the result
//      4. StatusBarController.publish(store:) refreshes the menu-bar line
//      5. NotificationCoordinator.process(records:) evaluates degradation
//         rules for this run and delivers alerts under its authorization /
//         quiet-hours policy
//
//  Why the Timer lives on RunLoop.main: in this LSUIElement accessory app
//  the process-wide main RunLoop is pumped by AppKit for the entire app
//  lifetime — closing the menu-bar popover or the main window tears down
//  SwiftUI *scenes*, never the run loop itself — so a timer hosted there
//  keeps ticking regardless of UI. All runner state is @MainActor, matching
//  the tick source (main run loop) with the side effects that hop here
//  anyway (NotificationCoordinator).
//
//  ══ INTEGRATION (owner: RootView lane — do not edit here) ═══════════════
//
//  Attach once at App level — NOT inside popover/window content, which can
//  be torn down when its scene closes. In NetMaxDesktopApp (App.swift):
//
//      init() {
//          ScheduleRunner.shared.start()   // skip-if-running guard: safe to call twice
//      }
//
//  …or equivalently as an environment object if that lane prefers binding:
//
//      WindowGroup { … }.environmentObject(ScheduleRunner.shared)
//      MenuBarExtra { … }.environmentObject(ScheduleRunner.shared)
//
//  The singleton keeps running for the process lifetime; stop() is exposed
//  for Settings/tests. Nothing in this file touches App.swift or RootView.swift
//  (hard rule: one new file only).
//

import Foundation

/// Drives `Scheduler` from a repeating Timer and executes fired runs
/// (wave-3 W3c, ALPHA-A4-01). Production code uses `ScheduleRunner.shared`;
/// tests/harnesses inject a fake client + throwaway store/defaults.
@MainActor
final class ScheduleRunner: ObservableObject {

    // MARK: Singleton

    /// Process-wide runner. Attach at App level (see file header): starting
    /// here survives popover closure because the tick Timer lives on the
    /// main RunLoop, which AppKit keeps pumping for the whole process life.
    static let shared = ScheduleRunner()

    // MARK: Tunables

    /// Tick granularity in seconds. Schedule intervals are minute-granular
    /// (5…1440), so a 30 s poll bounds lateness at half a minute without
    /// burning CPU.
    static let tickInterval: TimeInterval = 30

    /// Fixed engine invocation per spec — mirrors BackgroundRunner's agent.
    static let runMode = "boost"
    static let runArgs = ["--seconds", "10"]

    // MARK: Published state (read-only to observers)

    /// True while the repeating timer is armed. UI (Settings/RootView lane)
    /// may bind to this; start()/stop() are the only mutators.
    @Published private(set) var isRunning = false

    /// Last tick decision, kept for diagnostics/debug UI. Updated on every
    /// tick regardless of outcome.
    @Published private(set) var lastDecision: TickDecision?

    /// Instant of the most recent completed scheduled run (diagnostics only;
    /// authoritative state stays in HistoryStore / netmax.schedule.lastFire).
    @Published private(set) var lastRunAt: Date?

    /// True while a scheduled engine run is executing. Re-entry guard: a
    /// long-running measurement must not stack with itself across ticks.
    @Published private(set) var isRunInFlight = false

    // MARK: Collaborators (injectable for tests)

    /// Decision source. Production uses `Scheduler.shared`; harnesses pass
    /// an instance over a throwaway UserDefaults suite.
    nonisolated(unsafe) private let scheduler: Scheduler

    /// History sink. Injected so harnesses assert against an isolated file.
    nonisolated(unsafe) private let store: HistoryStore

    /// Injectable clock so tests drive due-ness deterministically.
    /// nonisolated(unsafe): assigned exactly once in (nonisolated) init,
    /// read-only afterwards — safe, and lets `shared` initialize anywhere.
    nonisolated(unsafe) private let now: () -> Date

    /// Engine boundary. `EngineClient()` is a struct with no state, but
    /// routing through this closure lets the /tmp harness swap a fake in.
    nonisolated(unsafe) private let performRun: (_ mode: String, _ args: [String]) async throws -> String

    /// Notification gate, consulted (on the main actor) after every appended
    /// run. Production reads the user's master switch; harnesses return
    /// false so the UN framework is never constructed headless (a bare CLI
    /// binary has no bundle, and UNUserNotificationCenter.current() aborts).
    nonisolated(unsafe) private let notificationsAllowed: () -> Bool

    // MARK: Timer plumbing

    /// The repeating tick timer. Hosted on RunLoop.main (.common mode so
    /// menu tracking/modal panels never starve a tick); strong-referenced
    /// here so it survives, invalidated by stop().
    private var tickTimer: Timer?

    // MARK: Init

    /// Production entry point is `shared`; parameterized init serves tests.
    nonisolated init(scheduler: Scheduler = .shared,
                     store: HistoryStore = .shared,
                     now: @escaping () -> Date = Date.init,
                     performRun: @escaping (String, [String]) async throws -> String = {
                         try await EngineClient().run($0, args: $1)
                     },
                     notificationsAllowed: @escaping () -> Bool = {
                         NotificationPreferences.shared.notificationsEnabled
                     }) {
        self.scheduler = scheduler
        self.store = store
        self.now = now
        self.performRun = performRun
        self.notificationsAllowed = notificationsAllowed
    }

    deinit {
        // Timer must not fire into a deallocated runner (only reachable in
        // tests; `shared` lives for the process).
        tickTimer?.invalidate()
    }

    // MARK: Lifecycle

    /// Arms the tick timer. Idempotent — repeated calls while running are
    /// no-ops (the skip-if-running guard), so App.init + environment
    /// attachment + any future re-entry all converge safely.
    func start() {
        guard !isRunning, tickTimer == nil else { return }

        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) {
            [weak self] _ in
            // Fires on the main run loop; hop through the actor for the
            // isolated body (cheap, ordered, and version-proof).
            Task { @MainActor [weak self] in self?.tickOnce() }
        }
        // .common mode: ticks continue during menu-bar tracking/modals.
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
        isRunning = true

        // First decision immediately — a schedule enabled while the app was
        // closed shouldn't wait up to 30 s just for the next tick.
        tickOnce()
    }

    /// Disarms the timer. Safe to call repeatedly; a later start() rearms.
    /// An in-flight run finishes — its completion path never touches the
    /// timer.
    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        isRunning = false
    }

    // MARK: One scheduling cycle

    /// A single tick: ask the scheduler what to do, act on it. Also called
    /// directly (no timer) by `.onAppear` integration points and tests —
    /// Scheduler.tick() stamps before returning, so timer/onAppear races
    /// cannot double-fire.
    ///
    /// - Parameter at: injectable instant (tests); production omits it.
    @discardableResult
    func tickOnce(at: Date? = nil) -> TickDecision {
        let decision = scheduler.tick(now: at ?? now())
        lastDecision = decision

        switch decision {
        case .fire(let scheduledFor):
            executeRun(scheduledFor: scheduledFor)
        case .waiting, .disabled:
            break
        }
        return decision
    }

    // MARK: Fire path

    /// Runs the engine off the main actor, appends the result, fans out the
    /// post-run pipeline (menu-bar status + notifications). Failures are
    /// recorded as error-text records so history shows the outage — ModeLab
    /// surfaces errors in its result pane, but a headless schedule has no
    /// visible pane; the failure must land somewhere inspectable.
    private func executeRun(scheduledFor: Date) {
        guard !isRunInFlight else { return }     // never stack measurements
        isRunInFlight = true

        Task { [weak self] in
            guard let self else { return }
            let mode = Self.runMode
            let args = Self.runArgs
            do {
                let raw = try await performRun(mode, args)
                let seconds = args.count >= 2 ? (Int(args[1]) ?? 10) : 10
                appendAndPublish(raw: raw, mode: mode,
                                 params: args.isEmpty ? [:] : ["seconds": seconds])
                self.lastRunAt = Date()
            } catch {
                appendAndPublish(raw: "Error: \(error.localizedDescription)",
                                 mode: mode, params: [:])
            }
            self.isRunInFlight = false
        }
    }

    /// Shared tail for success/failure: persist through P2, refresh the
    /// menu-bar line, then evaluate degradation alerts. The notification
    /// leg is gated by the user's `netmax.notify.enabled` master switch
    /// (same contract A4-02's RunPostProcessor implements) so a switched-off
    /// user never touches the UN framework at all; ON users get
    /// NotificationCoordinator.process, whose authorization + quiet-hours
    /// policy stays authoritative.
    private func appendAndPublish(raw: String, mode: String, params: [String: Int]) {
        store.append(mode: mode, params: params, raw: raw)
        StatusBarController.publish(store: store)
        WifiEventEmitter.captureNow() // timeline enrichment: wifi events around this run

        let records = store.loadAll()
        Task { @MainActor [records, notificationsAllowed] in
            // Gate first: only an opted-in user ever reaches
            // NotificationCoordinator (whose lazy .shared would otherwise
            // construct the UN framework).
            guard notificationsAllowed() else { return }
            await NotificationCoordinator.shared.process(records: records)
        }
    }
}

#if DEBUG
// MARK: - Offline self-checks (house style: plain enum, failure count)
// Exercised from a /tmp snippet; see RunPostProcessorSelfCheck precedent.

enum ScheduleRunnerSelfCheck {

    /// MainActor-isolated because tickOnce/isRunInFlight are; driven from a
    /// top-level `MainActor.assumeIsolated` hop in the /tmp harness.
    @MainActor
    @discardableResult
    static func runAll() -> Int {
        var failures = 0

        // Isolated fixtures: throwaway defaults suite, temp history file.
        let suite = "netmax.runner.selfcheck"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("netmax.runner.selfcheck.\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(fileURL: dir.appendingPathComponent("history.jsonl"))

        let scheduler = Scheduler(defaults: defaults)
        let fakeRaw = #"{"mbps": 88.5}"#
        let runner = ScheduleRunner(
            scheduler: scheduler,
            store: store,
            performRun: { mode, args in
                precondition(mode == "boost" && args == ["--seconds", "10"],
                             "runner must invoke boost --seconds 10")
                return fakeRaw
            },
            // Headless-safe: never construct the UN framework from a bare
            // CLI binary (no bundle ⇒ UNUserNotificationCenter aborts).
            notificationsAllowed: { false })

        // 1) Disabled → .disabled, no run, no record.
        failures += (runner.tickOnce(at: t(0)) == TickDecision.disabled) ? 0 : 1
        failures += store.loadAll().isEmpty ? 0 : 1

        // 2) Enabled, first-ever tick arms the anchor (does NOT fire).
        //    NOTE: Scheduler caches config at init — drive state through its
        //    API (persists AND updates the cached config); raw defaults
        //    writes post-init would be invisible until relaunch.
        scheduler.isEnabled = true
        scheduler.intervalMinutes = 5
        failures += matchesWaiting(runner.tickOnce(at: t(0))) ? 0 : 1
        failures += store.loadAll().isEmpty ? 0 : 1

        // 3) Before the boundary → still waiting, no record.
        failures += matchesWaiting(runner.tickOnce(at: t(120))) ? 0 : 1

        // 4) At the boundary → fires exactly once; back-to-back tick sees
        //    waiting (stamp-before-return contract prevents double-fire).
        failures += matchesFired(runner.tickOnce(at: t(300))) ? 0 : 1
        waitInFlight(runner)
        failures += (store.loadAll().count == 1) ? 0 : 1
        failures += matchesWaiting(runner.tickOnce(at: t(300))) ? 0 : 1
        failures += (store.loadAll().count == 1) ? 0 : 1

        // 5) The appended record carries mode boost, params seconds=10,
        //    and the fake payload verbatim (tick→fire→append proven end-to-end).
        if let rec = store.loadAll().first {
            failures += (rec.mode == "boost") ? 0 : 1
            failures += (rec.params == ["seconds": 10]) ? 0 : 1
            failures += (rec.resultRaw == fakeRaw) ? 0 : 1
        } else { failures += 1 }

        return failures
    }

    // Fixed epoch far from DST edges: 2026-06-15 12:00:00 UTC.
    private static func t(_ offsetSeconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_781_822_400 + offsetSeconds)
    }

    private static func matchesWaiting(_ d: TickDecision) -> Bool {
        if case .waiting = d { return true }
        return false
    }
    private static func matchesFired(_ d: TickDecision) -> Bool {
        if case .fire = d { return true }
        return false
    }

    /// Give an in-flight fire task time to land its append (bounded pump of
    /// the main run loop so the awaiting task can resume; the fake client
    /// completes almost immediately on the cooperative pool).
    @MainActor
    private static func waitInFlight(_ runner: ScheduleRunner, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while runner.isRunInFlight && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        Thread.sleep(forTimeInterval: 0.05)   // let append/publish drain
    }
}
#endif
