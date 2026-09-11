//
//  LicenseGate.swift — P2.9–P2.12 offline license gating.
//
//  Design: FREE keeps all current features; PRO adds watch/sentinel alerts,
//  scheduled reports, PDF/ISP report card, exports, deep history. Trial gives
//  PRO for TRIAL_DAYS then a NON-DESTRUCTIVE lockout (data is never deleted or
//  held hostage). Offline validation is structural only (LMS-style 5x4 key);
//  a determined pirate wins — accepted trade-off per project docs. This file
//  only GATES features, it never touches user data. Dev override for the test
//  pipeline: NETMAX_LICENSE_DISABLED=1 (forces Pro) or NETMAX_LICENSE_MODE=pro|free|trial.
//  Time is stored as two fixed-width UTC ISO strings (start+end) so "now < end"
//  is a lexicographic compare — zero date parsing anywhere.
//

import Foundation
import Combine

final class LicenseGate: ObservableObject {

    static let shared = LicenseGate()

    static let TRIAL_DAYS = 14

    static let KEY_PATTERN = #"^[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$"#

    enum Tier: Int, CaseIterable {
        case Free = 0
        case Trial = 1
        case Pro = 2
    }

    enum Feature: Int, CaseIterable {
        case WatchAlerts = 0
        case ScheduledReports = 1
        case PdfReportCard = 2
        case Exports = 3
        case DeepHistory = 4
    }

    enum Keys {
        static let licenseKey    = "netmax.prefs.licenseKey"     // String, "" = none
        static let trialStarted  = "netmax.prefs.trialStartedAt" // String, fixed-width UTC ISO, "" = not started
        static let trialEnds     = "netmax.prefs.trialEndsAt"    // String, fixed-width UTC ISO
    }

    let defaults: UserDefaults

    /// Injected state for tests (mirrors HistoryStore's fileURL injection).
    /// Production passes nothing and reads/persists via UserDefaults.
    init(defaults: UserDefaults = .standard,
         trialStartISO: String = "",
         trialEndISO: String = "") {
        self.defaults = defaults
        let storedKey   = defaults.string(forKey: Keys.licenseKey) ?? ""
        let storedStart = defaults.string(forKey: Keys.trialStarted) ?? ""
        let storedEnd   = defaults.string(forKey: Keys.trialEnds) ?? ""
        _licenseKey = Published(initialValue: storedKey)
        if !trialStartISO.isEmpty {
            _trialStartedAt = Published(initialValue: trialStartISO)
            _trialEndsAt    = Published(initialValue: trialEndISO.isEmpty ? trialStartISO : trialEndISO)
        } else if !storedStart.isEmpty {
            _trialStartedAt = Published(initialValue: storedStart)
            _trialEndsAt    = Published(initialValue: storedEnd)
        } else {
            // First real launch: begin the trial now and stamp both bounds.
            let now = Date()
            _trialStartedAt = Published(initialValue: LicenseGate.iso(now))
            _trialEndsAt    = Published(initialValue: LicenseGate.iso(now.addingTimeInterval(Double(LicenseGate.TRIAL_DAYS) * 86_400)))
        }
    }

    @Published var licenseKey: String {
        didSet { if oldValue != licenseKey { defaults.set(licenseKey, forKey: Keys.licenseKey) } }
    }

    @Published var trialStartedAt: String {
        didSet { if oldValue != trialStartedAt { defaults.set(trialStartedAt, forKey: Keys.trialStarted) } }
    }

    @Published var trialEndsAt: String {
        didSet { if oldValue != trialEndsAt { defaults.set(trialEndsAt, forKey: Keys.trialEnds) } }
    }
// MARK: Tier resolution (pure — testable without a UI)

    static func effectiveTier(_ gate: LicenseGate, now: Date = Date()) -> Tier {
        let mode = ProcessInfo.processInfo.environment["NETMAX_LICENSE_MODE"] ?? ""
        if !mode.isEmpty {
            let m = mode.lowercased()
            if m == "pro"   { return Tier.Pro }
            if m == "trial" { return Tier.Trial }
            return Tier.Free
        }
        if ProcessInfo.processInfo.environment["NETMAX_LICENSE_DISABLED"] == "1" {
            return Tier.Pro
        }
        return gate.resolvedTier(now: now)
    }

    func resolvedTier(now: Date = Date()) -> Tier {
        if !licenseKey.isEmpty && LicenseGate.isWellFormedKey(licenseKey) {
            return Tier.Pro
        }
        return isTrialActive(now: now) ? Tier.Trial : Tier.Free
    }

    /// A tier of Trial or Pro unlocks paid lanes.
    func canUse(_ feature: Feature, now: Date = Date()) -> Bool {
        return LicenseGate.effectiveTier(self, now: now) != Tier.Free
    }

    // MARK: Trial math (pure — lexicographic UTC compare, no parsing)

    static func iso(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return fmt.string(from: date)
    }

    func isTrialActive(now: Date = Date()) -> Bool {
        if trialStartedAt.isEmpty || trialEndsAt.isEmpty {
            return false
        }
        let nowISO = LicenseGate.iso(now)
        return nowISO >= trialStartedAt && nowISO < trialEndsAt
    }

    // MARK: Activation

    /// Validate and persist a key. Returns false on malformed input and
    /// leaves stored state untouched.
    func activate(_ key: String) -> Bool {
        let cleaned = key.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).uppercased()
        if !LicenseGate.isWellFormedKey(cleaned) {
            return false
        }
        licenseKey = cleaned          // @Published persists via didSet
        return true
    }

    func deactivate() {
        licenseKey = ""
    }

    /// Structural check only — honest limitation, documented above.
    static func isWellFormedKey(_ key: String) -> Bool {
        let upper = key.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).uppercased()
        return upper.range(of: LicenseGate.KEY_PATTERN, options: String.CompareOptions.regularExpression) != nil
    }

    // MARK: Persistence plumbing
}