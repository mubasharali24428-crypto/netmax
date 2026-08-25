# NetMax 10× — Upgrade Potential & Plan

> W6 joint deliverable. Baseline @ `415f7dc`: 6-tab macOS menu-bar app, 10
> measurement modes, scheduled auto-tests + launchd runner, degradation alerts,
> anomaly detection, bufferbloat storytelling, QoE timeline (wiring pending),
> PDF report cards, CSV/JSON export, diagnostics bundle, distribution pipeline.
> Suite: 177 tests. Zero backend infrastructure by design.

---

## Tier 1 — 10× REACH (10× the users)

| # | Item | Effort | Deps |
|---|---|---|---|
| R1 | Apple Developer account ($99) → run notarize.sh → public DMG | S | money only |
| R2 | Landing website: honest-limits positioning, FEATURES.md as body, download link | M | R1 |
| R3 | Mac App Store submission (sandboxed variant) | L | R1; launcher/launchd redesign |
| R4 | Windows companion (engine ports via curl core; WiFi telemetry needs adapter) | XL | engine abstraction layer |
| R5 | Localization (i18n pass over all user-facing strings) | M | string externalization |

**Sequence:** R1→R2→R5 parallel; R3 after R2 validates demand; R4 last.

## Tier 2 — 10× CAPABILITY (10× what it can do)

| # | Item | Effort | Deps |
|---|---|---|---|
| C1 | Finish X1 wiring: Timeline sub-tab in History + ScheduleRunner emits wifi events post-run | S | none — ships next pass |
| C2 | Plugin mode registry (decorator-based registration in netmax.py) → third-party modes without core edits | M | none |
| C3 | Multi-device paired probes (LAN discovery, consent pairing, shared event schema) | L | C2 optional |
| C4 | Router-aware insights: DHCP/UPnP fingerprint → known-issue notes (roadmap X2) | L | — |
| C5 | Per-app bandwidth attribution during tests (X4; needs permission spike) | L | — |
| C6 | Optional encrypted cloud sync of history (L2; opt-in, anonymized crowd tier later) | XL | privacy policy |
| C7 | ML diagnosis on labeled corpus (L5) — only when it beats rule-based baseline | XL | C3+C6 data |

## Tier 3 — 10× POLISH (10× quality/delight)

| # | Item | Effort | Deps |
|---|---|---|---|
| P1 | Surface ⌘-shortcuts: tab tooltips + Settings shortcuts row | S | none |
| P2 | Onboarding polish: first-run sample-data tour, feature discovery cards | M | — |
| P3 | Notification digests (daily summary instead of per-event pings) | S | N6 |
| P4 | Menu-bar popover mini-timeline sparkline | M | C1 |
| P5 | Report card v2: trend arrows vs personal baseline, shareable web link (local render) | M | — |
| P6 | Full a11y audit round 2 (VO walk every surface) + contrast re-check | M | — |

## Honest physics — what cannot be 10×'d

Per the brand this product is built on:
- **Cannot raise your ISP cap.** No software can. NetMax measures and proves;
  it does not and will not promise throughput beyond your plan/radio physics.
- **WiFi radio performance** is bounded by spectrum, distance, interference.
- **Measurement accuracy** is bounded by methodology (parallel-stream fairness,
  latency-under-load), which we already implement honestly.
Everything else — reach, capability, polish — has clear headroom above.

## Sequencing recommendation

Next 3 passes (highest payoff density):
1. **C1** timeline wiring (S) + **P1** shortcuts surfaced (S) + **R1/R2** account+site
2. **P2/P3/P5** polish cluster
3. **C2** plugin registry → opens community-mode ecosystem (the real capability multiplier)

Then reassess: C3/C4 for capability moat, R3/R4 for reach expansion.
