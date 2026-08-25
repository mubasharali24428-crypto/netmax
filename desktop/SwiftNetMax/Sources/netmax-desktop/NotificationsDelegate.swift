//
//  NotificationsDelegate.swift
//  netmax-desktop
//
//  W13B TEAM-UB / UB-5 (S-019 + S-061 + S-100).
//
//  Three deliverables live here:
//
//    • NotificationsDelegate — UNUserNotificationCenter delegate installed
//      ONCE at app init (see the cross-lane seam note below). Tapping a
//      NetMax notification activates the app, raises the main window when
//      one exists, and routes to the RELEVANT TAB by writing the exact
//      persisted selection key `netmax.state.lastTab` that MainTabView's
//      TabView binding reads — @AppStorage picks up the external write live
//      in every open window — and additionally posting
//      `openTabNotification` so programmatic listeners can react too.
//
//    • CROSS-LANE SEAM (documented per mission rules): installing the
//      delegate requires a process-start hook, and the only such hook is
//      NetMaxDesktopApp.init() (App.swift). That file gained exactly ONE
//      line — `NotificationsDelegate.install()` — mirroring the existing
//      StatusPublisherHook.install() pattern. No other App.swift changes.
//
//    • WhatsNew — pure model behind the "What's New" sheet: compares the
//      persisted `netmax.whatsNew.seenVersion` against the bundle version;
//      a mismatch means "show highlights once". The sheet itself is hosted
//      by DashboardCardsView (TEAM-UB-owned) so the banner surfaces on the
//      landing tab without editing unowned shell files.
//

import AppKit
import Foundation
import UserNotifications

// MARK: - Delegate

/// Handles notification taps: bring the app forward, land on the relevant
/// tab. Kept deliberately small — all decision logic is static + pure so it
/// is self-checkable offline (see NotificationsTests at the bottom).
final class NotificationsDelegate: NSObject, UNUserNotificationCenterDelegate {

    /// Strong singleton: UNUserNotificationCenter.delegate is weak, so the
    /// delegate must outlive the assignment — hence install() pins `shared`.
    static let shared = NotificationsDelegate()

    /// Persisted-tab key written on tap. EXACTLY the key MainTabView binds
    /// its TabView selection to (`netmax.state.lastTab`), so the write is
    /// the whole routing mechanism.
    static let lastTabKey = "netmax.state.lastTab"

    /// Posted alongside the defaults write (userInfo["tab"] = Int) so other
    /// surfaces can respond to a notification-tap navigation.
    static let openTabNotification = Notification.Name("netmax.notification.openTab")

    /// Install once per process. Called from NetMaxDesktopApp.init().
    static func install() {
        UNUserNotificationCenter.current().delegate = shared
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Tap → route. Completion-handler form (not the async shim) keeps the
    /// conformance valid on every SDK this package builds against.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler:
                                    @escaping () -> Void) {
        let tab = Self.tab(
            forIdentifier: response.notification.request.identifier)
        DispatchQueue.main.async {
            Self.bringAppForward(openingTab: tab)
            completionHandler()
        }
    }

    /// Present banners even while the app is frontmost (degradation alerts
    /// are worth seeing mid-run; silence would hide the very signal the
    /// notification rules exist for).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // MARK: Routing (pure / static)

    /// Map a posted notification identifier onto the tab that explains it.
    /// Degradation alerts cite recent RUNS → History (tab 2, the store of
    /// past runs). Unknown/foreign identifiers route nowhere (nil): the app
    /// still comes forward, but never guesses a destination.
    static func tab(forIdentifier identifier: String) -> Int? {
        guard identifier.hasPrefix("netmax.degradation.") else { return nil }
        // Every degradation kind (bloatGradeDrop / packetLossSpike /
        // successToFailure) points at History.
        return 2
    }

    /// Activate the app, raise the main window when present, and navigate
    /// to `tab` when one is known. Runs on the main thread (callers ensure).
    static func bringAppForward(openingTab tab: Int?) {
        NSApp.activate(ignoringOtherApps: true)

        // Raise an existing NetMax main window if there is one; when the
        // app runs menu-bar-only (launchWindow off) there is nothing to
        // raise — the popover reopens on next click, already on the tab.
        if let window = NSApp.windows.first(where: {
            $0.isVisible && $0.title == "NetMax"
        }) {
            window.makeKeyAndOrderFront(nil)
        }

        guard let tab else { return }
        // 1) The persisted-selection write: @AppStorage-bound views update
        //    live from this external change.
        UserDefaults.standard.set(tab, forKey: lastTabKey)
        // 2) The explicit post for programmatic listeners.
        NotificationCenter.default.post(name: openTabNotification,
                                        object: nil,
                                        userInfo: ["tab": tab])
    }
}

// MARK: - What's New model (S-061)

/// Pure model for the once-per-version "What's New" sheet.
enum WhatsNew {

    struct Entry: Equatable, Identifiable {
        let title: String
        let detail: String
        var id: String { title }
    }

    /// Persisted marker of the last version whose highlights were shown.
    static let seenVersionKey = "netmax.whatsNew.seenVersion"

    /// Current display version, e.g. "1.4 (82)". Dev builds without a
    /// stamped Info.plist read "dev" — deterministic, never crashes.
    static var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (version, build) {
        case let (v?, b?): return "\(v) (\(b))"
        case let (v?, nil): return v
        default: return "dev"
        }
    }

    /// Show the sheet exactly when the stored marker differs from now
    /// (first launch ever included). Pure over injected values.
    static func shouldShow(seen: String, current: String = WhatsNew.currentVersion) -> Bool {
        seen != current
    }

    /// This release's highlights, in reading order. Honest wording: each
    /// entry names what changed, nothing more.
    static let highlights: [Entry] = [
        Entry(title: "Presets & sequences",
              detail: "Save your favorite mode + parameters by name, and chain boost → bloat in one run."),
        Entry(title: "Monthly Summary PDF",
              detail: "Reports gains a last-30-days card — tests, average speed, worst grade — exportable as PDF."),
        Entry(title: "Compare runs",
              detail: "Pick any two past runs in History and see their metrics side by side."),
        Entry(title: "Week-over-week deltas",
              detail: "Dashboard cards now show how this week compares to last, with an hour-of-day coverage strip."),
        Entry(title: "Bulk delete & retention",
              detail: "Multi-select runs to delete, and optionally keep history for N days (archived, never destroyed)."),
    ]
}

#if DEBUG
// MARK: - Offline self-checks (W13B UB-5)
enum NotificationsTests {
    @discardableResult
    static func runAll() -> Int {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            failures += condition ? 0 : 1
            if !condition { print("[NotificationsTests] FAIL: \(name)") }
        }

        // Identifier → tab mapping: degradation alerts land on History,
        // foreign identifiers never guess.
        check(NotificationsDelegate.tab(forIdentifier:
                "netmax.degradation.packetLossSpike.0") == 2,
              "loss alert routes to History")
        check(NotificationsDelegate.tab(forIdentifier:
                "netmax.degradation.bloatGradeDrop.1") == 2,
              "grade alert routes to History")
        check(NotificationsDelegate.tab(forIdentifier: "com.other.app") == nil,
              "foreign identifier routes nowhere")
        check(NotificationsDelegate.tab(forIdentifier: "") == nil,
              "empty identifier routes nowhere")

        // What's New gating: same version hides, new version shows, first
        // launch (empty marker) shows.
        check(!WhatsNew.shouldShow(seen: "1.4 (82)", current: "1.4 (82)"),
              "same version stays quiet")
        check(WhatsNew.shouldShow(seen: "1.3 (70)", current: "1.4 (82)"),
              "version change shows highlights")
        check(WhatsNew.shouldShow(seen: "", current: "anything"),
              "first launch shows highlights")
        check(WhatsNew.shouldShow(seen: "dev", current: "1.0"),
              "dev-to-release transition shows highlights")

        // Highlights exist and each carries both a title and real detail.
        check(WhatsNew.highlights.count >= 3, "highlights list populated")
        check(WhatsNew.highlights.allSatisfy {
            !$0.title.isEmpty && !$0.detail.isEmpty
        }, "every highlight has title and detail")

        return failures
    }
}
#endif
