import Foundation

// Offline unit tests for LicenseGate (contract style mirrors HistoryStoreTests).
//
// Package.swift has a test target (netmax-desktopTests) whose SwiftHarnessTests
// wraps these `runAll()` harnesses so `swift test` and the shell harness share
// the same checks. Bodies convert 1:1 into XCTestCase methods if ever needed.
//
// Trial-hardening tests inject: a fixed hardware UUID (MachineFingerprint),
// stub VM providers, a stub TrialRegistryClient transport, an in-memory token
// store, and a test-known HMAC secret. Injectable state is save/restored.

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

        func check(_ cond: Bool, _ label: String = "") {
            if !cond {
                failures += 1
                if !label.isEmpty { print("FAIL LicenseGateTests: \(label)") }
            }
        }

        // Key format: LMS-style 5x4 uppercase alphanumeric.
        check(LicenseGate.isWellFormedKey("ABCD-EF12-GH34-IJ56-KL78"))
        check(LicenseGate.isWellFormedKey("abcd-ef12-gh34-ij56-kl78"))
        check(!LicenseGate.isWellFormedKey("ABCD-EF12-GH34-IJ56-KL7"))
        check(!LicenseGate.isWellFormedKey("ABCD EF12 GH34 IJ56 KL78"))
        check(!LicenseGate.isWellFormedKey(""))

        // ---- Trial hardening fixtures ----
        let testSecret = "test-secret-xyz"
        let testUUID = "TEST-UUID-0001-AAAA"
        let savedUUID = MachineFingerprint.uuidProvider
        let savedModel = VMDetector.modelProvider
        let savedHV = VMDetector.hypervisorFlagProvider
        MachineFingerprint.uuidProvider = { testUUID }
        VMDetector.modelProvider = { "MacBookPro18,3" }
        VMDetector.hypervisorFlagProvider = { false }
        defer {
            MachineFingerprint.uuidProvider = savedUUID
            VMDetector.modelProvider = savedModel
            VMDetector.hypervisorFlagProvider = savedHV
        }
        let fp = MachineFingerprint.fingerprint()!

        /// Gate whose injected window carries a VALID server token.
        func tokenGate(start: Date, end: Date,
                       registry: TrialRegistryClient? = nil) -> (LicenseGate, InMemoryTrialTokenStore) {
            let s = LicenseGate.iso(start), e = LicenseGate.iso(end)
            let store = InMemoryTrialTokenStore()
            store.save(start: s, end: e,
                       token: TrialToken.make(fingerprint: fp, start: s, end: e, secret: testSecret))
            var reg = registry ?? TrialRegistryClient()
            reg.hmacSecret = testSecret
            let g = LicenseGate(defaults: freshStore(), trialStartISO: s, trialEndISO: e,
                                trialRegistry: reg, tokenStore: store)
            return (g, store)
        }

        func stubClient(status: Int, json: [String: Any]) -> TrialRegistryClient {
            var c = TrialRegistryClient()
            c.baseURLString = "https://trial.test"
            c.hmacSecret = testSecret
            c.appVersion = "test"
            c.transport = { req in
                let data = try JSONSerialization.data(withJSONObject: json)
                let resp = HTTPURLResponse(url: req.url!, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
                return (data, resp)
            }
            return c
        }

        // ---- MachineFingerprint ----
        let fpAgain = MachineFingerprint.fingerprint()!
        check(fp == fpAgain, "fingerprint deterministic")
        check(fp.count == 64 && fp.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              "fingerprint is 64 lowercase hex")
        MachineFingerprint.uuidProvider = { "TEST-UUID-0002-BBBB" }
        let fpOther = MachineFingerprint.fingerprint()!
        check(fpOther != fp, "different UUID -> different fingerprint")
        check(!fpOther.contains("TEST-UUID"), "raw UUID never appears in fingerprint output")
        MachineFingerprint.uuidProvider = { nil }
        check(MachineFingerprint.fingerprint() == nil, "nil UUID -> nil fingerprint")
        MachineFingerprint.uuidProvider = { "   " }
        check(MachineFingerprint.fingerprint() == nil, "blank UUID -> nil fingerprint")
        MachineFingerprint.uuidProvider = { testUUID }

        // ---- VMDetector ----
        VMDetector.modelProvider = { "VMware7,1" }
        check(VMDetector.isVirtualMachine(), "vmware model flagged")
        VMDetector.modelProvider = { "VirtualBox" }
        check(VMDetector.isVirtualMachine(), "virtualbox model flagged")
        VMDetector.modelProvider = { "MacBookPro18,3" }
        VMDetector.hypervisorFlagProvider = { false }
        check(!VMDetector.isVirtualMachine(), "bare metal not flagged")
        VMDetector.hypervisorFlagProvider = { true }
        check(VMDetector.isVirtualMachine(), "hv_vmm_present flagged")
        VMDetector.hypervisorFlagProvider = { false }

        // ---- TrialToken (test-known HMAC secret) ----
        let ts = LicenseGate.iso(now), te = LicenseGate.iso(now.addingTimeInterval(14 * 86400))
        let tok = TrialToken.make(fingerprint: fp, start: ts, end: te, secret: testSecret)
        check(TrialToken.verify(token: tok, fingerprint: fp, start: ts, end: te, secret: testSecret),
              "token round-trip verifies")
        let teTampered = LicenseGate.iso(now.addingTimeInterval(15 * 86400))
        check(!TrialToken.verify(token: tok, fingerprint: fp, start: ts, end: teTampered, secret: testSecret),
              "tampered end date rejected")
        check(!TrialToken.verify(token: tok, fingerprint: "deadbeef", start: ts, end: te, secret: testSecret),
              "wrong fingerprint rejected")
        check(!TrialToken.verify(token: tok, fingerprint: fp, start: ts, end: te, secret: "wrong-secret"),
              "wrong secret rejected")
        check(!TrialToken.verify(token: tok + "00", fingerprint: fp, start: ts, end: te, secret: testSecret),
              "length-mismatched token rejected")

        // ---- Trial window: active inside, expired outside (token-bound) ----
        let (gActive, _) = tokenGate(start: now.addingTimeInterval(-3600.0),
                                     end: now.addingTimeInterval(6 * 3600.0))
        check(gActive.isTrialActive(now: now), "window math active inside")
        check(gActive.resolvedTier(now: now) == LicenseGate.Tier.Trial, "token-bound trial -> Trial")

        // Tampered window: editing the cached end breaks the token -> Free.
        gActive.trialEndsAt = LicenseGate.iso(now.addingTimeInterval(365 * 86400))
        check(!gActive.hasValidTrialToken(), "edited window invalidates token")
        check(gActive.resolvedTier(now: now) == LicenseGate.Tier.Free, "tampered window -> Free")

        let (gExpired, _) = tokenGate(start: now.addingTimeInterval(-10 * 86400.0),
                                      end: now.addingTimeInterval(-9 * 86400.0))
        check(!gExpired.isTrialActive(now: now), "window math expired outside")
        check(gExpired.resolvedTier(now: now) == LicenseGate.Tier.Free, "expired -> Free")
        check(!gExpired.canUse(LicenseGate.Feature.ScheduledReports, now: now))

        // 72h offline grace: ended 24h ago -> still Trial; ended 80h ago -> Free.
        let (gGrace, _) = tokenGate(start: now.addingTimeInterval(-16 * 86400.0),
                                    end: now.addingTimeInterval(-24 * 3600.0))
        check(gGrace.resolvedTier(now: now) == LicenseGate.Tier.Trial, "24h past end within grace -> Trial")
        let (gPastGrace, _) = tokenGate(start: now.addingTimeInterval(-20 * 86400.0),
                                        end: now.addingTimeInterval(-80 * 3600.0))
        check(gPastGrace.resolvedTier(now: now) == LicenseGate.Tier.Free, "80h past end -> Free")

        // Activation: valid key -> Pro + persisted; bad key -> untouched.
        let (gPro, _) = tokenGate(start: now.addingTimeInterval(-10 * 86400.0),
                                  end: now.addingTimeInterval(-9 * 86400.0))
        check(gPro.activate("ABCD-EF12-GH34-IJ56-KL78"))
        check(gPro.licenseKey == "ABCD-EF12-GH34-IJ56-KL78")
        check(gPro.resolvedTier(now: now) == LicenseGate.Tier.Pro)
        check(gPro.canUse(LicenseGate.Feature.PdfReportCard, now: now))

        let (g2, _) = tokenGate(start: now.addingTimeInterval(-10 * 86400.0),
                                end: now.addingTimeInterval(-9 * 86400.0))
        check(!g2.activate("nonsense"))
        check(g2.resolvedTier(now: now) == LicenseGate.Tier.Free)

        // Persistence round-trip: a new gate over the SAME store restores Pro.
        let g3 = LicenseGate(defaults: gPro.defaults,
            trialStartISO: LicenseGate.iso(now.addingTimeInterval(-10 * 86400.0)),
            trialEndISO: LicenseGate.iso(now.addingTimeInterval(-9 * 86400.0)),
            trialRegistry: gPro.trialRegistry, tokenStore: gPro.tokenStore)
        check(g3.resolvedTier(now: now) == LicenseGate.Tier.Pro)

        // H8: a fresh gate with no stored trial is Free (no auto-stamp);
        // startTrial now requires a server activation.
        let gFresh = LicenseGate(defaults: freshStore())
        check(gFresh.trialStartedAt.isEmpty && gFresh.trialEndsAt.isEmpty)
        check(!gFresh.isTrialActive(now: now))
        check(gFresh.resolvedTier(now: now) == LicenseGate.Tier.Free)

        // Server-allowed activation: server window stamped, token cached, Trial.
        let aStart = LicenseGate.iso(now), aEnd = LicenseGate.iso(now.addingTimeInterval(14 * 86400))
        let aTok = TrialToken.make(fingerprint: fp, start: aStart, end: aEnd, secret: testSecret)
        let allowedJSON: [String: Any] = ["ok": true, "trial_start": aStart, "trial_end": aEnd, "token": aTok]
        let gAct = LicenseGate(defaults: freshStore(),
                               trialRegistry: stubClient(status: 200, json: allowedJSON),
                               tokenStore: InMemoryTrialTokenStore())
        gAct.startTrial(now: now)
        check(gAct.trialStartedAt == aStart && gAct.trialEndsAt == aEnd, "server window stamped")
        check(gAct.hasValidTrialToken(), "token cached and valid")
        check(gAct.isTrialActive(now: now))
        check(gAct.resolvedTier(now: now) == LicenseGate.Tier.Trial)
        let stampedStart = gAct.trialStartedAt
        gAct.startTrial(now: now.addingTimeInterval(60))
        check(gAct.trialStartedAt == stampedStart, "second startTrial is a no-op")

        // Server-denied (already consumed): stays Free, denial latched, no-op after.
        let gDenied = LicenseGate(defaults: freshStore(),
                                  trialRegistry: stubClient(status: 403, json: ["ok": false, "error": "trial_already_consumed"]),
                                  tokenStore: InMemoryTrialTokenStore())
        gDenied.startTrial(now: now)
        check(gDenied.trialStartedAt.isEmpty, "denied: no window stamped")
        check(gDenied.trialDenialReason == TrialDenialReason.alreadyConsumed.rawValue, "denial reason latched")
        check(gDenied.resolvedTier(now: now) == LicenseGate.Tier.Free, "denied -> Free")
        check(LicenseGate.trialDenialMessage(for: gDenied.trialDenialReason) != nil, "denial has UI copy")
        gDenied.startTrial(now: now)
        check(gDenied.resolvedTier(now: now) == LicenseGate.Tier.Free, "denied: retry is a no-op")

        // Server-denied (VM): stays Free with the VM reason.
        let gVM = LicenseGate(defaults: freshStore(),
                              trialRegistry: stubClient(status: 403, json: ["ok": false, "error": "vm_not_allowed"]),
                              tokenStore: InMemoryTrialTokenStore())
        gVM.startTrial(now: now)
        check(gVM.trialDenialReason == TrialDenialReason.vmNotAllowed.rawValue, "VM denial reason latched")
        check(gVM.resolvedTier(now: now) == LicenseGate.Tier.Free, "VM denied -> Free")

        // Offline: stays Free, needs-connection flagged (non-destructive).
        var cOff = TrialRegistryClient()
        cOff.baseURLString = "https://trial.test"
        cOff.hmacSecret = testSecret
        cOff.transport = { _ in throw URLError(.notConnectedToInternet) }
        let gOff = LicenseGate(defaults: freshStore(), trialRegistry: cOff,
                               tokenStore: InMemoryTrialTokenStore())
        gOff.startTrial(now: now)
        check(gOff.resolvedTier(now: now) == LicenseGate.Tier.Free, "offline -> Free")
        check(gOff.trialNeedsConnection, "offline flags needs-connection")
        check(gOff.trialStartedAt.isEmpty, "offline stamps nothing")

        // Unconfigured server (placeholder host): fail-closed, no network.
        let gUncfg = LicenseGate(defaults: freshStore(),
                                 trialRegistry: TrialRegistryClient(),
                                 tokenStore: InMemoryTrialTokenStore())
        gUncfg.startTrial(now: now)
        check(gUncfg.trialNeedsConnection, "placeholder host -> needs-connection")
        check(gUncfg.resolvedTier(now: now) == LicenseGate.Tier.Free)

        // Revalidation: server reports unknown -> local window dropped (non-destructive).
        let (gReval, revalStore) = tokenGate(start: now.addingTimeInterval(-3600.0),
                                            end: now.addingTimeInterval(6 * 3600.0))
        // tokenGate injects the window via init (never persisted by design);
        // simulate the persisted production state explicitly:
        gReval.defaults.set(gReval.trialStartedAt, forKey: LicenseGate.Keys.trialStarted)
        gReval.defaults.set(gReval.trialEndsAt, forKey: LicenseGate.Keys.trialEnds)
        var revalReg = TrialRegistryClient()
        revalReg.baseURLString = "https://trial.test"
        revalReg.hmacSecret = testSecret
        revalReg.transport = { req in
            let data = try JSONSerialization.data(withJSONObject: ["ok": false, "error": "unknown_fingerprint"])
            let resp = HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (data, resp)
        }
        let gReval2 = LicenseGate(defaults: gReval.defaults, trialRegistry: revalReg, tokenStore: revalStore)
        check(gReval2.resolvedTier(now: now) == LicenseGate.Tier.Trial, "pre-revalidation Trial")
        check(gReval2.revalidateTrial(), "revalidation changed state")
        check(gReval2.trialStartedAt.isEmpty, "unknown fp -> window dropped")
        check(revalStore.load() == nil, "unknown fp -> token cleared")
        check(gReval2.resolvedTier(now: now) == LicenseGate.Tier.Free, "post-revalidation Free")

        // Legacy migration: a cached window with no token is dropped at init.
        let legacyDefaults = freshStore()
        legacyDefaults.set(LicenseGate.iso(now.addingTimeInterval(-3600.0)), forKey: LicenseGate.Keys.trialStarted)
        legacyDefaults.set(LicenseGate.iso(now.addingTimeInterval(6 * 3600.0)), forKey: LicenseGate.Keys.trialEnds)
        let gLegacy = LicenseGate(defaults: legacyDefaults,
                                  trialRegistry: stubClient(status: 200, json: allowedJSON),
                                  tokenStore: InMemoryTrialTokenStore())
        check(gLegacy.trialStartedAt.isEmpty, "legacy window migrated away")
        check(gLegacy.resolvedTier(now: now) == LicenseGate.Tier.Free, "legacy -> Free until server trial")
        gLegacy.startTrial(now: now)
        check(gLegacy.resolvedTier(now: now) == LicenseGate.Tier.Trial, "legacy owner gets one server trial")

        return failures
    }
}
