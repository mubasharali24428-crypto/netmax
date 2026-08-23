# NetMax — Legal & Regulatory Barrier Analysis

**Document:** `docs/product/02-legal-barriers.md`
**Status:** Draft for counsel review · **Date:** 2026-08-23
**Scope:** Consumer shipping paths for NetMax v0.5 (macOS bandwidth maximizer +
diagnostics toolkit): (a) Mac App Store distribution, (b) direct download /
outside-the-App-Store distribution.
**Product behavior analyzed:** throughput measurement over public HTTP endpoints;
N-parallel-TCP-stream "turbo"/"boost" modes claiming a larger fair share of a
*contended* WiFi pipe; public DNS resolver latency ranking; Waveform-style
bufferbloat grading (A+–F); local WiFi info reads; CSV/JSON export; continuous
watch loop.

> **NOT LEGAL ADVICE.** This document is an internal engineering/policy risk
> analysis prepared by non-lawyers. It identifies likely friction points so that
> product decisions can be made deliberately, but it does not constitute legal
> advice, creates no attorney-client relationship, and must not be relied upon
> as a substitute for review by qualified counsel in the relevant jurisdictions
> before launch. Confidence tags ([CONFIRMED]/[LIKELY]/[UNCERTAIN]) express
> engineering-level confidence only. Statutes, regulations, platform policies,
> and case law evolve; everything here requires fresh verification at submission
> time.

---

## 0. How to read this document

Each numbered item carries one of three tags:

| Tag | Meaning |
|---|---|
| `[CONFIRMED]` | Long-standing, stable, verifiable fact or policy area (still re-verify current text before submission). |
| `[LIKELY]` | Well-supported inference from how platforms/regulators operate; directionally reliable, details unverified. |
| `[UNCERTAIN]` | Genuinely unsettled, jurisdiction-dependent, or fast-moving — counsel call required. |

Confidence applies to *existence/direction of the barrier*, not to any specific
threshold, dollar figure, or outcome.

---

## 1. Apple App Store review risks

### 1.1 Category fit and the core question reviewers will ask
NetMax measures and reports; it does not tunnel traffic, intercept packets, or
act as a VPN. That distinction is the load-bearing wall of an App Store
submission. Apple treats genuine VPN/network-tunneling functionality as a
special category requiring the NetworkExtension entitlement, specific review
attention, and (in recent policy generations) justification for collecting
browsing-related data. NetMax's architecture — plain TCP/HTTP measurement
streams plus local `airport`/`networksetup` reads — sits outside that category.
**[CONFIRMED]** that VPN-like tunneling apps face a distinct, stricter review
track; **[LIKELY]** that a pure measurement tool avoids it, provided UI copy
never suggests interception, filtering, or content access.

### 1.2 Misleading-performance-claims rules (Guideline 2.3 family)
App Review Guidelines require accurate metadata and prohibit exaggerated or
misleading performance claims. Marketing language like "boost," "turbo,"
"faster internet" invites rejection if the app cannot deliver in general
conditions — which NetMax cannot (it only shifts *shares* of a contended pipe).
NetMax's existing "honest limits" framing ("cannot exceed your ISP cap";
"gains appear only under contention"; "router QoS overrides everything") is
exactly the posture reviewers reward, because screenshots/descriptions and
in-app copy will match observed behavior. **[CONFIRMED]** that misleading
metadata is a standard rejection ground; **[LIKELY]** that honest-limits framing
materially reduces rejection probability; residual tripwires:

- Any screenshot showing a large "gain %" without an on-image "contended WiFi
  only" qualifier **[LIKELY]** draws a 2.3 objection.
- The word "maximizer" itself is borderline; a reviewer reading only the
  subtitle may pre-judge scamware. Mitigate with subtitle copy like "Measure,
  don't guess — honest Wi-Fi diagnostics." **[UNCERTAIN]** whether the name
  alone ever triggers rejection; more likely it triggers *scrutiny*, so every
  other surface must be spotless.
- Third-party comparison charts ("faster than X") are unsupported-claims
  magnets unless the methodology is disclosed in-app. **[LIKELY]**.

### 1.3 Background execution / daemons
The watch loop (`netmax_watch.py`) is conceptually a monitoring daemon. App
Store builds cannot install launchd agents/daemons or rely on arbitrary
background execution; iOS-style background-mode rules apply to macOS apps too,
and long-running polling loops attract energy complaints and possible rejection
under software-requirements guidance (apps must behave responsibly when not
frontmost). **[CONFIRMED]** that installing privileged helper daemons is not
possible for App Store-distributed apps (sandbox); **[LIKELY]** that a
user-visible, foreground-bounded "watch session" (start/stop, menu-bar app with
documented battery behavior) passes where an invisible always-on poller would
not. Design consequence: ship watch mode as an explicit, pausable session, not
a login item.

### 1.4 Sandbox and API consequences (not strictly legal, but gating)
Sandboxed App Store builds lose raw access to tools NetMax shells out to
(`curl` exists in-container but spawning arbitrary subprocesses is constrained;
`airport -s`-style private wireless diagnostics APIs have been gated behind
Apple entitlements in recent macOS releases, with an application process for
SSID/subscriber-info style reads). **[CONFIRMED]** that sandbox + private-API
gating constrains the current Python-subprocess architecture; **[LIKELY]** that
an App Store version needs partial re-architecture (native NWPathCheck/
Network.framework measurements, entitlement application for Wi-Fi SSID info).
This is an engineering cost driven by policy — budget for it or route those
features to the direct-download build.

### 1.5 Direct download path: Developer ID + notarization
Distributing outside the Store requires Developer ID signing and notarization;
Gatekeeper enforces both. Notarization checks malware/security basics, not
guideline compliance, so the §1.2 claim-framing risk shrinks (no human reviewer)
but §3–§6 risks below grow instead (no Apple privacy-label mediation; you carry
the full EULA/liability surface yourself). **[CONFIRMED]** notarization is
mandatory for frictionless Gatekeeper passage on current macOS; **[LIKELY]**
that un-notarized ad-hoc builds now generate scary end-user warnings that kill
consumer conversion.

### 1.6 Privacy "nutrition labels"
Any App Store listing requires privacy answers (what's collected, linked to
identity, tracking). For a strictly local-first build the honest answer is
"nothing collected," which is both compliant and a marketing asset. If
telemetry ships, labels become a legal exposure surface themselves — inaccurate
labels are treated far more seriously than most teams expect. See §3.3.
**[CONFIRMED]** labels are mandatory; **[LIKELY]** misstatement risk is the
practical teeth.

---

## 2. ISP terms-of-service exposure

### 2.1 Parallel streams
Speed measurement via multiple concurrent connections is mainstream practice —
major consumer speed tests use parallel connections — so N-stream measurement
itself is almost never contractually problematic. **[CONFIRMED]** that
multi-connection testing is industry-standard and publicly practiced at scale.
The genuinely gray zone is *purpose*: streams opened to game shared-medium
airtime allocation (claiming more than a per-flow-fair share for sustained
personal use) sit closer to conduct ISPs characterize as abuse of fair-use/
network-management terms. NetMax's turbo mode is bounded by standard TCP
congestion fairness per flow — i.e., each stream behaves politely — which is a
meaningful defensive fact. **[LIKELY]** that per-flow-polite parallelism is
defensible as ordinary use; **[UNCERTAIN]** whether any given ISP's ToS
language ("may not interfere with," "no artificial traffic manipulation") could
be stretched to cover it — language varies by carrier and jurisdiction, and
counsel should sample the top carriers' current residential ToS in launch
markets.

### 2.2 Residential vs commercial use
Most residential agreements restrict use to personal, non-commercial purposes
and prohibit resale/sharing. A consumer running NetMax personally is squarely
inside personal use **[CONFIRMED]**; the exposure appears only if marketing
drifts toward small-office/performance-SLA audiences while users hold
residential plans, or if a future "report sharing" feature publishes results
publicly in a way resembling a commercial service. Keep the product story
consumer-personal and this stays clean. **[LIKELY]** low residual risk.

### 2.3 Cap evasion optics
NetMax cannot exceed provider-side caps, and its own README says so — that
honesty is also legal hygiene. Never market "get past your data cap/throttle."
Throttle-*measurement* (detecting, documenting, exporting evidence of
throttling) is legitimate consumer tooling and, if anything, socially valuable;
**[UNCERTAIN]** whether any jurisdiction's rules create obligations or
complications for vendors whose tools produce regulator-grade evidence — treat
exported reports as informational, not certified, in product copy.

---

## 3. Privacy / data-protection

### 3.1 Strictly-local baseline (recommended default)
As shipped today — all measurement local, exports written to user-chosen files,
no network calls beyond the measurement targets themselves — NetMax processes
no personal data beyond what the user's own machine generates, and there is no
controller relationship over third-party data. GDPR/CCPA-type statutes attach
to *personal data processing by a business*; a fully local tool largely falls
outside their practical scope. **[LIKELY]** minimal statutory exposure in the
local-first configuration; **[UNCERTAIN]** edge questions (device identifiers
generated locally, crash logs the user manually submits) remain trivially
manageable but should be described in the privacy policy anyway.

### 3.2 If telemetry/crash reporting ships
Adding analytics or crash reporting flips NetMax into regulated territory in
multiple jurisdictions at once. Minimum viable compliance surface:

- **GDPR-family (EU/EEC/UK):** lawful basis for each processing purpose
  (consent or legitimate interests analysis), purpose limitation and *data
  minimization by design* (aggregate counters > raw events), transparency
  notice, data-subject rights handling, processor contracts with any SDK vendor,
  and a DPIA if profiling-like features appear. Consent must be freely given,
  specific, informed, unbundled — no telemetry-by-default with an off-switch
  buried in settings; opt-in at first run. **[CONFIRMED]** that these
  obligations exist and apply to desktop apps distributed into the EU;
  **[UNCERTAIN]** precise applicability thresholds for a small vendor (some
  obligations scale with size/role).
- **CCPA/CPRA (California) and sibling state laws:** notice at collection,
  disclosure of categories sold/shared, opt-out of "sharing" where cross-context
  behavioral advertising definitions are met (unlikely for a diagnostic app, but
  SDK choice decides), reasonable security. **[CONFIRMED]** statute exists and
  covers for-profit businesses meeting modest thresholds; **[LIKELY]** a
  telemetry-only (non-adtech) implementation lands in the lightest tier.
- **Design rule:** every byte of telemetry must map to a named purpose in the
  privacy policy *before* the build ships, or cut the feature.

### 3.3 Privacy nutrition labels (conceptual)
App Store privacy labels are declarative self-certification. Local-first =
"data not collected" label = near-zero label risk. With telemetry, the label
must enumerate collection types accurately, and Apple has shown willingness to
remove/reject apps over label mismatches with observed behavior. **[CONFIRMED]**
labels are required and enforced; **[LIKELY]** mismatch enforcement intensifies
over time.

### 3.4 DNS ranking feature — special note
Ranking public resolvers requires querying them with the user's lookups or
synthetic probes. Synthetic probes (fixed test domains) leak nothing personal;
re-resolving the user's real browsing through ranked third-party resolvers
would create a data-sharing story (user DNS queries visible to whichever
resolver wins). Ship synthetic probes only. **[LIKELY]** keeps the feature out
of privacy-regulation scope; **[UNCERTAIN]** if real-query steering ships later
— that becomes a §3.2-grade feature change.

---

## 4. Measurement-target etiquette & law

### 4.1 The scale problem
One customer probing public endpoints is a speed test. Thousands of customers
probing on schedule (watch loops!) is a distributed load pattern indistinguishable
from light abuse. Risks in ascending severity: rate-limiting → IP/CIDR blocking
→ AUP breach claims → (worst case) civil claims framed around unauthorized
access/impairment doctrines. **[CONFIRMED]** that public endpoints rate-limit
and block aggressively at scale; **[LIKELY]** that default-on scheduled probes
against third-party endpoints is the single highest-severity operational-legal
risk in this document.

### 4.2 Doctrinal sketch (qualitative)
Anti-abuse statutes in the U.S. turn on access "without authorization" or
exceeding authorized use; courts have narrowed broad readings in recent years,
but the boundary between "public endpoint used as intended" and "use the
operator didn't authorize" is fact-specific and litigation-tested only at the
edges. Similar computer-misuse regimes exist in the UK/EU. Hitting documented,
publicly-offered speed-test/DNS endpoints within published rate limits is the
safe harbor; ignoring 403s/blocks, rotating IPs to evade bans, or hammering
endpoints lacking any public AUP is where exposure concentrates.
**[CONFIRMED]** that such regimes exist broadly; **[UNCERTAIN]** how they'd
apply to any specific endpoint — do not assume; verify per-endpoint.

### 4.3 Concrete mitigations
1. Default probe cadence conservative (e.g., full test on demand; watch loop
   lightweight, randomized jitter, hard daily cap). **[LIKELY]** sufficient.
2. Honor HTTP 429/403 immediately, back off exponentially, never retry around
   blocks. Encode in engine. **[CONFIRMED]** best practice.
3. Maintain an endpoint allowlist with per-endpoint owner, terms link, and
   documented limits; review quarterly. **[LIKELY]** expected diligence.
4. Contact-and-license: several operators offer developer terms or mirrors;
   written permission converts etiquette into contract. **[CONFIRMED]** that
   licensed options exist in the measurement ecosystem.
5. **Owned/licensed infrastructure option:** self-host measurement nodes (or
   license a commercial measurement network) for the default path; keep public
   endpoints as opt-in fallback. This eliminates §4.1 wholesale and improves
   result consistency. Cost-bearing but the strategically correct end-state
   **[LIKELY]** for a serious consumer launch.

### 4.4 Public DNS resolvers specifically
Major public resolver operators publish usage policies prohibiting automated
abuse; latency-ranking probes are tiny, but at fleet scale they are automation.
Same mitigation set applies (jitter, caps, honor blocks). **[CONFIRMED]** that
published acceptable-use policies exist for major resolvers.

---

## 5. Trademark / branding

### 5.1 Name collision
"NetMax"-style names are heavily used across networking utilities, ISPs'
marketing tiers ("MAX" plan brands), and legacy software. Risk is
likelihood-of-confusion analysis: same/similar mark + related goods/services
(network software) = elevated conflict probability. Consequences range from
cease-and-desist letters (cheap nuisance, real distraction) to App Store name
disputes (Apple adjudicates naming conflicts and can force renaming late —
expensive). **[LIKELY]** meaningful collision risk with the bare name;
**[CONFIRMED]** that Apple enforces first-come naming disputes in the Store.
Mitigations: full clearance search in launch jurisdictions before committing;
consider a distinctive compound mark; register early in priority classes for
software. **[UNCERTAIN]** availability outcomes — search, don't assume.

### 5.2 "Waveform A+–F rubric" attribution vs trademark
Two separate questions, routinely conflated:

- **Trademark:** if the grading scheme is marketed using Waveform's name or a
  confusingly similar badge ("Waveform Grade™"), that implies endorsement and
  is classic trademark-infringement exposure regardless of attribution.
  Attribution does not cure confusion. **[CONFIRMED]** doctrine shape;
  **[UNCERTAIN]** whether Waveform asserts rights over rubric letter grades
  specifically — grading letters alone are likely weak marks, but the safe play
  is generic labeling ("bufferbloat grade A+–F under increased load").
- **Accuracy/attribution ethics:** if NetMax's implementation replicates
  Waveform's methodology, referencing it descriptively ("inspired by the
  open Waveform bufferbloat test methodology") with a link is honest and
  reduces passing-off/unfair-competition optics — but check whether Waveform's
  site terms restrict derivative test implementations, and prefer publishing
  NetMax's own methodology page. **[LIKELY]** that an independent-methodology +
  generic-grading approach ends both the trademark and attribution questions.

### 5.3 Descriptive marks elsewhere
Resolver names, ISP names, and "macOS" in copy: nominative fair use (naming a
product to describe compatibility/measurement) is legitimate when truthful and
not implying sponsorship. Keep logos out, add "not affiliated with" boilerplate
where third-party names appear prominently. **[CONFIRMED]** nominative-use
doctrine exists in U.S. law with similar concepts elsewhere; **[LIKELY]** low
risk with disciplined copy.

---

## 6. Liability disclaimers & EULA essentials

### 6.1 Advertising-claims discipline (the FTC-shaped hole)
A utility that *reports* performance makes implicit *claims* about performance.
Advertising-substantiation doctrine (U.S.) requires a reasonable basis for
objective claims before publication; consumer-protection regimes in the EU/UK
similarly police misleading commercial practices. Every number in App Store
copy, landing pages, and release notes needs either internal test evidence or
removal. "Up to" phrasing requires the typical-result reality to match.
**[CONFIRMED]** substantiation duty exists; **[LIKELY]** the practical bar is
"keep claims narrow, measured, and conditional" — which the honest-limits
framing already does.

### 6.2 EULA minimum clause set (direct-download builds especially)
- License grant (personal, non-transferable), restrictions.
- **AS-IS/warranty disclaimer** to the maximum extent permitted; the tool
  provides *informational estimates*, not guarantees of throughput.
- **Liability cap / consequential-damages exclusion**, drafted to survive local
  law review — several jurisdictions (EU/UK consumer law, parts of Germany/
  Austria doctrine, some U.S. states) limit disclaimers of consequential
  damages or implied warranties against consumers; a U.S.-drafted blanket
  disclaimer will not transplant cleanly. **[CONFIRMED]** that consumer-law
  overrides exist; **[UNCERTAIN]** exact enforceability per jurisdiction —
  counsel drafts, this memo flags.
- Measurement-accuracy disclaimer: results depend on uncontrollable factors
  (ISP conditions, Wi-Fi medium, third-party endpoints); outputs are
  directional, not calibrated instruments.
- No-network-modification representation: NetMax observes and measures; it does
  not alter router/QoS/ISP configurations (protects against "your tool broke my
  Wi-Fi" claims and reinforces §1.1 positioning).
- Arbitration/class-action waiver (U.S. consumer products commonly include;
  enforceability varies and some platforms/jurisdictions constrain it —
  counsel decision). **[UNCERTAIN]**.
- Export-control and sanctions boilerplate; age/government-end-user reps.
- Update & termination terms; governing law/venue.

### 6.3 App Store builds
Apple's standard Licensed Application EULA automatically covers Store
distribution; a custom EULA can supplement via Settings > app description
mechanics. Practical consequence: the custom drafting burden of §6.2 applies
mostly to the direct-download channel. **[CONFIRMED]** default Apple EULA
applies absent customization; **[LIKELY]** still worth a short supplemental
terms page covering the measurement-accuracy and no-network-modification points
everywhere the product is described.

### 6.4 Support-surface hygiene
Support replies diagnosing "your ISP throttles you" should stay factual
(measurement, export, suggestion to contact ISP) — avoid asserting legal
conclusions about the ISP's conduct in product copy or support macros.
**[LIKELY]** reduces defamation-adjacent complaint risk to negligible.

---

## 7. Consolidated risk register

| # | Risk | Channel | Severity | Likelihood | Tag | Primary mitigation |
|---|---|---|---|---|---|---|
| R1 | Performance-claim rejection / metadata | App Store | Medium | Medium | LIKELY | Honest-limits copy everywhere; conditioned screenshots |
| R2 | Watch-loop background-execution rejection | App Store | Medium | Medium | LIKELY | Foreground bounded sessions, pausable |
| R3 | Sandbox/private-API feature loss | App Store | High (eng) | High | CONFIRMED | Native re-architecture or feature split |
| R4 | Endpoint AUP breach at scale | Both | High | Medium | LIKELY | Caps+jitter+backoff; owned/licensed nodes |
| R5 | Telemetry privacy regime trigger | Both | High | Low (if local-first) | UNCERTAIN | Stay local-first; opt-in only |
| R6 | Trademark name collision | Both | Medium | Medium | LIKELY | Clearance search pre-commit |
| R7 | Rubric-name endorsement implication | Both | Low-Med | Medium | UNCERTAIN | Generic grading labels; own methodology page |
| R8 | EULA unenforceable clauses abroad | Direct | Medium | Medium | UNCERTAIN | Counsel-drafted localized terms |
| R9 | Un-notarized build friction | Direct | High | High if skipped | CONFIRMED | Developer ID + notarize |

---

## 8. Pre-submission checklist

1. Re-read current App Review Guidelines end-to-end; confirm §1 items against
   live text (numbering drifts between versions).
2. Legal copy audit: every marketing surface passes the "contended-only,
   cap-honest" test; screenshots annotated.
3. Endpoint allowlist reviewed; rate limits, backoff, and block-honoring
   verified in code paths (watch loop included).
4. Privacy decision recorded: local-first confirmed OR telemetry design
   reviewed against §3.2 with counsel sign-off.
5. Trademark clearance search completed in launch jurisdictions; Apple naming
   checked.
6. Grading labels made generic; methodology page published.
7. EULA/terms finalized by counsel per channel (Store supplement + direct
   download full EULA).
8. Notarization pipeline verified for direct builds.

---

> **NOT LEGAL ADVICE — closing notice.** This analysis maps engineering
> decisions onto known regulatory and platform-policy landscapes as of the date
> above. It contains no legal advice and must not substitute for it. Before
> shipping NetMax to consumers through either channel, engage qualified counsel
> to review: (a) App Store submission materials, (b) ISP-facing marketing
> claims, (c) any telemetry design, (d) trademark clearance, and (e) the final
> EULA/terms for each distribution channel and target jurisdiction. All tagged
> statements require re-verification against then-current law and policy.
