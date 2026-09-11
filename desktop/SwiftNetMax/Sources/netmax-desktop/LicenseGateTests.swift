import Foundation

// Offline unit tests for LicenseGate (contract style mirrors HistoryStoreTests).
//
// Package.swift has no test target (single executable target), so this file
// compiles as a plain enum with static checks (like HistoryStoreTests). The
// executable probe harness lives in scripts/verify_phase1.sh step (f), which
// compiles these sources with a generated main.swift. Bodies convert 1:1 into
// XCTestCase methods if a test target is ever added.

enum LicenseGateTests {

    /// Run all checks; returns number of failures (0 == pass).
    @discardableResult
    static func runAll() -> Int {
        var failures = 0
        let now = Date()

        func freshStore() -> UserDefaults {
            let suite = "netmax.lgprobe." + UUID().uuidString
            let d = UserDefaults(suiteName: suite)!
            d.removePersistentDomain(forName: suite)
            return d
        }

        func check(_ cond: Bool) { failures += cond ? 0 : 1 }

        // Key format: LMS-style 5x4 uppercase alphanumeric.
        check(LicenseGate.isWellFormedKey("ABCD-EF12-GH34-IJ56-KL78"))
        check(LicenseGate.isWellFormedKey("abcd-ef12-gh34-ij56-kl78"))
        check(!LicenseGate.isWellFormedKey("ABCD-EF12-GH34-IJ56-KL7"))
        check(!LicenseGate.isWellFormedKey("ABCD EF12 GH34 IJ56 KL78"))
        check(!LicenseGate.isWellFormedKey(""))

        // Trial window: active inside, expired outside.
        let gActive = LicenseGate(defaults: freshStore(),
            trialStartISO: LicenseGate.iso(now.addingTimeInterval(-3600.0)),
            trialEndISO: LicenseGate.iso(now.addingTimeInterval(6 * 3600.0)))
        check(gActive.isTrialActive(now: now))
        check(gActive.resolvedTier(now: now) == LicenseGate.Tier.Trial)

        let gExpired = LicenseGate(defaults: freshStore(),
            trialStartISO: LicenseGate.iso(now.addingTimeInterval(-10 * 86400.0)),
            trialEndISO: LicenseGate.iso(now.addingTimeInterval(-9 * 86400.0)))
        check(!gExpired.isTrialActive(now: now))
        check(gExpired.resolvedTier(now: now) == LicenseGate.Tier.Free)
        check(!gExpired.canUse(LicenseGate.Feature.ScheduledReports, now: now))

        // Activation: valid key -> Pro + persisted; bad key -> untouched.
        let gPro = LicenseGate(defaults: freshStore(),
            trialStartISO: LicenseGate.iso(now.addingTimeInterval(-10 * 86400.0)),
            trialEndISO: LicenseGate.iso(now.addingTimeInterval(-9 * 86400.0)))
        check(gPro.activate("ABCD-EF12-GH34-IJ56-KL78"))
        check(gPro.licenseKey == "ABCD-EF12-GH34-IJ56-KL78")
        check(gPro.resolvedTier(now: now) == LicenseGate.Tier.Pro)
        check(gPro.canUse(LicenseGate.Feature.PdfReportCard, now: now))

        let g2 = LicenseGate(defaults: freshStore(),
            trialStartISO: LicenseGate.iso(now.addingTimeInterval(-10 * 86400.0)),
            trialEndISO: LicenseGate.iso(now.addingTimeInterval(-9 * 86400.0)))
        check(!g2.activate("nonsense"))
        check(g2.resolvedTier(now: now) == LicenseGate.Tier.Free)

        // Persistence round-trip: a new gate over the SAME store restores Pro.
        let g3 = LicenseGate(defaults: gPro.defaults,
            trialStartISO: LicenseGate.iso(now.addingTimeInterval(-10 * 86400.0)),
            trialEndISO: LicenseGate.iso(now.addingTimeInterval(-9 * 86400.0)))
        check(g3.resolvedTier(now: now) == LicenseGate.Tier.Pro)

        return failures
    }
}