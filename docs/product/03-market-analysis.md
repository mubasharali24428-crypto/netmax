# 03 — Market & Competitor Analysis: NetMax-derived macOS Network-Health App

**Sub-03, market analysis squad · Aug 23, 2026**
**Scope:** consumer/prosumer macOS network-health app derived from the NetMax v0.5
fork (honest bandwidth maximizer + diagnostics toolkit: baseline/turbo probes,
parallel-stream contention gain, DNS ranking, bufferbloat grade A+–F, loss /
jitter / WiFi / upload diagnostics, CSV/JSON export, continuous `watch` monitor).

> **Method note.** Competitor facts below are grounded in what I know reliably
> from training data; nothing is scraped or measured live. Where a product's
> current state may have shifted (pricing, ownership, feature set), it is
> flagged **[UNCERTAIN]**. No download counts, revenue figures, or analyst-market
> stats are cited anywhere — deliberately: those are the numbers most likely to
> be fabricated, and qualitative reasoning is more decision-useful here anyway.
> All pricing "benchmarks" in §5 are approximations from memory, not quotes.

---

## 1. Competitor map across adjacent categories

No single product occupies the exact position we're aiming at. The landscape is
five adjacent rings, each with strong tools that stop one ring short of us.

### 1a. Mainstream speed-test apps

| Product | What it does well | Weakness / gap |
|---|---|---|
| **Ookla Speedtest** (macOS app + speedtest.net) | The default mental model for "how fast is my internet." Huge server network → results feel authoritative; ping/jitter/download/upload in one tap; history of past runs. | One-shot snapshot, not continuous. Measures the pipe; does nothing to change your share of it under contention. Brand is so tied to "the number" that it can't tell you *why* Zoom stutters while the number looks fine. [UNCERTAIN: current feature drift between the free app and paid tiers.] |
| **Cloudflare Speed Test** (speed.cloudflare.com) | Clean, ad-free, trustworthy backend; measures latency under load and sustained throughput rather than burst peaks; increasingly the "honest" reference testers cite. | Web-only, no resident app, no monitoring over time, no remediation. Our own baseline probe already uses its endpoint — we inherit its credibility but must not hammer it (see PROJECT_LOG root cause #1: >~50 MB payloads get 403'd). |
| **Netflix Fast.com** (+ the broader fast.com ecosystem) | Zero-friction: loads instantly, one number, ISP-neutral (peered with Netflix CDN). The tool non-technical people actually open when the internet feels slow. | Deliberately minimal — download-focused first, everything else an afterthought. No diagnosis, no history worth acting on, no notion of contention. It answers "is the plan slow?" but never "is my household the problem?" |

**Takeaway:** this ring owns *awareness* ("test my speed") but stops at the
measurement. Nobody here monitors continuously, grades bufferbloat for
normals, or tells you what to do next.

### 1b. WiFi analyzers / scanner-class tools

| Product | What it does well | Weakness / gap |
|---|---|---|
| **WiFi Explorer** (Adrian Granados) | The prosumer standard on macOS: channel occupancy, signal/noise (RSSI/SNR), band and channel-width detail, scan export. Respected because it shows raw reality without upsell. | Purely passive RF observation. Tells you channel 11 is crowded but not what your throughput *becomes* when it is; no QoE scoring, no remediation, no ongoing record. |
| **AirPort Utility** (with the hidden scan mode) | Free, Apple-signed, surprisingly decent AP/channel view once you enable the undocumented scan mode. | Effectively unmaintained for this purpose; hidden feature = zero discoverability; only meaningful with Apple networking hardware. |
| **iStumbler-class tools** (iStumbler and similar freeware scanners) | Quick "what networks are around me" answer; long heritage as the Mac community's free scanner. | Aging codebases, sporadic maintenance [UNCERTAIN: current release cadence], RF-view only, no performance layer at all. |

**Takeaway:** analyzers see the *radio environment*; they never connect it to
experienced quality. Our `wifi` diagnostic (RSSI/noise/channel) puts us in this
ring technically, but our differentiator is joining it to throughput and QoE.

### 1c. Bufferbloat / QoE measurement tools

| Product | What it does well | Weakness / gap |
|---|---|---|
| **Waveform Bufferbloat Test** (web app) | The best-known consumer bufferbloat test; popularized the A+–F grading rubric our engine already uses; measures latency under load, which is the metric that actually predicts video-call quality. | One-shot web test again. Grades the line but doesn't watch it across a workday; no per-app or per-hour breakdown; no memory of yesterday's 4pm collapse. |

**Takeaway:** Waveform proved normals will engage with a graded QoE score if
you make it legible (letter grades). That's validation of the rubric choice,
and also a warning: a grade alone, delivered occasionally, is a novelty, not a
product.

### 1d. Power-user tools

| Product | What it does well | Weakness / gap |
|---|---|---|
| **Little Snitch** (Objective Development) | The gold standard for outbound-connection visibility on macOS; beloved, durable franchise; demonstrates that Mac users will pay real money for a well-crafted network utility. [UNCERTAIN: current version pricing/details.] | Purpose is security/privacy, not link quality. Zero interest in throughput, contention, or QoE. Adjacent proof-of-willingness-to-pay more than a competitor. |
| **iPerf** (and iPerf3) | The engineer's ground truth for achievable throughput between two endpoints; scriptable, precise, free. | Two-endpoint setup (needs a server), CLI-only, meaningless to normals. We compete for attention, not capability. |
| **Network Utility** (macOS built-in) | Free, preinstalled; basic lookup/ping/traceroute/netstat surface. | Frozen-in-time utility; Apple has visibly deprioritized it; no measurement, no interpretation, no advice. |
| *(honorable mention)* **Wireless Diagnostics** (macOS built-in) | Hidden gem: real per-AP logging, RSSI/SNR history, channel recommendation — if you know Option-click the WiFi icon. Undiscoverable, unsummarized, gone tomorrow. | Its existence proves Apple knows this data matters and chose not to productize it for normals. That gap is our opening. |

### 1e. "Internet booster" scamware — the ring we differentiate FROM

The Mac App Store and download sites carry a persistent genre of "booster,"
"accelerator," "WiFi speed magic" utilities promising large multiples of
speed. Physically impossible claims (an app cannot exceed the ISP cap), dark
patterns, subscription traps, fake before/after gauges. This category poisons
the well: any product with "maximizer" in the name inherits suspicion.

NetMax's entire positioning is the anti-scamware stance:

- README leads with **"Honest limits — read this first"**: cannot exceed the
  ISP cap; gains appear only under contention; router QoS overrides all.
- Dropouts are reported as dropouts, never laundered into a flattering gauge.
- Every claim in PROJECT_LOG.md is backed by a verified mechanism (N parallel
  fair TCP streams claiming a bigger share during contention — +48% in a
  contended window on a real line — and honest ~0% expectation on idle lines).

This is the core marketing asset: **the only maximizer that tells you the truth
about maximizers.** Scamware makes honesty a positioning moat, because the
first thing a skeptical reviewer checks is whether we admit the cap. We do,
prominently.

---

## 2. Gap analysis: what nobody combines

Across all five rings, no mainstream product combines these four things:

1. **Continuous QoE monitoring.** Every mainstream tool above is episodic — a
   test you run when something already feels wrong. Nobody watches the line
   across the workday and can say "your calls degrade every weekday ~3–4pm;
   here's the packet-loss signature." NetMax's `watch` mode is exactly this
   primitive; nobody packages it for normals.
2. **An honest "maximizer" framing.** Contention-share improvement via parallel
   fair TCP streams is real but conditional, so honest framing is mandatory —
   which is precisely why the scamware-infested "booster" category has left
   the *framing* vacant. The first credible player to say "we can win you a
   bigger share of a busy pipe, and nothing can beat your cap" owns the
   trustworthy-maximizer position by default.
3. **ISP accountability reporting.** Everyone measures; nobody adjudicates.
   The natural output of continuous monitoring is a documented, exportable
   history: "here are six weeks of graded measurements showing your evening
   throughput fell short of provisioned rate N times" — the artifact you
   attach to a support ticket, an upgrade-refusal pushback, or an FCC-style
   complaint. Position it as documentation, never as certified evidence
   (copy discipline per 02-legal-barriers §2.3/§6.4).
   No mainstream consumer tool generates that report today.
4. **Diagnosis → explanation → action in one place.** Today the journey is
   fragmented: Fast.com says "slow," WiFi Explorer says "channel congested,"
   Waveform says "grade C bufferbloat," and the user assembles the story
   themselves. The gap is the synthesis layer — one app that turns raw
   diagnostics into "your neighbor's AP is on your channel and your router
   buffers; switch channels and enable SQM" style conclusions.

**Strategic read:** items 1–3 are mutually reinforcing and map directly onto
features already built or specced in this fork (`watch`, turbo/boost with
honest limits, `export`). Item 4 is the hardest and the true moat.

---

## 3. Target segments, ranked

Ranked by expected fit × willingness to pay (qualitative reasoning, no market-
size numbers):

1. **Remote workers / hybrid knowledge workers.** Their income literally rides
   on call quality; they already pay for tools that remove friction (focus
   apps, VPNs, better webcams). Bufferbloat grade + dropout log speaks their
   language ("will my 2pm standup survive?"). High WTP for anything that ends
   the "you're on mute / you froze" blame cycle. Likely best early adopters:
   they self-diagnose, read blogs, install utilities unprompted.
2. **IT prosumers / sysadmin-adjacent power users.** Lowest friction to adopt
   (they'll take the CLI happily), highest credibility influence — they write
   the forum posts and reviews normals trust. Moderate direct WTP (expect to
   pay $20–50-ish once for a good tool), outsized advocacy value. Also the
   harshest critics of any overclaim — which our honest-limits stance survives.
3. **Gamers / streamers.** Latency, jitter, and loss are their native metrics;
   they understand contention immediately. But: heavy overlap with Windows,
   strong free-tool culture, and many already have router-side solutions.
   WTP exists but skews lower and is fickle; treat as amplification segment
   (streamer coverage) more than revenue core.
4. **WFH households.** The contention scenario is *their* daily life (two
   people on calls, kids streaming). Turbo-mode gains are most real here.
   But they're the least technical: need a polished GUI, plain-language
   verdicts, and likely buy via bundle/App Store discovery rather than
   direct download. Higher WTP than gamers but higher support/UX cost too.
5. **Small offices (<10 people, no dedicated IT).** Real pain (shared pipe),
   real budget authority, but longest sales consideration and expectations of
   support SLAs. Better served later, possibly via a team tier, than chased
   at launch.

**Implication for sequencing:** lead with segments 1–2 (self-serve, credible,
vocal), design the GUI for 4, keep 5 as a future tier.

---

## 4. Distribution channels compared

| Channel | Reach | Friction (user side) | Revenue share / economics | Notes |
|---|---|---|---|---|
| **Mac App Store** | Largest discoverable surface; the only store normals browse for utilities. | Lowest for buyers (one click, trusted billing); BUT sandboxing constrains deep network diagnostics — raw sockets, packet capture, and some system-level probing are limited or awkward under MAS rules. | ~70/30 split in Apple's favor (standard terms; small-business program lowers it — details [UNCERTAIN]). | Best for a simplified "monitoring + verdicts" SKU; worst place for the full-power diagnostics edition. Risk: sitting beside the scamware boosters we differentiate from — mitigated by honest copy and review velocity. |
| **Notarized direct download** | Near-zero organic reach; depends entirely on our content/community/marketing. | Moderate: Gatekeeper warning on first run is much milder post-notarization, but still a trust step for normals; manual updates unless we build a Sparkle-style updater. | ~100% minus payment processing (~3–5%). | Required for the full-power edition (no sandbox). Highest margin, total control of trial/licensing, but we own all acquisition cost. Natural home for the prosumer/pro editions and the CLI story. |
| **Setapp** (subscription bundle) | Instant access to a large installed base of exactly our audience — people who already pay monthly for curated Mac utilities. | Lowest possible for subscribers (included in membership); zero purchase decision. | Revenue share of the Setapp pool based on usage; per-member economics are opaque to outsiders [UNCERTAIN]; effectively indirection revenue, not list-price revenue. | Unmatched low-friction reach for segments 1 & 4; weak brand-building (users remember Setapp, sometimes not the app). Acceptance requires quality bar and exclusivity considerations — terms [UNCERTAIN]. |

**Recommended posture:** two-track. Ship the **full diagnostics edition
direct** (notarized, own licensing, keeps ~100%), and put a **sandbox-friendly
monitoring edition on MAS + Setapp** for reach. Setapp first among the two
store channels: its user base self-selects for utility-paying behavior, while
MAS listing mainly buys credibility and search presence for normals.

---

## 5. Pricing benchmarks (approximations, not quotes)

All figures below are rough ranges typical for Mac network/system utilities as
I recall them; treat as hypothesis inputs for price testing, not market data.

- **One-time purchase, single utility** (scanner-class, small tools): roughly
  **$10–30**. Below ~$10 signals toy; above ~$40 one-time needs a strong name.
- **Prosumer professional tools** (WiFi Explorer-tier, Little Snitch-tier):
  roughly **$20–60**, sometimes with major-version paid upgrades. Little
  Snitch's durability shows the ceiling is real if the tool becomes essential.
- **Subscription models** exist in this space but are resented for simple
  utilities; where subscriptions stick, it's for services with ongoing value
  (continuous monitoring + cloud sync/history is plausibly "ongoing").
- **Freemium pattern that fits us:** free = on-demand tests (baseline, bloat
  grade, DNS ranking); paid = continuous watch, scheduled reports, ISP
  accountability exports, history beyond N days. This mirrors how the market
  pays elsewhere: pay for *memory and automation*, not for the measurement.
- **Setapp economics** fold into the bundle pool — plan for meaningfully less
  per-user revenue than direct list price, in exchange for volume and zero
  acquisition cost [UNCERTAIN on current per-dev payout mechanics].

**Suggested starting frame for testing:** free core + ~$29 one-time Pro (or
$19 launch pricing) + optional small monthly for cloud history/reporting —
then let waitlist/conversion data (§6) argue for adjustments. Note: any
server-side cloud-history component crosses out of the strictly-local privacy
posture into the compliance surface described in 02-legal-barriers §3.2
(lawful basis, consent-by-default-off, policy disclosures) — treat that tier
as a deliberate privacy-posture decision, not just a pricing line item.

---

## 6. Go / no-go signals to gather cheaply before committing

Evidence worth buying before writing another line of shipping code, cheapest
first:

1. **Landing page + waitlist** (days of work): one page stating the honest
   pitch verbatim from our README ("can't exceed your cap; wins you a bigger
   share when contended"). Measure signup rate from targeted communities.
   *Go signal:* double-digit % of visitors joining a waitlist from niche
   traffic; *no-go:* traffic converts near zero even with honest framing
   sharpened twice.
2. **Community soundings** (free): post the bufferbloat-grade screenshots and
   the +48% contention result as a story (not a sales pitch) in r/mac, r/sysadmin,
   HomeNetworking forums, HN Show. Watch for: organic "shut up and take my
   money," vs. polite indifference, vs. "scamware" reflexes that survive the
   honest framing. The last one would be fatal to the whole positioning and
   should kill or rename the concept early.
3. **Free-tier analytics on the page** (any privacy-respecting analytics):
   time-on-page and scroll-depth on the *honest limits* section specifically.
   If readers who hit the limits section convert as well as or better than
   those who don't, honesty is an asset, not friction — that validates the
   brand thesis.
4. **Manual concierge test** (~zero code): offer 10–20 remote workers a free
   one-week "connection report card" generated by running the existing CLI
   suite (`watch` + `export`) on their machines and hand-writing the summary.
   If recipients find the report valuable enough to ask for recurring versions,
   the ISP-accountability feature has demand; if they shrug, the flagship
   differentiator needs rethinking *before* it's built into UI.
5. **Pricing smoke test:** after waitlist reaches a few hundred, email a
   mock-checkout survey (two price points, fake "preorder" button measuring
   click intent, clearly labeled as preorder interest). Click-through delta
   between price points is directional WTP evidence without taking money.

**Kill criteria (explicit):** fewer than a trickle of waitlist signups despite
two messaging iterations AND negative/neutral community response to the honest
framing AND concierge-test participants not wanting recurrence ⇒ treat the
consumer app as no-go; the tech remains salvageable as an IT/prosumer CLI or
open-source project.

---

## Bottom line

The competitive field is crowded with *measurement* and empty of
*accountability*. Ookla/Cloudflare/Fast own the one-shot number; analyzers own
the RF view; Waveform owns the grade; scamware owns (disgracefully) the word
"booster." The unclaimed position — **continuous, honest, evidence-producing
network health for people whose work depends on the connection** — matches the
fork's existing capabilities (watch, export, bloat grade, honest turbo) almost
feature-for-feature. The main risks are discoverability outside the App Store
ecosystem and the scamware taint on the category's vocabulary; the honest-
limits branding attacks both simultaneously.
