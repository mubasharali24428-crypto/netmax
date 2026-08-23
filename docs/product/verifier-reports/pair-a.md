# Verifier Report — Pair A (Vertical A: Product Strategy × Feature Roadmap)

**Date:** 2026-08-23 · **Work dir:** `/Users/user/netmax-app` · **Baseline:** `8d12548`
**Lanes:** M1 `docs/product/01-product-strategy.md`, M4 `docs/product/04-feature-roadmap.md`
**Method:** Pass 1 (sub verifier) mechanical sweep with raw evidence first; Pass 2 (prime verifier)
classification + in-lane fixes. No builder self-report was read before Pass 1 completed.

---

## PASS 1 — Mechanical sweep (raw evidence)

### 1.1 Git footprint

```
$ git status --short
?? docs/product/01-product-strategy.md
?? docs/product/03-market-analysis.md
?? docs/product/04-feature-roadmap.md
?? docs/product/05-app-architecture.md
$ git log --oneline -2
8d12548 mission graph + verifier brief (docs-only analysis mission)
5cd59d5 version bump 0.5.0
```

Footprint matches ownership: my lanes are the two untracked files named in the
vertical; `03` / `05` belong to other pairs and were not touched.

### 1.2 Test suite rerun

```
$ /Users/user/1/bin/python -m pytest -q | tail -3
........................................................................ [ 91%]
.............                                                            [100%]
157 passed in 8.05s
```

Known-good confirmed: **157 passed**, not the README's claimed number.
Brief said "README says 201" — direct check: README.md line 67 actually says
**68** offline tests ("68 offline tests (network fully mocked — safe to run
anywhere)"). So there are two stale test-count claims in circulation (README=68,
builder M4 header=201); measured ground truth is **157**. Recorded as MINOR;
both occurrences inside my lanes were fixed in-lane (see §3). The README itself
is outside my lanes — flagged for Pair B/C or the parent squad.

### 1.3 Anti-synthesis scan

```
$ grep -nE 'TODO|FIXME|TBD|placeholder' docs/product/01-product-strategy.md docs/product/04-feature-roadmap.md
(no output; exit code 1 = zero matches)
```

Clean — no placeholder language in either lane.

**Module/function/CLI-mode name inventory** (every name cited in either doc,
each verified against repo source):

| Name cited | Where cited | Verified at |
|---|---|---|
| CLI modes `baseline/turbo/boost/dns/bloat/full` | M1 §0; M4 §foundation, N5, N6(X6), L4 | `netmax.py:462-469` MODE_HELP dict |
| CLI modes `upload/loss/jitter/wifi/export/watch/fetch/bloat-eco/eco_dns path` | M1 §0; M4 foundation | `netmax.py:351,358-371,429-436`; `netmax_eco.py:81 eco_dns()` |
| `--streams`, `--seconds` flags | both docs | README examples; `netmax.py` argparse |
| OVH→Cloudflare failover | M1 §0 "OVH→Cloudflare endpoint failover"; M1 §5 risk 2 | `netmax.py:26-33`: `ENDPOINTS = [("OVH", proof.ovh.net/files/100Mb.dat), ("Cloudflare", ...)]` with comment "OVH's static test file leads and CF is the fallback" |
| curl vs urllib TLS-fingerprint block | M4 foundation table | `netmax.py:23-25` comment; PROJECT_LOG root cause 3 |
| Cloudflare `__down` >~50 MB → HTTP 403 | M4 "Known engine facts" | PROJECT_LOG root cause 1 verbatim |
| Cloudflare `__up` verified fastest upload endpoint | M4 foundation | `netmax_upload.py:18-22` "confirmed live 2026-08-22 … speed.cloudflare.com/__up" |
| NXDOMAIN valid latency sample | M4 engine facts | PROJECT_LOG root cause 2 verbatim |
| zero-throughput dropouts never faked | both docs | PROJECT_LOG root cause 4; README Honest limits |
| `AdaptiveController` backoff >300 ms / >2% loss | M1 §0, Concept C | `netmax_throttle.py:3,19 class AdaptiveController` |
| resumable byte-range parts + manifest | M1 §0 Concept C | `netmax_fetch.py:5-6` ".netmax-part-N files plus a .netmax-meta.json manifest" |
| `watch_loop`, `summarize_watch_history` | M1 §0 | `netmax_watch.py:13`; `netmax.py:490` |
| `history.json`, `results.json`, `results.png` | both docs | `measure.py:2,23,82,131` |
| `system_profiler SPAirPortDataType`, airport removed, wdutil sudo | M1 §0 debts, §5 risk 1; M4 X1 note | `netmetrics.py:67-71` |
| packet loss %, jitter RTT-delta, RSSI/noise/channel | M4 foundation (`netmetrics.py`) | `netmetrics.py:26 packet_loss, 43 jitter_ms, 64 wifi_info` |
| GUI isolated subprocess + `root.after` marshalling | M4 foundation; N9 base | `netmax_gui.py:4-6,13,147,163`; PROJECT_LOG §agent notes |
| `netmax_export.py` CSV/JSON export | both docs | `netmax_export.py:27,46 export_results` |
| eco ~100 KB bloat / <0.5 KB DNS | M1 Concepts D/E; M4 foundation | `netmax_eco.py:9-15,35` (~101 KB default; <0.5 KB DNS) |
| Waveform-style A+–F bufferbloat rubric | M1 §0; M4 X6/N5 | `netmax.py:474 GRADE_ORDER = ["A+","A","B","C","D","F"]`; README line 7 |
| +48% contended turbo result (28.3→42.0 Mbps) | M1 ×4 citations | PROJECT_LOG verified-results table, identical figures |
| Cloudflare fastest DNS ~50–54 ms vs system 63–68 ms | M1 §0 | PROJECT_LOG DNS ranking row, identical figures |

Every name resolves. Zero fabricated module/mode references found.

**Unhedged statistics sweep:** every quantitative claim in either doc is either
source-traceable (the +48%, 28.3→42.0, ~50–54 ms, ~101 KB items above), explicitly
hedged ([LIKELY]/[UNCERTAIN] markers on market claims, "[price unmeasured]",
"conversion rates unknown", Section 6 "no fabricated numbers"), or presented as
a design parameter (notification thresholds, ≤150 MB bundle size). No unhedged
market/statistic assertion found.

### 1.4 Line counts

```
$ wc -l docs/product/01-product-strategy.md docs/product/04-feature-roadmap.md
     268 docs/product/01-product-strategy.md
     253 docs/product/04-feature-roadmap.md
```

Both ≥150 ✅ (re-checked post-fix: 268 / 254).

---

## PASS 2 — Prime verifier judgment

### 2.1 Seam contract conformance (M1 recommended concept == M4 NOW scope)

M1 §2 (01-product-strategy.md:128-129):

> **Primary: Concept B — Home QoE Sentinel, with Concept A's evidence kit as the
> flagship feature inside it, Concepts C/D as paid pro modules.**

…with the sequencing implication (:154-156): "ship B v1 (monitor + grade +
notify + export), add A's report generator as the first paid feature … then C
and D as modules."

M4 NOW (§2) scopes exactly that:

- Sentinel core: **N3** menu-bar presence, **N4** scheduled background tests,
  **N6** degradation notifications, **N8** history trends view (= B's "monitor +
  grade + notify + history").
- Evidence kit as flagship paid feature: **N5** ISP comparison report card,
  **N7** PDF report & share sheet (= A's report generator).
- v1.0 exit bar (:121): "N1–N9 shipped; N10 decided…" — C/D modules correctly
  deferred to NEXT/LATER (X-series/L-series), matching M1's "then C and D as
  modules."

**Verdict: CONFORMANT.** The seam holds bidirectionally — nothing M4 puts in NOW
lacks an M1 mandate, and M1's recommendation is fully covered by M4 NOW+N10.

### 2.2 Integration probe — cross-claim table (7 probes ≥5 required)

| # | Claim | M1 loc | M4 loc | Verdict |
|---|---|---|---|---|
| 1 | Contention gain "+48% (28.3→42.0 Mbps)" real and reproducible | :16, :87-88, :92, :173 | foundation row `turbo/boost` implies same capability | **agree** — matches PROJECT_LOG exactly; M4 doesn't restate the number (no conflict) |
| 2 | Endpoint posture: Cloudflare blocks non-curl clients; multi-endpoint failover required | §5 risk 2 (:223-229) "engine now shells to curl and fails over to OVH"; "403-blocked" | foundation row `netmax.py`: "curl-based probes (urllib is TLS-fingerprint-blocked by Cloudflare…)"; engine facts: "__down >~50 MB (HTTP 403)" | **agree** — all three facets match source (`netmax.py:23-33`, PROJECT_LOG rc 1&3) |
| 3 | Upload probe endpoint fact | §0 :19 "curl POST" under upload/loss/jitter/wifi row | foundation: "Upload probe (curl POST; Cloudflare `__up` verified fastest)" | **agree** — `netmax_upload.py:18-22` confirms both |
| 4 | WiFi telemetry fragility (airport gone → system_profiler; wdutil sudo ruled out) | §0 debts :34-37; §5 risk 1 | foundation row `netmetrics.py` "(airport binary is gone on modern macOS)"; X1 [UNCERTAIN] spike note re wdutil/CoreWLAN | **agree** — consistent with each other and `netmetrics.py:67-71` |
| 5 | Eco/data-frugal budgets (~100 KB bloat, <0.5 KB DNS, ~1% of budget) | §0 :23; Concept D :110-111; Concept E :119 | foundation row `netmax_eco.py` "Eco mode" (no numbers restated) | **agree** — no numeric conflict; source confirms M1's figures |
| 6 | Test-suite size | §0 :25 originally "**68 offline tests**" | header :4 originally "**201 offline tests**" | **conflict** — mutually inconsistent AND both differ from measured truth (157). FIXED in-lane (§3). |
| 7 | Effort ratings vs scope realism | §2 sequencing: B-v1 then A-report as "highest perceived value per line of code" | N5 effort S (report card), N7 M (PDF), N8 S (trends), menu-bar/scheduler M | **agree** — M4's S-ratings for the flagship evidence features are consistent with M1's cheap-first sequencing logic; no scope contradiction |

### 2.3 Classification

- **BLOCKER:** none. No fabricated content (all names/stats trace to repo),
  no core-recommendation contradiction (seam conformant), both files ≥150 lines.
- **MAJOR:** none.
- **MINOR (fixed in-lane):**
  1. M4:4 "201 offline tests" → measured truth 157. Fixed with verification date
     and provenance note.
  2. M1:25 "68 offline tests" (inherited from stale README) → fixed to 157 with
     suite composition note.
- **Out-of-lane flag (not mine to edit):** README.md:67 still says "68 offline
  tests" — stale vs the current 9-file suite (55 engine + 44 GUI tests alone).
  Recommend parent squad update README in its own pass.
- SUSPICION (unverifiable from repo alone, hedged appropriately by builders
  already): M1's "no mainstream consumer tool owns continuous honest QoE grading
  on macOS [LIKELY]" — correctly gated on M3 market scan; no action needed here.

### 2.4 Fixes applied + regression rerun

Edit 1 — `docs/product/04-feature-roadmap.md` header:

```
-capabilities below marked "existing" are real and covered by 201 offline tests.
+capabilities below marked "existing" are real and covered by 157 offline tests
+(verified via pytest rerun 2026-08-23; README's "68" predates the v0.4 diagnostic suites).
```

Edit 2 — `docs/product/01-product-strategy.md` §0 table:

```
-| Test discipline | 68 offline tests | Passing; network fully mocked |
+| Test discipline | 157 offline tests | Passing; network fully mocked (pytest rerun 2026-08-23; engine + GUI + per-module suites) |
```

Post-fix rerun:

```
$ /Users/user/1/bin/python -m pytest -q | tail -2
.............                                                            [100%]
157 passed in 7.92s
$ wc -l docs/product/01-product-strategy.md docs/product/04-feature-roadmap.md
     268 docs/product/01-product-strategy.md
     254 docs/product/04-feature-roadmap.md
```

No behavioral surface touched (docs only); suite green.

---

## Verdict

Lane M1: clean after one MINOR fix. Lane M4: clean after one MINOR fix.
Seam contract: CONFORMANT. No blockers.

READY-TO-MERGE
