# NetMax → Product App: Executive Summary

**Mission:** analyze whether/how to turn NetMax v0.5 into a successful product app.
**Method:** 5 builder lanes → 3 verifier pairs (adversarial verification, all verdicts below).
**Verdict sources:** `01`–`05` lane docs; `verifier-reports/pair-{a,b,c}.md`.

---

## VERDICT: CONDITIONAL GO

NetMax is a credible measurement engine with a genuinely differentiated brand asset —
its honesty. It should become a **macOS menu-bar app: "Home QoE Sentinel"**
(Concept B, M1 §2) that continuously grades connection quality, explains *why* it's
slow, and produces shareable ISP-accountability evidence. Sell it direct-download,
freemium, with continuous monitoring as the paid tier.

## The product (M1, verified Pair A)

- **Primary concept B:** Home QoE Sentinel — consumer network health monitor +
  evidence kit. Concepts C/D ship later as paid pro modules; E is a niche wedge.
- **Brand moat:** anti-scamware positioning. Every marketing claim traces to a
  logged reproducible run (+48% under contention, measured, methodology public).
- **Monetization:** freemium wins for this product — free measures; paid unlocks
  continuous watch sessions, scheduled reports, accountability exports, history
  retention. One-time purchase underprices ongoing value; pure subscription fights
  the category's expectations.

## Architecture (M5, verified Pair B)

- **Stack:** SwiftUI menu-bar app calling the bundled Python engine via subprocess;
  UI never imports engine code. Full Swift rewrite rejected (engine is tested and
  works); Electron/Tauri rejected on footprint; py2app alone can't deliver native UX.
- **Platform facts handled honestly:** sandbox constraints, SSID location permission,
  notarization — tagged [CONFIRMED]/[UNCERTAIN] in the doc.
- **Data:** SQLite history schema mapped field-by-field onto what `results.json` /
  `history.json` actually contain (verified against real files).
- **Migration:** engine modules port as-is; only `netmax_gui.py` is superseded.

## Feature roadmap (M4, verified Pair A)

- **NOW (v1.0, 10 items):** signed/notarized .app+DMG, honest-limits onboarding,
  menu-bar presence, scheduled background tests, ISP report card, degradation
  notifications, PDF export/share, history trends, diagnostics bundle, licensing gate.
- **NEXT (v1.x):** QoE timeline with WiFi-event correlation, router awareness,
  multi-device coordination, per-app attribution, anomaly detection.
- **LATER:** Windows companion, opt-in cloud sync/crowd data, community ISP
  benchmarking, Shortcuts/Home Assistant integrations, ML diagnosis.
- **Non-goals (hard):** scamware-style claims, VPN features (changes regulatory
  class), router firmware flashing, non-consensual telemetry.

## Legal barriers (M2, verified Pair C) — NOT LEGAL ADVICE

Top exposures, ranked:
1. **App Store review risk** around network-manipulation framing → mitigated by
   honest-limits copy; direct download shrinks reviewer risk but shifts exposure to
   ToS/claims/privacy surfaces (tradeoff stated both ways in-doc).
2. **Measurement-endpoint etiquette:** thousands of customers hammering public
   speed-test/DNS endpoints invites blocking → plan owned/licensed probe infra.
3. **Privacy posture:** strictly local-first keeps GDPR/CCPA surface minimal; any
   telemetry flips the app into regulated territory — opt-in only, or don't ship it.
4. **Claims substantiation duty:** exports are informational, never certified;
   marketing numbers need internal run evidence behind them.
5. **Trademark:** "NetMax"-style names are heavily used in-category — clearance
   search before committing to a brand.

## Market reality (M3, verified Pair C)

- **Gap is real:** no mainstream product combines continuous QoE monitoring +
  honest maximizer framing + ISP accountability artifacts. Speed-test apps measure
  once; analyzers are enthusiast tools; boosters are scamware.
- **Segments:** remote workers first, IT prosumers second, gamers third; small
  offices deliberately deferred (residential-ToS alignment, per M2 seam check).
- **Distribution tradeoff:** App Store = reach + review risk; notarized direct =
  control + trust-building friction. Setapp viable as a secondary channel.
- **Validate before building:** landing-page waitlist with honest pitch is the
  cheapest go/no-go signal.

## Verification record

| Vertical | Lanes | Verdict | Fixes |
|---|---|---|---|
| Pair A | M1 strategy × M4 roadmap | READY-TO-MERGE | 2 MINOR (stale test-count claims → measured truth) |
| Pair B | M5 architecture | READY-TO-MERGE | 5 MINOR (tag hygiene, class-name fix, schema rename, UX gaps) |
| Pair C | M2 legal × M3 market | READY-TO-MERGE | 2 MINOR (evidence-grade→informational; cloud-tier compliance note) |

Suite at merge time: **157 passed** (default pytest scope). Note: full collection
reports 201 passed + 5 subtests — the README's "201" and strategy doc's original
"68" were both stale/partial counts of the same suites; docs now carry the
reconciled numbers. Zero blockers across all three pairs; every verdict backed by
pasted command output in the pair reports.

## Open decisions (flagged by builders/verifiers, unowned)

1. Final product name + trademark clearance search (blocks branding work).
2. Pricing confirmation ($ one-time vs sub tiers) — M3/M4 left as open question.
3. Telemetry stance sign-off: recommend none at v1.0; revisit only with counsel.
4. Owned measurement infrastructure budget (endpoint-independence vs cost).

## Next step

Build Phase 0 of NOW: signed .app bundle wrapping today's engine (N1) + onboarding
flow (N2). Everything else in NOW depends on those two.
