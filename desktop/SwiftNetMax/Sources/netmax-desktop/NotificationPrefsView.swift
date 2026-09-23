//
//  NotificationPrefsView.swift
//  netmax-desktop
//
//  ALEX-250 wave-1 · ALPHA-A1-05 — notification preferences UI.
//
//  Master notifications toggle plus one toggle per degradation rule,
//  persisted under `netmax.notify.*` UserDefaults keys:
//      netmax.notify.enabled                  Bool, default true
//      netmax.notify.rule.bloatGradeDrop      Bool, default true
//      netmax.notify.rule.packetLossSpike     Bool, default true
//      netmax.notify.rule.successToFailure    Bool, default true
//      netmax.notify.quietStartHour           Int,  default 22  (M6)
//      netmax.notify.quietStartMinute         Int,  default 0
//      netmax.notify.quietEndHour             Int,  default 7
//      netmax.notify.quietEndMinute           Int,  default 30
//
//  Rule identifiers match lane A1-04's `Notifications.swift`
//  (`DegradationAlert.Kind` raw values). Mission-brief name → shipped rule:
//      "grade drop" → bloatGradeDrop · "high loss" → packetLossSpike ·
//      "offline"    → successToFailure (closest shipped rule: a run fails
//      after a successful one — the connection effectively dropped out)
//
//  Pattern source: SettingsView.swift — every control binds through a
//  self-persisting prefs object (never UserDefaults directly from the
//  view), carries an accessibilityLabel (+ hint where the effect isn't
//  obvious), and persists immediately with no Save button, matching macOS
//  settings-pane convention. Storage discipline mirrors AppPreferences.swift
//  (typed Keys/Fallbacks namespaces, load-time reads, injectable defaults).
//
//  This file owns ONLY the preference surface. Delivery (authorization,
//  posting, quiet hours) lives in A1-04's NotificationCoordinator.
//

import SwiftUI

struct NotificationPrefsView: View {

    /// Self-persisting store for all `netmax.notify.*` keys; views bind
    /// here only — direct UserDefaults access stays inside the store,
    /// matching contract P1's discipline.
    @ObservedObject private var prefs = NotificationPreferences.shared

    var body: some View {
        Form {
            master
            rules
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 320)
        .accessibilityIdentifier("notifications.root")
    }

    // MARK: - Master toggle

    private var master: some View {
        Section {
            Toggle("Enable notifications", isOn: $prefs.notificationsEnabled)
                .accessibilityLabel(Text("Enable notifications"))
                .accessibilityHint(Text("Master switch. When off, no notification fires regardless of the individual rules below."))
                .accessibilityIdentifier("notifications.master")
        } header: {
            Text("Notifications")
        } footer: {
            Text(prefs.notificationsEnabled
                 ? "NetMax will alert you when any enabled rule matches."
                 : "Notifications are off — individual rules are kept but ignored.")
        }
    }

    // MARK: - Per-rule toggles

    private var rules: some View {
        Section {
            ruleRow(
                title: "Grade drop",
                subtitle: "Bufferbloat grade falls ≥ 2 letters between runs (e.g. B → D).",
                isOn: $prefs.gradeDropEnabled,
                kind: .bloatGradeDrop,
                hint: "Alerts when a run's bufferbloat grade drops sharply compared to the previous run."
            )
            ruleRow(
                title: "High loss",
                subtitle: "Packet loss climbs above the healthy 3% threshold.",
                isOn: $prefs.highLossEnabled,
                kind: .packetLossSpike,
                hint: "Alerts when measured packet loss crosses the high-loss threshold."
            )
            ruleRow(
                title: "Run failed",
                subtitle: "A measurement fails right after a successful one.",
                isOn: $prefs.failureEnabled,
                kind: .successToFailure,
                hint: "Alerts when the connection appears to drop out — a failed run following a successful one."
            )
        } header: {
            Text("Alert Rules")
        } footer: {
            Text("Rules apply to every measurement while the master switch is on.")
        }
        .disabled(!prefs.notificationsEnabled)
        .opacity(prefs.notificationsEnabled ? 1 : 0.55)
    }

    /// Standard row for a toggleable rule: title + one-line effect, bound
    /// toggle on the trailing edge.
    private func ruleRow(
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        kind: DegradationAlert.Kind,
        hint: String
    ) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(hint))
        .accessibilityIdentifier("notifications.rule.\(kind.rawValue)")
    }
}

// MARK: - Persistence (netmax.notify.*)

/// Owns every `netmax.notify.*` UserDefaults key. Mirrors the
/// AppPreferences pattern: @Published mirrors persist back on change;
/// missing keys fall back to the documented defaults at init.
///
/// Consumers (e.g. NotificationCoordinator filtering before posting) should
/// ask `isEnabled(_:)` rather than reading UserDefaults directly.
final class NotificationPreferences: ObservableObject {

    static let shared = NotificationPreferences()

    // MARK: Keys — exact spellings, part of the wave-1 contract.
    // Suffixes are the raw values of DegradationAlert.Kind (A1-04).

    enum Keys {
        static let enabled          = "netmax.notify.enabled"
        static let bloatGradeDrop   = "netmax.notify.rule.bloatGradeDrop"
        static let packetLossSpike  = "netmax.notify.rule.packetLossSpike"
        static let successToFailure = "netmax.notify.rule.successToFailure"
        // M6 — quiet-hours window (local wall clock; may wrap midnight).
        static let quietStartHour   = "netmax.notify.quietStartHour"
        static let quietStartMinute = "netmax.notify.quietStartMinute"
        static let quietEndHour     = "netmax.notify.quietEndHour"
        static let quietEndMinute   = "netmax.notify.quietEndMinute"

        static func key(for kind: DegradationAlert.Kind) -> String {
            "netmax.notify.rule.\(kind.rawValue)"
        }
    }

    // MARK: Documented fallbacks (used when a key was never written).

    enum Fallbacks {
        static let enabled          = true
        static let bloatGradeDrop   = true
        static let packetLossSpike  = true
        static let successToFailure = true
        // Prior hardcoded window: 22:00 – 07:30.
        static let quietStartHour   = 22
        static let quietStartMinute = 0
        static let quietEndHour     = 7
        static let quietEndMinute   = 30

        static func fallback(for kind: DegradationAlert.Kind) -> Bool { true }
    }

    // MARK: Observed, self-persisting values

    /// Master switch; gates every rule regardless of per-rule state.
    @Published var notificationsEnabled: Bool {
        didSet { persist(notificationsEnabled, key: Keys.enabled) }
    }

    /// Alert when the bufferbloat grade drops ≥ 2 letters between runs.
    @Published var gradeDropEnabled: Bool {
        didSet { persist(gradeDropEnabled, key: Keys.bloatGradeDrop) }
    }

    /// Alert when packet loss crosses the high-loss threshold (> 3%).
    @Published var highLossEnabled: Bool {
        didSet { persist(highLossEnabled, key: Keys.packetLossSpike) }
    }

    /// Alert when a run fails right after a successful one.
    @Published var failureEnabled: Bool {
        didSet { persist(failureEnabled, key: Keys.successToFailure) }
    }

    // MARK: Quiet hours (M6) — 0...23 / 0...59, persisted immediately.

    @Published var quietStartHour: Int {
        didSet { persistHour(quietStartHour, key: Keys.quietStartHour) }
    }

    @Published var quietStartMinute: Int {
        didSet { persistMinute(quietStartMinute, key: Keys.quietStartMinute) }
    }

    @Published var quietEndHour: Int {
        didSet { persistHour(quietEndHour, key: Keys.quietEndHour) }
    }

    @Published var quietEndMinute: Int {
        didSet { persistMinute(quietEndMinute, key: Keys.quietEndMinute) }
    }

    /// Effective window for NotificationCoordinator (may wrap midnight).
    var quietWindow: (start: (hour: Int, minute: Int),
                      end: (hour: Int, minute: Int)) {
        (start: (quietStartHour, quietStartMinute),
         end: (quietEndHour, quietEndMinute))
    }

    // MARK: Setup

    private let defaults: UserDefaults

    /// Injectable backing store for tests/proof snippets; production code
    /// uses `shared`, which reads `UserDefaults.standard`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _notificationsEnabled = Published(initialValue: Self.read(defaults, Keys.enabled, Fallbacks.enabled))
        _gradeDropEnabled     = Published(initialValue: Self.read(defaults, Keys.bloatGradeDrop, Fallbacks.bloatGradeDrop))
        _highLossEnabled      = Published(initialValue: Self.read(defaults, Keys.packetLossSpike, Fallbacks.packetLossSpike))
        _failureEnabled       = Published(initialValue: Self.read(defaults, Keys.successToFailure, Fallbacks.successToFailure))
        _quietStartHour       = Published(initialValue: Self.readInt(defaults, Keys.quietStartHour, Fallbacks.quietStartHour, 0...23))
        _quietStartMinute     = Published(initialValue: Self.readInt(defaults, Keys.quietStartMinute, Fallbacks.quietStartMinute, 0...59))
        _quietEndHour         = Published(initialValue: Self.readInt(defaults, Keys.quietEndHour, Fallbacks.quietEndHour, 0...23))
        _quietEndMinute       = Published(initialValue: Self.readInt(defaults, Keys.quietEndMinute, Fallbacks.quietEndMinute, 0...59))
    }

    // MARK: Helpers for non-UI consumers (delivery layer)

    /// Effective rule state as delivery should evaluate it: master AND rule.
    /// Call before posting an alert of the given kind.
    func isEnabled(_ kind: DegradationAlert.Kind) -> Bool {
        guard notificationsEnabled else { return false }
        switch kind {
        case .bloatGradeDrop:   return gradeDropEnabled
        case .packetLossSpike:  return highLossEnabled
        case .successToFailure: return failureEnabled
        }
    }

    // MARK: Private

    /// Static so the initializer may call it during phase-one setup,
    /// before `self` is fully initialized.
    private static func read(_ defaults: UserDefaults, _ key: String, _ fallback: Bool) -> Bool {
        (defaults.object(forKey: key) as? Bool) ?? fallback
    }

    /// Load-time int read with range pull-back (quiet-hours fields).
    private static func readInt(_ defaults: UserDefaults, _ key: String,
                                _ fallback: Int, _ range: ClosedRange<Int>) -> Int {
        guard let n = defaults.object(forKey: key) as? Int else { return fallback }
        return min(max(n, range.lowerBound), range.upperBound)
    }

    private func persist(_ value: Bool, key: String) {
        if defaults.object(forKey: key) as? Bool != value {
            defaults.set(value, forKey: key)
        }
    }

    private func persistHour(_ value: Int, key: String) {
        let clamped = min(max(value, 0), 23)
        if clamped != value { quietStartOrEndFix(key: key, clamped: clamped); return }
        if defaults.object(forKey: key) as? Int != value {
            defaults.set(value, forKey: key)
        }
    }

    private func persistMinute(_ value: Int, key: String) {
        let clamped = min(max(value, 0), 59)
        if clamped != value { quietStartOrEndFix(key: key, clamped: clamped); return }
        if defaults.object(forKey: key) as? Int != value {
            defaults.set(value, forKey: key)
        }
    }

    /// Re-entry convergence for an out-of-range hour/minute write: map the
    /// key back onto the matching @Published field (didSet re-enters once).
    private func quietStartOrEndFix(key: String, clamped: Int) {
        switch key {
        case Keys.quietStartHour: quietStartHour = clamped
        case Keys.quietStartMinute: quietStartMinute = clamped
        case Keys.quietEndHour: quietEndHour = clamped
        case Keys.quietEndMinute: quietEndMinute = clamped
        default: break
        }
    }
}

#if DEBUG
struct NotificationPrefsView_Previews: PreviewProvider {
    static var previews: some View {
        NotificationPrefsView()
    }
}
#endif
