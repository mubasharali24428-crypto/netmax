# NetMax → Product App: Product Strategy (M1)

Lane owner: Sub-01 (Product Strategist). Baseline: netmax v0.5 @ `5cd59d5`.
Scope: this file only. Evidence base: `README.md`, `PROJECT_LOG.md`,
`docs/FEATURE-SPECS.md`, `docs/VERIFY-REPORT.md`, source tree skim
(`netmax.py`, `netmax_gui.py`, `netmax_fetch.py`, `netmax_eco.py`,
`netmax_throttle.py`, `measure.py`).

## 0. What we actually have (ground truth)

Any product concept must be built from capabilities that verifiably exist today:

| Capability | Where | Verified state |
|---|---|---|
| True single-stream throughput | `netmax.py baseline` | Live PASS (VERIFY-REPORT), OVH→Cloudflare endpoint failover |
| Parallel-stream share gain | `turbo` / `boost` | **28.3 → 42.0 Mbps (+48%)** during a contended window (PROJECT_LOG) |
| DNS resolver ranking | `dns`, `eco_dns` | Cloudflare fastest every run (~50–54 ms vs system 63–68 ms) |
| Bufferbloat grade A+–F | `bloat`, `bloat-eco` | Waveform-style rubric implemented; eco variant ≈100 KB total |
| Upload / loss / jitter / RSSI-channel | `upload`, `loss`, `jitter`, `wifi` | Live-verified parsing (`ping`, `system_profiler SPAirPortDataType`, curl POST) |
| Continuous monitor + history | `watch`, `summarize_watch_history`, `history.json`, `results.png` | Cycles with worst-grade/max-delta aggregation |
| Export | `export --fmt csv/json` | Working |
| Chunked download accelerator | `fetch` + `AdaptiveController` | Resumable byte-range parts + manifest; latency/loss-aware backoff (>300 ms / >2% loss → step down) |
| Data-frugal mode | `netmax_eco.py` | Full verdicts at ~1% of the data budget (metered-link friendly) |
| Desktop GUI | `netmax_gui.py` (Tkinter) | Isolated-subprocess commands, non-blocking UI, headless-tested |
| Test discipline | 157 offline tests | Passing; network fully mocked (pytest rerun 2026-08-23; engine + GUI + per-module suites) |

Equally important ground truth — the *honesty constraints* baked into the
product: NetMax **cannot exceed the ISP cap**, gains appear **only under
contention**, router QoS overrides everything, and zero-throughput dropouts are
reported as dropouts. This is not a limitation to hide; Section 3 argues it is
the moat.

Known engineering debts relevant to productization: Python + external `curl`
runtime dependency, Tkinter UI (functional, not consumer-polished),
macOS-specific fragility already encountered once (the `airport` binary was
removed by Apple; the team re-derived RSSI via `system_profiler`; `wdutil`
needs sudo and was ruled out; SSID redaction observed in some contexts).

---

## 1. Product concepts

### Concept A — "Network Proof": ISP accountability & evidence kit

- **Target user:** households and remote workers who suspect their connection
  underperforms the plan they pay for; small-office admin who must escalate to
  an ISP or landlord; anyone who has ever argued with an ISP support script.
- **Core value prop:** scheduled, timestamped, exportable proof of what your
  line actually delivered — single-stream truth, bufferbloat grade, packet
  loss, jitter, dropout events (including honest airtime-starvation windows),
  all in CSV/JSON a human or an ISP ticket can consume.
- **Why it wins:** every measurement needed already ships and is
  live-verified; `watch` + `history.json` + `export` + charts form a natural
  evidence pipeline. Competing speed-test sites give a moment-in-time number
  with no memory and no advocacy; NetMax accumulates a case file. The honest
  framing ("we will tell you when the line is fine, too") is exactly what an
  evidence tool needs to be credible.
- **Gaps to build:** scheduler daemon, report generator (human-readable PDF/
  HTML summary), plan-vs-measured comparison input, incident tagging
  ("Zoom froze 19:40").

### Concept B — "Home QoE Sentinel": prosumer network health monitor

- **Target user:** prosumers, home-lab owners, WFH professionals whose income
  depends on the link; the person in the house everyone asks "why is the WiFi
  slow."
- **Core value prop:** a resident monitor that continuously grades the
  connection (bufferbloat A+–F, loss, jitter, RSSI/channel), keeps history,
  correlates bad periods, and answers "is it my ISP, my WiFi, or my router?"
  with per-layer diagnostics (radio layer via RSSI/noise/channel; ISP layer
  via throughput/bloat; DNS layer via resolver ranking).
- **Why it wins:** `watch`, `summarize_watch_history`, `wifi`, and the grade
  rubric already implement the core loop. Menu-bar presence plus
  notifications ("grade dropped to D for 10 min") is a small step from existing
  code. No mainstream consumer tool owns "continuous honest QoE grading with
  history" on macOS [LIKELY — based on qualitative familiarity, needs a
  dedicated market scan (M3 lane) before treating as fact].
- **Gaps to build:** menu-bar app shell, notification thresholds, WiFi
  placement advisor (walk-around RSSI mapper), trend views.

### Concept C — "Fair Share": contended-household accelerator (prosumer power tool)

- **Target user:** heavy downloaders in shared-bandwidth homes/dorms/offices;
  prosumers pulling large assets (datasets, game builds, video rushes) while
  others stream.
- **Core value prop:** when the pipe is contended, claim your fair larger
  share with N parallel TCP streams (standard fairness — the verified +48%
  result), and accelerate large downloads with the resumable chunked `fetch`
  whose `AdaptiveController` automatically backs off when it would hurt the
  link (latency >300 ms or loss >2%) — i.e., fast *and* polite.
- **Why it wins:** this is the capability competitors fake. Real, measurable,
  reproducible gain (+48% under contention is in PROJECT_LOG) versus scamware
  "boosters" that do nothing. The adaptive governor is a genuine safety
  feature nobody markets: it refuses to degrade the household's experience.
- **Gaps to build:** browser-integration or share-sheet ingestion of URLs,
  download manager UI, scheduling (run at night), per-host stream policies.
- **Honest-marketing trap:** gains are conditional on contention. On an idle
  line the product does (and must say) nothing. Any store listing that
  buries this invites refunds and 1-star reviews.

### Concept D — "Pre-flight": gamer/streamer QoE check

- **Target user:** streamers, competitive gamers, podcasters preparing to go
  live; also call-heavy professionals prepping for interviews.
- **Core value prop:** a 30-second pre-flight that checks exactly what ruins
  live sessions — jitter, loss, loaded-latency (bufferbloat grade), upload
  capacity, WiFi signal — and issues a go/no-go with fix hints ("move closer /
  switch channel", "your upload saturates at X, cap bitrate below Y").
- **Why it wins:** upload + jitter + loss + bloat + RSSI are all implemented;
  the composition is new UX, not new science. Eco variants (`bloat-eco`,
  ~100 KB) make it safe on hotel/hotspot links where a full test would burn
  capped data. Streamers are an audience that shares tooling publicly —
  organic distribution channel [UNCERTAIN — conversion behavior unmeasured].
- **Gaps to build:** bitrate recommendation logic (derivable from measured
  upload + jitter), one-click run flow, overlay/compact results card.

### Concept E — Metered-link companion (niche wedge, not standalone)

The eco module (~100 KB full diagnostics, <0.5 KB DNS check) is unusually
good for hotspot/travel/satellite/capped users. Standalone it is too narrow;
as a *mode* across A/B/D ("Trusted Diagnostics on metered links") it is a
differentiator none of the big speed-test brands emphasize.

---

## 2. Recommended primary concept

**Primary: Concept B — Home QoE Sentinel, with Concept A's evidence kit as the
flagship feature inside it, Concepts C/D as paid pro modules.**

Reasoning:

1. **Value is unconditional.** Turbo's benefit exists only under contention;
   monitoring, grading, diagnosing, and proving work on every line, every day.
   A product whose core promise fires 100% of the time retains better than one
   whose headline feature fires only during evening congestion [LIKELY].
2. **Asset fit is maximal.** The codebase's most finished, most tested surface
   is measurement + watch + history + export + GUI shell. Concept B is that
   surface with a menu bar icon and notifications — shortest credible path to
   a shippable v1.
3. **It carries the brand.** "Sentinel that tells you the truth, including
   when nothing is wrong" is the strongest possible expression of the honesty
   position (Section 3). An accelerator (C) monetizes honesty's credibility;
   it cannot establish it.
4. **Natural upsell ladder.** Free: manual tests + current grade. Pro:
   continuous watch, history beyond N days, evidence reports (A), Fair Share
   accelerator + fetch manager (C), pre-flight profiles (D). Each paid module
   maps to code that already exists.
5. **Risk profile.** It avoids depending on contested features (App Store
   review of anything resembling traffic manipulation is unpredictable
   [UNCERTAIN — M2 legal lane should assess]); monitoring/diagnostics is a
   well-trodden, defensible category.

Sequencing implication: ship B v1 (monitor + grade + notify + export), add
A's report generator as the first paid feature (highest perceived value per
line of code), then C and D as modules.

---

## 3. Positioning: honesty as the moat

The category is polluted. Consumers have been trained by "WiFi booster"/"RAM
cleaner"-style apps promising multiples of speed — physically impossible
claims, since the ISP-side cap is enforced upstream and no software can lift
it. NetMax's README leads with exactly this admission. That is the moat:

- **Competitors oversell; we can't be out-honest.** Any rival that copies the
  honesty stance validates ours; any rival that keeps scamming makes ours more
  valuable by contrast. Honesty is a one-way ratchet: once a user trusts the
  tool's bad news (a D grade, a dropout report), they trust its good news —
  and its recommendations.
- **Verifiable claims only.** Every marketing number traces to a logged,
  reproducible run (e.g., "+48% under contention, measured 2026-08, method in
  PROJECT_LOG"). Publish the methodology; invite verification.

Messaging angles:

1. **"The speed test that tells you the truth."** Anchor: admits caps, admits
   idle-line reality, reports dropouts instead of flattering percentages.
2. **"Proof, not promises."** For the ISP-dispute use case: bring evidence,
   not anecdotes. (Concept A language.)
3. **"Know which layer broke."** Radio / ISP / DNS / latency-under-load —
   layered diagnosis as the smart user's tool. (Concept B language.)
4. **"Fast when it's fair."** For Fair Share: standard TCP fairness, backs off
   automatically so your household doesn't suffer. Politeness as a feature.
5. **Anti-scam public education** as content marketing: explain why "10x"
   claims are impossible; publish the bufferbloat rubric; teach users to read
   their own grades. This earns search traffic and authority [LIKELY effective
   long-term; unmeasured].

Tone rule: never show a number we can't reproduce; never hide the conditions
of a gain. In-app copy should repeat the honest-limits framing the README
already nails.

---

## 4. Monetization options compared

| Option | Pros for THIS product | Cons for THIS product |
|---|---|---|
| **One-time purchase** (e.g., $20–40 tier [price unmeasured — requires willingness-to-pay testing]) | Fits episodic-utility perception; indie-Mac-friendly; no server obligation; matches "tool you own" trust story; simple refund policy supports honesty brand | One-shot revenue conflicts with continuous-monitor value (server-less watch is local, so ongoing cost ≈ 0 — acceptable); weak capture of high-intent pro users; every upgrade needs a new paid version |
| **Subscription** | Recurring revenue fits continuous sentinel value (it *runs daily*); funds future hosted features (multi-device history, report hosting) | Requires building real recurring value (backend, sync) before charging recurring money — otherwise feels like rent on a local tool; churn risk after "I fixed my WiFi" moments; trust-brand friction ("the honest app wants a sub?") |
| **Freemium + one-time Pro unlock** (recommended start) | Generous free tier (manual tests + current grade) is the honesty statement made tangible — the free tier *proves* the tool tells uncomfortable truths; Pro unlocks watch/sentinel, history depth, evidence reports, Fair Share, pre-flight — each mapped to existing code; no server costs initially since everything is local | Free tier must stay genuinely useful or trust story collapses; conversion rates unknown — must be measured (target metric: free→Pro %, to be established in beta); piracy trivial for local unlocks — accept it [LIKELY immaterial] |
| **Setapp-style bundle membership** | Instant access to an audience that pays for quality Mac utilities and skews prosumer — precisely Concept B/C's buyer; zero storefront/marketing spend to reach them; bundle curation itself signals legitimacy against scamware | Revenue share and no direct customer relationship (email, upsells); discovery inside the catalog is not guaranteed; exclusivity constraints may conflict with direct sales [terms to verify]; cannibalizes direct full-price sales somewhat |

**Recommendation:** launch freemium with one-time Pro unlock (local license),
add Setapp distribution once stable (non-exclusive), defer subscription until
a genuinely server-backed feature exists (e.g., cross-device history or
scheduled report email). Re-evaluate with beta data; no pricing number should
be committed before willingness-to-pay measurement.

---

## 5. Top strategic risks & mitigations

1. **Platform fragility (macOS API drift).** Already demonstrated internally:
   the `airport` binary vanished in recent macOS; `wdutil` needs sudo; SSID is
   privacy-redacted in some contexts. Future releases may remove more.
   *Mitigation:* confine OS access to a thin adapter layer; prefer documented
   interfaces (`system_profiler`, NetworkExtension/entitlements where needed);
   test every macOS beta in CI; degrade gracefully (show "unavailable" rather
   than wrong data — consistent with the honesty brand).
2. **Measurement-endpoint dependence & blocking.** Cloudflare's bot layer
   already 403-blocked the Python client (engine now shells to curl and
   fails over to OVH); upload echo endpoints have size/rate caveats. A dead
   endpoint = a dead speed test. *Mitigation:* keep multi-endpoint failover,
   add periodic endpoint health checks, diversify sinks, and consider
   self-hosted/lightweight measurement nodes at scale; review endpoint ToS
   compliance (M2 lane).
3. **Category skepticism (scamware halo).** Buyers burned by booster scams
   may dismiss NetMax on sight; stores may miscategorize it. *Mitigation:*
   name and copy never promise speed; lead with measurement/grading; publish
   methodology; harvest and showcase reviews that cite honesty; in-app
   "why we can't promise X" explainer converts skeptics.
4. **Conditional-value misunderstanding (refund/complaint risk).** Turbo/Fair
   Share gains occur only under contention; idle-line users see zero change.
   *Mitigation:* expectation-setting is mandatory in onboarding and store
   copy (the README language is ready-made); gate accelerator marketing behind
   "does someone else in your house stream?" self-qualification; in-app
   detection of contention state before suggesting turbo.
5. **Free-commodity perception.** Speed tests are expected to be free;
   differentiating "one number" tools is hard. *Mitigation:* sell memory,
   diagnosis, and evidence (things a one-shot web test structurally lacks),
   not the measurement itself; keep a best-in-class free tier as the wedge.
6. **Packaging/runtime debt.** Shipping Python + Tkinter + external `curl` as
   a consumer .app is fragile (code-signing, notarization, Gatekeeper,
   bundled interpreters). *Mitigation:* phase it — near term wrap the engine
   in a native Swift menu-bar shell calling the same logic; medium term port
   the measurement core to Swift/network.framework [effort UNCERTAIN — needs
   M5 architecture estimate]; keep the offline test suite as the port's spec.
7. **Single-platform concentration.** macOS-only caps the market and couples
   fate to one vendor. *Mitigation:* not a v1 problem; design the engine as a
   portable core (it mostly is: stdlib + curl) so Windows/Linux ports are a
   deliberate later bet, informed by macOS retention data.

---

## 6. What must be measured before committing (no fabricated numbers)

- Free→Pro conversion, price sensitivity (Van Westendorp or A/B price test in
  beta), refund rate by acquisition channel.
- Retention of watch-mode users vs manual-only users (validates the sentinel
  thesis).
- Contention-window frequency across beta households (sizes the Fair Share
  story honestly: "% of users with ≥1 h contended/day" — unknown today).
- Setapp economics fit (requires reading current terms; not assumed here).
- Support-deflection evidence: whether ISP-ticket reports generated by the
  evidence kit resolve favorably (case-study collection post-launch).
