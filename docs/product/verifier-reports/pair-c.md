# Verifier Report — PAIR C (Vertical C: Legal × Market)

**Mission:** Verify lanes M2 (legal) × M3 (market) and their seam contract.
**Verifier:** Pair C delegate (Pass 1 sub-verifier mechanics → Pass 2 prime-verifier judgment).
**Date:** 2026-08-23 · **Baseline commit:** `8d12548` · **Work dir:** `/Users/user/netmax-app`
**Scope of edits allowed:** `docs/product/02-legal-barriers.md`, `docs/product/03-market-analysis.md` (fixes only), this report.

---

## PASS 1 — Mechanical sweep (sub-verifier, raw evidence)

### 1.1 Footprint (`git status --short`)

```
?? docs/product/01-product-strategy.md
?? docs/product/02-legal-barriers.md
?? docs/product/03-market-analysis.md
?? docs/product/04-feature-roadmap.md
?? docs/product/05-app-architecture.md
?? docs/product/verifier-reports/
```

Deliverables are untracked as expected; no tracked files modified by me beyond the in-lane fixes recorded in §2.4. No commits made (hard rule honored).

### 1.2 Test suite rerun

```
$ /Users/user/1/bin/python -m pytest -q
157 passed in 7.92s
```

Matches known-good baseline exactly. (Per mission note: default scope is the legitimate expectation; not a lane failure.)

### 1.3 Line counts

```
$ wc -l docs/product/02-legal-barriers.md docs/product/03-market-analysis.md
     403 docs/product/02-legal-barriers.md   ← ≥150 ✓
     256 docs/product/03-market-analysis.md  ← ≥150 ✓ (pre-fix; 262 post-fix)
```

### 1.4 Anti-synthesis scan

**Statute / citation patterns** (`\b\d+\s+U\.S\.C\.|Article\s+\d+|GDPR Art|§-as-statute|Regulation \(EU\)|Directive \d+`):

```
02-legal-barriers.md:105: ...the §1.2 claim-framing risk shrinks...
02-legal-barriers.md:106: ...§3–§6 risks below grow instead...
02-legal-barriers.md:117: ...See §3.3.
02-legal-barriers.md:213: — that becomes a §3.2-grade feature change.
02-legal-barriers.md:253: ...eliminates §4.1 wholesale...
02-legal-barriers.md:337: ...reinforces §1.1 positioning).
02-legal-barriers.md:347: ...custom drafting burden of §6.2 applies...
02-legal-barriers.md:379: ...confirm §1 items against live text...
02-legal-barriers.md:386: ...reviewed against §3.2 with counsel sign-off.
03-market-analysis.md:15: > All pricing "benchmarks" in §5 are approximations from memory...
03-market-analysis.md:201: ...waitlist/conversion data (§6)...
```

Judgment: every `§` hit is an **internal cross-reference to the document's own sections**, not statutory citation. Zero `U.S.C.`/`C.F.R.`/`Article N`/`GDPR Art` patterns. No case names matching `X v. Y` found anywhere.

**Named laws/regimes treatment:** GDPR-family, CCPA/CPRA, FTC-shaped substantiation doctrine, computer-misuse regimes (US + UK/EU), EU/UK consumer law, Apple App Review Guidelines, Apple standard Licensed Application EULA — all described **qualitatively with confidence tags**, no section numbers, no invented precision. M2 explicitly says guideline numbering "drifts between versions" and mandates re-reading live text (M2:379–380).

**Dollar/revenue/market-size figures:**

```
03-market-analysis.md:82-83: "+48% in a contended window on a real line — and honest ~0%..."
03-market-analysis.md:140: "$20–50-ish once for a good tool"          ← hedged "-ish"
03-market-analysis.md:167: "~100% minus payment processing (~3–5%)"   ← "~"
03-market-analysis.md:184: "$10–30 ... above ~$40 one-time..."        ← hedged ranges
03-market-analysis.md:186: "$20–60"                                   ← hedged range
03-market-analysis.md:199-200: "~$29 one-time Pro (or $19 launch pricing)"
```

Provenance check on `+48%`:

```
$ grep -rn '48%' PROJECT_LOG.md docs/product/*.md
PROJECT_LOG.md:12: | Multi-stream turbo | ... | 28.3 → 42.0 Mbps (+48%) during a contended window |
docs/product/01-product-strategy.md:16,87,92,173: same figure, cited to PROJECT_LOG
docs/product/03-market-analysis.md:82,217: same figure
```

The only measured statistic in M3 traces to the repo's own verified run log — not fabricated. All pricing figures carry hedge language ("approximations from memory, not quotes", M3:15; §5 header restates it at M3:178–181). Zero revenue/market-size/download stats present — M3's method note (M3:9–14) explicitly disclaims citing any, deliberately.

**Placeholders / empty sections:** `grep -niE 'TODO|FIXME|TBD|placeholder|XXX|\[insert|lorem'` → no matches in either file. Every numbered section carries substantive content; risk register R1–R9 fully populated.

**Hedge & tag coverage:** M2 has NOT-LEGAL-ADVICE banners top (M2:14–22) and bottom (M2:396–403), tag definitions (M2:26–37), `[CONFIRMED]/[LIKELY]/[UNCERTAIN]` tags on every load-bearing claim. M3 has method-note hedges (M3:9–15) plus per-item `[UNCERTAIN]` flags where facts may have drifted (M3:28, 42, 63, 166, 168, 197).

**Pass 1 conclusion:** mechanically clean. No fabricated citations, statutes, or statistics detected.

---

## PASS 2 — Judgment (prime verifier)

### 2.1 Seam conformance probe (7 cross-claims, ≥5 required)

| # | Cross-claim probed | M2 evidence (file:line) | M3 evidence (file:line) | Verdict |
|---|---|---|---|---|
| S1 | Distribution channel recs vs App Store review/sandbox risk findings | App Store = sandbox + private-API gating constrains current architecture; full-power diagnostics don't fit MAS (M2:90–100, R3 M2:367); watch loop must be foreground-bounded (M2:77–88); honest-limits framing required for metadata (M2:55–75) | Two-track posture: full diagnostics edition direct/notarized; sandbox-friendly monitoring edition on MAS+Setapp (M3:170–174); scamware differentiation via honest copy (M3:68–88) | **AGREE** — channel split mirrors M2's sandbox finding exactly; direct path matches M2's notarization requirement (M2:102–110, R9) |
| S2 | Pricing model vs monetization-relevant legal constraints | Telemetry flips app into regulated territory; opt-in only; design rule: every byte maps to named policy purpose or cut feature (M2:175–196); local-first = minimal exposure (M2:164–173) | Freemium: paid = continuous watch, scheduled reports, ISP accountability exports, history beyond N days (M3:191–194); optional small monthly for cloud history/reporting (M3:199–200) | **CONFLICT (MINOR, fixed)** — cloud-history tier implies server-side storage, crossing M2's strictly-local privacy posture; M3 never acknowledged the compliance surface. **FIXED in-lane** (see §2.4, fix F2) |
| S3 | Telemetry/analytics recs vs privacy-law analysis | Local-first recommended default; if analytics ship → GDPR/CCPA surface, opt-in at first run (M2:164–196, R5) | Go/no-go signal #3 uses "any privacy-respecting analytics" for the landing page (M3:222–226) | **AGREE** — landing-page analytics is pre-product marketing measurement with consent-by-clicking-waitlist semantics, not shipped-app telemetry; consistent with M2's local-first default. (Residual ambiguity noted as SUSPICION-level only; acceptable.) |
| S4 | Competitor scamware framing vs liability/advertising-claims advice | Substantiation duty: every number in copy needs internal test evidence; "up to" phrasing must match typical results (M2:310–319); support replies stay factual, no legal conclusions about ISPs (M2:353–357); throttle-evidence reports are informational, not certified (M2:151–158) | Scamware ring differentiated FROM; claims backed by "verified mechanism" (M3:68–88); ISP-accountability artifact pitched for tickets/complaints (M3:107–112); community posts framed as "story (not a sales pitch)" (M3:216–218) | **CONFLICT (MINOR, fixed)** — M3 called the export artifact "**evidence-grade** history," colliding with M2 §2.3's explicit instruction to treat exported reports as *informational, not certified*. **FIXED in-lane** (fix F1) |
| S5 | Target segments vs ToS residential/commercial notes | Exposure arises if marketing drifts toward small-office/performance-SLA audiences while users hold residential plans; keep product story consumer-personal (M2:142–149) | Segments ranked: remote workers, IT prosumers, gamers, WFH households; small offices (<10 people) explicitly deferred ("better served later… than chased at launch", M3:152–155, 157–158) | **AGREE** — M3's deferral of segment 5 directly honors M2 §2.2's warning |
| S6 | Watch-mode productization vs background-execution finding | Ship watch as explicit, pausable, user-visible session — not login item/daemon (M2:83–88, R2) | Continuous `watch` monitoring is the flagship gap/pricing differentiator (M3:96–100, 192) | **AGREE** — M3 sells continuous monitoring as a *feature* without prescribing implementation; M2's session constraint is compatible (menu-bar pausable sessions still deliver "continuous across the workday") |
| S7 | Naming/branding vs trademark collision risk | "NetMax"-style names heavily used; clearance search before committing; consider distinctive compound mark (M2:267–278, R6) | M3 keeps "maximizer" vocabulary but leans on honest-limits branding; notes scamware taint on category vocabulary (M3:74–88, 250–256) | **UNVERIFIABLE** — M3 makes no naming commitment that contradicts M2; final name decision sits outside both docs' scope. Not a conflict; flagged for the strategy-lane owner |

Seam score: 5 agree, 2 minor conflicts (both fixed), 0 core contradictions, 1 unverifiable-but-consistent.

### 2.2 Internal consistency — M2 (legal doc)

- Channel story: §1.5 correctly states direct-download *shrinks* §1.2 reviewer risk but *grows* §3–§6 exposure (M2:103–110) — consistent with §6.2 applying "mostly to the direct-download channel" (M2:344–351). No approve-then-warn contradiction; it's a tradeoff stated both directions.
- Risk register R1–R9 cross-checks against body text (R3↔§1.4, R5↔§3.2, R9↔§1.5): severities and tags line up.
- DNS ranking: §3.4 synthetic-probes-only recommendation is consistent with §4.4 resolver AUP caution.
- No self-contradiction found.

### 2.3 Internal consistency — M3 (market doc)

- Recommended lead segments (1–2: remote workers, IT prosumers) align with pricing benchmarks: prosumers "$20–50-ish" (M3:139–140) brackets the $29 Pro suggestion (M3:199); remote workers' high WTP supports it. Segment 4 (WFH households, App Store buyers, M3:150–151) aligns with keeping a MAS presence in the two-track posture.
- Setapp-first-among-stores (M3:172–174) coheres with segments 1&4 being its sweet spot (M3:168).
- Kill criteria (M3:238–242) are consistent with the go/no-go signals they gate.
- Post-fix: no contradictions found.

### 2.4 Fixes applied IN-LANE (both MINOR, both in M3)

**F1 — "evidence-grade" seam clash (S4).**
`03-market-analysis.md` §2 item 3: replaced "evidence-grade history" with "documented, exportable history" and added pointer: *"Position it as documentation, never as certified evidence (copy discipline per 02-legal-barriers §2.3/§6.4)."* Diff verified via patch output; post-fix `grep 'evidence-grade'` returns nothing.

**F2 — cloud-tier privacy-posture omission (S2).**
`03-market-analysis.md` §5 suggested starting frame: appended *"Note: any server-side cloud-history component crosses out of the strictly-local privacy posture into the compliance surface described in 02-legal-barriers §3.2 (lawful basis, consent-by-default-off, policy disclosures) — treat that tier as a deliberate privacy-posture decision, not just a pricing line item."*

Post-fix verification:

```
$ /Users/user/1/bin/python -m pytest -q
157 passed in 7.95s
$ wc -l docs/product/02-legal-barriers.md docs/product/03-market-analysis.md
     403 docs/product/02-legal-barriers.md
     262 docs/product/03-market-analysis.md    ← still ≥150
```

No edits were made to `02-legal-barriers.md` (it needed none). No files touched outside permitted set except creating this report.

### 2.5 Classification

- BLOCKERs: none. (No fabricated citation/statistic presented as fact; no core cross-doc contradiction remaining; both files ≥150 lines.)
- MAJOR: none.
- MINOR: 2, both fixed in-lane (F1, F2 above), pytest re-run green after fixes.
- SUSPICION (informational, no action): M3's landing-page-analytics signal (M3:222–226) doesn't specify the analytics tool's own data practices; harmless pre-launch context but worth one line when that page ships.

---

## VERDICT

Both lanes pass Pass 1 mechanical checks clean; seam holds after two MINOR in-lane fixes to M3; suite green post-fix.

READY-TO-MERGE
