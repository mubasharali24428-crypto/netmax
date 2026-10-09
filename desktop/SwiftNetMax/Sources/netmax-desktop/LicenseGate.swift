//
//  LicenseGate.swift — P2.9–P2.12 offline license gating + hardware-bound trials.
//
//  Design: FREE keeps all current features; PRO adds watch/sentinel alerts,
//  scheduled reports, PDF/ISP report card, exports, deep history. Trial gives
//  PRO for TRIAL_DAYS then a NON-DESTRUCTIVE lockout (data is never deleted or
//  held hostage).
//
//  TRIAL HARDENING (2026-10-09): the old UserDefaults-only trial window was
//  deletable for infinite re-trials (same hole as IDM's registry keys).
//  Trials are now hardware-bound and server-recorded:
//    - Machine fingerprint = SHA-256 of the hardware UUID (IOPlatformUUID);
//      only the hash ever leaves the machine (MachineFingerprint.swift).
//    - startTrial requires a successful POST /v1/trial/activate. The server
//      stamps the window (server clock authoritative) and returns an HMAC
//      token binding (fingerprint, start, end).
//    - The token is verified locally, so any edit of the cached window breaks
//      the signature (tamper-evident cache). It is stored in the Keychain
//      (service "netmax.trial", ThisDeviceOnly — never roams via iCloud),
//      NOT in UserDefaults.
//    - Server is source of truth when online (revalidateTrial); offline, the
//      cached window is honored with a 72h grace cap past its end, then Free
//      until online revalidation succeeds.
//    - A fingerprint that already consumed a trial stays Free with
//      trialDenialReason = "trial_already_consumed" ("trial already used on
//      this Mac"). VM-suspected machines are denied server-side
//      (trial_server DENY_VM_TRIALS).
//    - Legacy local-only windows (no valid token) are migrated away at
//      launch — non-destructive — so their owners get exactly one
//      server-bound trial.
//  Accepted trade-off (unchanged): a determined attacker extracting the
//  embedded HMAC secret from the binary can mint tokens — the server remains
//  authoritative whenever online. This file only GATES features, it never
//  touches user data.
//
//  Dev override for the test pipeline: NETMAX_LICENSE_DISABLED=1 (forces Pro)
//  or NETMAX_LICENSE_MODE=pro|free|trial.
//  Time is stored as two fixed-width UTC ISO strings (start+end) so "now < end"
//  is a lexicographic compare — zero date parsing in the hot path.
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
        static let licenseKey    = "netmax.prefs.licenseKey"       // String, "" = none
        static let trialStarted  = "netmax.prefs.trialStartedAt"   // String, fixed-width UTC ISO, "" = not started
        static let trialEnds     = "netmax.prefs.trialEndsAt"      // String, fixed-width UTC ISO
        static let trialDenial   = "netmax.prefs.trialDenialReason" // String, "" = none
    }

    let defaults: UserDefaults
    let trialRegistry: TrialRegistryClient
    let tokenStore: TrialTokenStore

    /// Transient: the last startTrial could not reach the server. Not persisted;
    /// the UI offers a retry.
    @Published var trialNeedsConnection = false

    /// Injected state for tests (mirrors HistoryStore's fileURL injection).
    /// Production passes nothing: UserDefaults + live registry client +
    /// Keychain token store.
    ///
    /// H8 fix: the trial is NEVER auto-started here. An empty stored window
    /// stays empty (`isTrialActive` → false → Free) until the user presses
    /// "Start trial" (or a future gated-feature first use calls `startTrial`).
    init(defaults: UserDefaults = .standard,
         trialStartISO: String = "",
         trialEndISO: String = "",
         trialRegistry: TrialRegistryClient = TrialRegistryClient(),
         tokenStore: TrialTokenStore = KeychainTrialTokenStore()) {
        self.defaults = defaults
        self.trialRegistry = trialRegistry
        self.tokenStore = tokenStore
        let storedKey    = defaults.string(forKey: Keys.licenseKey) ?? ""
        let storedDenial = defaults.string(forKey: Keys.trialDenial) ?? ""
        _licenseKey = Published(initialValue: storedKey)
        _trialDenialReason = Published(initialValue: storedDenial)

        var start: String
        var end: String
        if !trialStartISO.isEmpty {
            start = trialStartISO
            end = trialEndISO.isEmpty ? trialStartISO : trialEndISO
        } else {
            start = defaults.string(forKey: Keys.trialStarted) ?? ""
            end = defaults.string(forKey: Keys.trialEnds) ?? ""
        }
        // Migration: a cached window with no valid server token is a legacy
        // local-only trial (the old hole). Drop it — non-destructive — so the
        // owner gets exactly one server-bound trial via startTrial.
        var migrated = false
        if !start.isEmpty && !Self.tokenIsValid(tokenStore: tokenStore,
                                                secret: trialRegistry.hmacSecret,
                                                start: start, end: end) {
            start = ""
            end = ""
            migrated = true
        }
        _trialStartedAt = Published(initialValue: start)
        _trialEndsAt = Published(initialValue: end)
        if migrated {
            // didSet does not fire during init — persist explicitly.
            defaults.set("", forKey: Keys.trialStarted)
            defaults.set("", forKey: Keys.trialEnds)
        }
    }

    /// Hardware-bound 14-day trial start (H8: never auto-starts — explicit
    /// user action only). Requires a successful server activation: the server
    /// stamps the window (server clock authoritative) and the token is cached
    /// in the Keychain. One shot: once a server-bound window exists, or the
    /// server denies this Mac, further calls are no-ops. Offline (or
    /// unconfigured server) → stays Free with trialNeedsConnection set.
    /// Never touches user data.
    func startTrial(now: Date = Date()) {
        guard trialStartedAt.isEmpty else { return }
        guard trialDenialReason.isEmpty else { return }
        trialNeedsConnection = false
        guard let fp = MachineFingerprint.fingerprint() else {
            trialNeedsConnection = true
            return
        }
        switch trialRegistry.activate(fingerprint: fp, vmSuspected: VMDetector.isVirtualMachine()) {
        case .activated(let start, let end, let token):
            trialStartedAt = start
            trialEndsAt = end
            tokenStore.save(start: start, end: end, token: token)
            trialDenialReason = ""
        case .denied(let reason):
            trialDenialReason = reason.rawValue
        case .unreachable:
            trialNeedsConnection = true
        }
    }

    /// Best-effort online revalidation. The server is source of truth: if it
    /// reports the trial over/consumed, the local window is dropped
    /// (non-destructive — data untouched). Returns true if local state changed.
    /// Callers that must not block the main thread: refreshTrialStatusInBackground.
    @discardableResult
    func revalidateTrial() -> Bool {
        guard let fp = MachineFingerprint.fingerprint(),
              let bundle = tokenStore.load() else { return false }
        return applyTrialStatus(trialRegistry.status(fingerprint: fp, token: bundle.token))
    }

    /// Non-blocking revalidation for UI call sites (e.g. Settings onAppear).
    /// Network on a utility queue, state mutations back on main.
    func refreshTrialStatusInBackground() {
        guard let fp = MachineFingerprint.fingerprint(),
              let bundle = tokenStore.load() else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let outcome = self.trialRegistry.status(fingerprint: fp, token: bundle.token)
            DispatchQueue.main.async { _ = self.applyTrialStatus(outcome) }
        }
    }

    private func applyTrialStatus(_ outcome: TrialStatusOutcome) -> Bool {
        switch outcome {
        case .current(let start, let end, _):
            var changed = false
            if trialStartedAt != start { trialStartedAt = start; changed = true }
            if trialEndsAt != end { trialEndsAt = end; changed = true }
            return changed
        case .unknownOrConsumed:
            // Server has no record (or rejected the token): drop the local
            // window. Denial is NOT latched — a later startTrial lets the
            // server decide (already-consumed → denied there).
            if !trialStartedAt.isEmpty || !trialEndsAt.isEmpty {
                trialStartedAt = ""
                trialEndsAt = ""
                tokenStore.clear()
                return true
            }
            return false
        case .unreachable:
            return false
        }
    }

    /// The cached window is server-bound only if the Keychain token matches
    /// this machine's fingerprint and the exact cached bounds.
    static func tokenIsValid(tokenStore: TrialTokenStore, secret: String, start: String, end: String) -> Bool {
        guard let fp = MachineFingerprint.fingerprint(),
              let bundle = tokenStore.load(),
              bundle.start == start, bundle.end == end, !bundle.token.isEmpty else {
            return false
        }
        return TrialToken.verify(token: bundle.token, fingerprint: fp,
                                 start: start, end: end, secret: secret)
    }

    func hasValidTrialToken() -> Bool {
        Self.tokenIsValid(tokenStore: tokenStore, secret: trialRegistry.hmacSecret,
                          start: trialStartedAt, end: trialEndsAt)
    }

    /// User-facing copy for a persisted denial reason, nil when no denial.
    static func trialDenialMessage(for reason: String) -> String? {
        switch reason {
        case TrialDenialReason.alreadyConsumed.rawValue:
            return "Trial already used on this Mac — enter a key for Pro"
        case TrialDenialReason.vmNotAllowed.rawValue:
            return "Trials aren't available on virtual machines — enter a key for Pro"
        default:
            return nil
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

    @Published var trialDenialReason: String {
        didSet { if oldValue != trialDenialReason { defaults.set(trialDenialReason, forKey: Keys.trialDenial) } }
    }
// MARK: Tier resolution (pure — testable without a UI)

    static func effectiveTier(_ gate: LicenseGate, now: Date = Date()) -> Tier {
        #if DEBUG
        // Dev/test override only — release builds ignore env entirely (H8).
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
        #endif
        return gate.resolvedTier(now: now)
    }

    func resolvedTier(now: Date = Date()) -> Tier {
        if !licenseKey.isEmpty && LicenseGate.isWellFormedKey(licenseKey) {
            return Tier.Pro
        }
        return isServerTrialActive(now: now) ? Tier.Trial : Tier.Free
    }

    /// A tier of Trial or Pro unlocks paid lanes.
    ///
    /// M10: tiers are all-or-nothing — `feature` is intentionally unused;
    /// every `Feature` case checks the same tier (Free blocks all paid
    /// features; Trial/Pro unlock all of them). Per-feature policy is not
    /// implemented.
    func canUse(_ feature: Feature, now: Date = Date()) -> Bool {
        return LicenseGate.effectiveTier(self, now: now) != Tier.Free
    }

    // MARK: Trial math (pure — lexicographic UTC compare, no parsing in hot path)

    static func iso(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return fmt.string(from: date)
    }

    /// Parses the fixed-width UTC format produced by `iso(_:)`. Used only for
    /// the offline-grace computation, never in the hot compare path.
    static func dateFromISO(_ s: String) -> Date? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return fmt.date(from: s)
    }

    /// Pure window math (kept for tests/UI). Tier resolution uses
    /// `isServerTrialActive`, which additionally requires a valid token.
    func isTrialActive(now: Date = Date()) -> Bool {
        if trialStartedAt.isEmpty || trialEndsAt.isEmpty {
            return false
        }
        let nowISO = LicenseGate.iso(now)
        return nowISO >= trialStartedAt && nowISO < trialEndsAt
    }

    /// Server-bound trial check: valid token for THIS machine and the exact
    /// cached window, and now inside the window — or inside the 72h offline
    /// grace past its end (then Free until an online revalidation succeeds).
    func isServerTrialActive(now: Date = Date()) -> Bool {
        guard hasValidTrialToken() else { return false }
        let nowISO = LicenseGate.iso(now)
        if nowISO < trialEndsAt { return true }
        guard let endDate = LicenseGate.dateFromISO(trialEndsAt) else { return false }
        let graceEndISO = LicenseGate.iso(endDate.addingTimeInterval(TrialRegistryClient.offlineGraceInterval))
        return nowISO < graceEndISO
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
