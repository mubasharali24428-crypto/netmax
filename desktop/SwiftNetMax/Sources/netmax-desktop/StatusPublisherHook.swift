//
//  StatusPublisherHook.swift
//  netmax-desktop
//
//  ALPHA-A4-07 — launch hook: keeps the menu-bar quick-status fresh (wave-3).
//
//  A tiny static bootstrap that wires StatusBarController's publish API to the
//  app lifecycle, so the menu-bar label is correct from launch onward without
//  any per-run call sites. Two responsibilities:
//
//    1. On install, immediately `publish(store:)` so a freshly launched app
//       shows the newest historical measurement instead of a stale key left
//       over from the previous session.
//    2. Observe `.netmaxHistoryDidChange` (posted by HistoryStore mutators and
//       by RunPostProcessor.process as its step 3) and re-publish from the
//       store on each event. Once installed this is the single point where
//       completed runs reach the menu bar: A4-02's pipeline appends the
//       record, publishes once, then posts the change notification — this
//       observer picks it up with no extra wiring.
//
//  ── ONE-LINE INTEGRATION FOR App.swift (owner: wiring lane — do not edit here) ──
//
//      private struct NetMaxDesktopApp: App {
//          init() { StatusPublisherHook.install() }   // ← add this line
//          …
//      }
//
//  Call exactly once per process; the guard makes repeat calls no-ops (safe
//  against App re-init in previews/tests). Install is cheap and non-blocking:
//  the startup publish reads one small JSONL file on the main thread, the same
//  cost as a one-shot history-file refresh.
//
//  Contract notes (mirrors StatusBarController.swift):
//  - Reads history ONLY through the P2 API surface
//    (`HistoryStore.shared.loadAll()`); never touches the history file directly.
//  - Writes ONLY through `StatusBarController.publish`, i.e. the `netmax.status.*`
//    keys; never touches the P1 `netmax.prefs.*` namespace owned by L3-C.
//

import Foundation

/// Launch bootstrap that keeps the published menu-bar status in sync with the
/// shared history store (wave-3, ALPHA-A4-07).
enum StatusPublisherHook {

    /// Posted by `install()` right after it has finished wiring (guard passed,
    /// startup publish done, observer registered). Object is `nil`. Lets tests
    /// and future callers await readiness without polling.
    static let didInstallNotification =
        Notification.Name("netmax.status.hook.didInstall")

    // MARK: Install

    /// Wire the hook up. Idempotent: the first call wins, later calls are
    /// silent no-ops. See header comment for the one-line App init integration.
    /// Injectable store/defaults keep self-checks hermetic (no `.standard`
    /// traffic); production callers omit both.
    @discardableResult
    static func install(store: HistoryStore = .shared,
                        defaults: UserDefaults = .standard) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !installed else {
            #if DEBUG
            print("[StatusPublisherHook] install() ignored: already installed")
            #endif
            return false
        }
        installed = true

        // Startup publish: newest record wins; empty history clears stale keys
        // (publish(record: nil) routes to clear()).
        publishNow(store: store, defaults: defaults)

        changeToken = NotificationCenter.default.addObserver(
            forName: .netmaxHistoryDidChange, object: nil, queue: .main
        ) { [store, defaults] _ in
            publishNow(store: store, defaults: defaults)
        }

        NotificationCenter.default.post(name: didInstallNotification, object: nil)
        return true
    }

    /// True once `install()` has succeeded in one call in this process.
    static var isInstalled: Bool { installed }

    // MARK: Internals

    private static var installed = false
    private static var changeToken: NSObjectProtocol?

    /// One republish cycle: read through the store's P2 surface and hand the
    /// result to StatusBarController. Injectable store/defaults/now keep the
    /// self-check below deterministic.
    ///
    /// "Newest" is the LAST record in file order, not `max { $0.ts < $1.ts }`:
    /// `HistoryRecord.ts` has second granularity, so two runs in the same
    /// second tie on `ts`, and the tie would resurrect the older run's metric
    /// right after RunPostProcessor published the fresh one.
    private static func publishNow(store: HistoryStore,
                                   now: Date = Date(),
                                   defaults: UserDefaults = .standard) {
        StatusBarController.publish(
            record: store.loadAll().last,
            now: now, defaults: defaults)
    }
}

#if DEBUG
// MARK: - Offline self-checks (house style: plain enum, failure count)
//
// Exercised from a /tmp snippet (see RunPostProcessorSelfCheck): compile the
// snippet against this package's built objects and run it. Call runAll() ON
// the main thread — install() asserts main-queue, and the notification steps
// pump the main run loop inline (no nested-runloop tricks).

enum StatusPublisherHookSelfCheck {

    @discardableResult
    static func runAll(now: Date = Date()) -> Int {
        var failures = 0
        func check(_ what: @autoclosure () -> String, _ ok: Bool) {
            if !ok { print("[StatusPublisherHookSelfCheck] FAIL: \(what())") }
            failures += ok ? 0 : 1
        }

        let suite = "netmax.statuspublisherhook.selfcheck"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        // Fresh injectable store in a throwaway file; shared store untouched.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("netmax-statuspublisherhook-selfcheck-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(fileURL: dir.appendingPathComponent("history.jsonl"))

        // Post .netmaxHistoryDidChange exactly like production does
        // (RunPostProcessor step 3): async on the main queue…
        func fireChangeOnMainQueue() {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .netmaxHistoryDidChange,
                                                object: nil)
            }
        }
        // …and settle it by spinning the main run loop until the hook's
        // re-publish has actually landed in `defaults` (bounded; no hang).
        // In a bare CLI the main queue only drains while that run loop runs.
        @discardableResult
        func settleMainQueue(until done: () -> Bool, maxSpins: Int = 200) -> Bool {
            var ok = false
            for _ in 0..<maxSpins where !ok {
                RunLoop.main.run(mode: .default,
                                 before: Date().addingTimeInterval(0.005))
                ok = done()
            }
            return ok
        }

        // 1) Startup publish: install() publishes current history to the
        //    injected defaults; empty store clears stale keys first.
        check("install returned true",
              StatusPublisherHook.install(store: store, defaults: defaults))
        check("install idempotent",
              !StatusPublisherHook.install(store: store, defaults: defaults))
        check("empty history cleared label",
              defaults.string(forKey: StatusBarController.labelKey) == nil)

        // 2) Notification re-publish: append + post + settle → newest wins.
        store.append(mode: "turbo", params: [:], raw: #"{"mbps": 42.5}"#)
        fireChangeOnMainQueue()
        check("label reflects appended record",
              settleMainQueue {
                  defaults.string(forKey: StatusBarController.labelKey)?
                      .contains("42.5") == true
              })

        // 3) A newer record displaces it on the next change event.
        store.append(mode: "baseline", params: [:], raw: #"{"mbps": 99}"#)
        fireChangeOnMainQueue()
        check("newer record displaced older",
              settleMainQueue {
                  defaults.string(forKey: StatusBarController.labelKey)?
                      .contains("99") == true
              })

        // 4) Clearing history empties the published keys again.
        store.clear()
        fireChangeOnMainQueue()
        check("clear emptied label",
              settleMainQueue {
                  defaults.string(forKey: StatusBarController.labelKey) == nil
              })

        return failures
    }
}
#endif
