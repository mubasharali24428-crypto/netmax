# AI Refinements — 105 Ways Intelligence Levels Up NetMax

Companion to `suggestions-100.md` (general product). Everything here is AI/ML-specific.
Effort: S (<1 day) · M (~1–3 days) · L (~1–2 weeks) · XL (multi-week). Impact 1–5.
Status: DONE = shipped · NOW = this session · NEXT = queued.

## A. Diagnosis & root-cause reasoning (AI-001–012)

| ID | Title | Why it matters | Effort | Impact | Status |
|----|-------|----------------|--------|--------|--------|
| AI-001 | Counterfactual "what-if" answers ("would fq_codel fix my grade?") | Turns diagnosis into decisions | M | 5 | NEXT |
| AI-002 | Multi-metric causal attribution (loss vs WiFi vs ISP) | One blame, not three suspects | M | 5 | NEXT |
| AI-003 | Natural-language root-cause paragraph per run | Users quote it to their ISP | S | 4 | NEXT |
| AI-004 | Confusion-pair disambiguation (congestion vs throttling vs WiFi) | The #1 misdiagnosis trio | M | 5 | NEXT |
| AI-005 | Evidence-linked verdicts (every claim cites a metric) | Trust without blind faith | S | 4 | NEXT |
| AI-006 | Second-opinion mode (two analysers must agree) | Kills single-model hallucinations | S | 4 | NEXT |
| AI-007 | Diagnosis confidence calibration (stated %, measured %) | Honest uncertainty | M | 4 | NEXT |
| AI-008 | Historical precedent lookup ("seen 3× before, was X") | Your own data as prior | M | 4 | NEXT |
| AI-009 | Cross-run differential diagnosis (what changed since last good) | Degradation explained, not just flagged | M | 4 | NEXT |
| AI-010 | ISP-throttling signature library (time-of-day + pattern match) | Names the unnameable | L | 4 | NEXT |
| AI-011 | WiFi-vs-WAN split verdict with separate grades | Tells you which half to fix | M | 4 | NEXT |
| AI-012 | "Ask a follow-up" on any diagnosis | Diagnosis becomes conversation | S | 3 | NEXT |

## B. Forecasting & prediction (AI-013–024)

| ID | Title | Why it matters | Effort | Impact | Status |
|----|-------|----------------|--------|--------|--------|
| AI-013 | 24h speed forecast with bands ("expect 180–240 Mbps at 8pm") | Plan big downloads | M | 4 | NEXT |
| AI-014 | Congestion-window prediction (worst hour tomorrow) | Avoid, don't endure | M | 4 | NEXT |
| AI-015 | Scheduled-test outcome pre-estimate | Skip doomed runs | S | 3 | NEXT |
| AI-016 | Plan-adequacy forecast ("your plan fails WFH Fridays") | Upgrade advice with proof | M | 4 | NEXT |
| AI-017 | Bufferbloat forecast under predicted load | Gaming sessions planned safe | M | 3 | NEXT |
| AI-018 | Quantile forecasts (p10/p50/p90), never point-only | Honest ranges | S | 4 | NEXT |
| AI-019 | Forecast accuracy ledger (predicted vs actual, per horizon) | Forecasts that grade themselves | S | 4 | NEXT |
| AI-020 | Seasonal decomposition view (trend/seasonal/residual) | See the pattern, not just numbers | M | 3 | NEXT |
| AI-021 | Event-aware forecasts (match nights, holidays, outages) | Context beats naive seasonality | L | 3 | NEXT |
| AI-022 | Cold-start forecasts for new networks (population priors) | Useful from run #1 | L | 3 | NEXT |
| AI-023 | "Best hour to…" advisor (call, upload, game, stream) | Forecast as feature | S | 4 | NEXT |
| AI-024 | Degradation early-warning (48h ahead, with cause) | Fix before the meeting drops | L | 5 | NEXT |

## C. Anomaly detection & smart alerts (AI-025–034)

| ID | Title | Why it matters | Effort | Impact | Status |
|----|-------|----------------|--------|--------|--------|
| AI-025 | Reconstruction-error anomaly score per run | Catches what thresholds miss | M | 4 | NEXT |
| AI-026 | Adaptive per-network thresholds (no global magic numbers) | New SSID, new normal | M | 4 | NEXT |
| AI-027 | Alert fatigue guard (one alert per cause, auto-merge) | Alerts stay meaningful | S | 4 | NEXT |
| AI-028 | Anomaly explanations in plain words ("2.1σ below your Tuesday norm") | No statistics degree needed | S | 4 | NEXT |
| AI-029 | Collective-anomaly detection (slow 3-day slides, not just spikes) | Drift is the silent killer | M | 4 | NEXT |
| AI-030 | Point-vs-contextual anomaly labels | Different causes, different fixes | S | 3 | NEXT |
| AI-031 | False-alarm feedback ("not an issue" trains your thresholds) | Alerts learn manners | M | 4 | NEXT |
| AI-032 | Correlated-anomaly grouping (loss+jitter+speed as one incident) | One incident, one alert | M | 4 | NEXT |
| AI-033 | Scheduled-run failure triage (transient vs real, auto-retry) | Fewer 3am false pages | S | 3 | NEXT |
| AI-034 | Outage auto-declaration (all metrics dead = ISP, say so) | "It's them, not you" in 60s | S | 4 | NEXT |

## D. Adaptive measurement (AI-035–044)

| ID | Title | Why it matters | Effort | Impact | Status |
|----|-------|----------------|--------|--------|--------|
| AI-035 | Dynamic stream count (measure congestion, then choose N) | No more guessing --streams | M | 4 | NEXT |
| AI-036 | Adaptive test duration (stop when confidence reached) | Short tests when clear, long when noisy | M | 4 | NEXT |
| AI-037 | Smart endpoint selection per network | Fastest mirror, automatically | S | 3 | NEXT |
| AI-038 | Congestion-aware scheduling (measure when informative) | Data where it matters | M | 4 | NEXT |
| AI-039 | Battery/cost-aware probing (light touch on battery) | Laptop users stay happy | S | 3 | NEXT |
| AI-040 | Interference-aware timing (defer when user is on a call) | Never skew your own meeting | M | 3 | NEXT |
| AI-041 | Progressive refinement (quick verdict now, precise later) | Instant + accurate | M | 4 | NEXT |
| AI-042 | Cross-mode inference (predict bloat from loss+jitter, skip the load test) | Answers without the pain | L | 4 | NEXT |
| AI-043 | Personalized baselines per SSID+hour | Comparisons that are actually fair | M | 4 | NEXT |
| AI-044 | Measurement-cost governor (bandwidth budget per day) | Measuring never costs more than it saves | S | 3 | NEXT |

## E. Natural-language assistant (AI-045–054)

| ID | Title | Why it matters | Effort | Impact | Status |
|----|-------|----------------|--------|--------|--------|
| AI-045 | "Explain this run" in one paragraph | Every number gets a story | S | 5 | NEXT |
| AI-046 | Chat over your history ("why is Friday slow?") | Your data, interrogable | L | 5 | NEXT |
| AI-047 | ISP complaint letter generator (with evidence table) | Anger, formatted | M | 4 | NEXT |
| AI-048 | Router-fix instructions matched to detected vendor | From grade to guide | M | 4 | NEXT |
| AI-049 | Jargon toggle (engineer ↔ human explanations) | One product, two vocabularies | S | 3 | NEXT |
| AI-050 | Voice-query answers in menu bar ("how's my net?") | Zero-click status | M | 3 | NEXT |
| AI-051 | Weekly narrative summary (3 sentences, auto-written) | The digest writes itself | M | 4 | NEXT |
| AI-052 | Suggested follow-up tests after each run | Curiosity, automated | S | 3 | NEXT |
| AI-053 | Multilingual explanations (analysis is language-free, render any) | Metrics translate trivially | M | 3 | NEXT |
| AI-054 | Kid-mode explanations ("the internet tubes are crowded") | Household peace | S | 2 | NEXT |

## F. BYOK provider ecosystem (AI-055–064)

| ID | Title | Why it matters | Effort | Impact | Status |
|----|-------|----------------|--------|--------|--------|
| AI-055 | Any-LLM presets (OpenAI, Anthropic, Gemini, DeepSeek, Groq, Mistral, OpenRouter) | No vendor lock-in, ever | S | 5 | NOW |
| AI-056 | Ollama / LM Studio / llama.cpp local presets (keyless loopback) | Private AI, zero cost | S | 5 | NOW |
| AI-057 | macOS Keychain key storage (`--save-key`, never plaintext) | BYOK without env-var gymnastics | S | 4 | NOW |
| AI-058 | `--verify-provider` handshake before first use | "Is my setup right?" in 2s | S | 4 | NOW |
| AI-059 | `--detect-local` (probe 11434/1234/8080, first alive wins) | Local AI with zero config | S | 4 | NOW |
| AI-060 | Per-analysis model routing (cheap model for labels, smart for diagnosis) | Cost without quality loss | M | 4 | NEXT |
| AI-061 | Provider failover chain (local → cheap cloud → flagship) | Answers survive outages | M | 3 | NEXT |
| AI-062 | Token/cost ledger per analysis | AI spend, itemized | S | 3 | NEXT |
| AI-063 | Offline-first guarantee badge (which analyses need no key) | Privacy you can audit | S | 4 | NEXT |
| AI-064 | Swift Settings provider picker + key field (Keychain-backed) | BYOK reaches the Mac app UI | M | 5 | NEXT |

## G. On-device & privacy-preserving AI (AI-065–074)

| ID | Title | Why it matters | Effort | Impact | Status |
|----|-------|----------------|--------|--------|--------|
| AI-065 | CoreML anomaly scorer (replaces cloud for routine verdicts) | Instant, offline, free | L | 5 | NEXT |
| AI-066 | Tiny time-series forecaster on-device (sub-10MB, ONNX/CoreML) | Forecasts without a server | L | 4 | NEXT |
| AI-067 | Apple Foundation Models path (on-device LLM when available) | Free inference on new OSes | M | 4 | NEXT |
| AI-068 | Privacy manifest per analysis (what bytes leave the Mac) | Trust as a feature | S | 4 | NEXT |
| AI-069 | Redaction pass (SSID/BSSID stripped before any cloud call) | Leak-proof by construction | S | 4 | NEXT |
| AI-070 | Local-first cascade (heuristics → on-device → local LLM → cloud) | Cloud is the last resort | M | 4 | NEXT |
| AI-071 | Differential-privacy option for crowd contributions | Share trends, never traces | L | 3 | NEXT |
| AI-072 | On-device embedding index over history (semantic recall) | "Find runs like this" offline | L | 3 | NEXT |
| AI-073 | Quantized-model downloader (pick size: 1M/8M/70M params) | User chooses brain size | M | 3 | NEXT |
| AI-074 | Airplane-mode full function (every core verdict offline) | AI that works in a tunnel | M | 4 | NEXT |

## H. Trust, eval & honesty (AI-075–084)

| ID | Title | Why it matters | Effort | Impact | Status |
|----|-------|----------------|--------|--------|--------|
| AI-075 | Golden-set eval harness (100 labeled runs, every analyser scored) | Regressions get caught | M | 5 | NEXT |
| AI-076 | Abstention protocol (say "not enough data" instead of guessing) | Silence beats confabulation | S | 5 | NEXT |
| AI-077 | Hallucination tripwires (metric cited must exist in input) | Claims pinned to evidence | S | 4 | NEXT |
| AI-078 | Prompt-injection guard on history annotations | User text is data, never instruction | S | 4 | NEXT |
| AI-079 | Model-upgrade detector (re-run goldens on version change) | New model, re-proven | S | 3 | NEXT |
| AI-080 | Explanation diffing (same run, two models, show disagreement) | Disagreement made visible | M | 3 | NEXT |
| AI-081 | Confidence shown as bet ("I'd wager 4:1 this is bufferbloat") | Uncertainty users feel | S | 3 | NEXT |
| AI-082 | "Why not X?" alternative-killer per verdict | Doubt, pre-answered | M | 4 | NEXT |
| AI-083 | Audit log of every AI claim (prompt hash + response + inputs) | Reproducible intelligence | M | 3 | NEXT |
| AI-084 | Kill-switch per analyser (disable any AI, keep heuristics) | User is the final gate | S | 3 | NEXT |

## I. Automation & remediation (AI-085–092)

| ID | Title | Why it matters | Effort | Impact | Status |
|----|-------|----------------|--------|--------|--------|
| AI-085 | One-click DNS switch to ranked-best (with revert) | Advice that acts | M | 4 | NEXT |
| AI-086 | Router-config snippet generator (fq_codel per detected firmware) | Copy-paste the fix | M | 4 | NEXT |
| AI-087 | Self-healing schedule (bad hours get measured more, good less) | Attention follows need | M | 4 | NEXT |
| AI-088 | Auto-baseline after network change (new SSID detected) | Fresh normal, no prompt | S | 4 | NEXT |
| AI-089 | Smart retry with backoff advice (when a run fails mid-way) | Failures that teach | S | 3 | NEXT |
| AI-090 | ISP-call script with your numbers filled in | Hold music, armed | S | 3 | NEXT |
| AI-091 | macOS network-setting checks (proxy/VPN/DNS misconfig scan) | Local faults first | M | 3 | NEXT |
| AI-092 | "Fix my call quality" one-button routine (diagnose→adjust→verify) | Outcome, not metrics | L | 5 | NEXT |

## J. Data flywheel & learning (AI-093–100)

| ID | Title | Why it matters | Effort | Impact | Status |
|----|-------|----------------|--------|--------|--------|
| AI-093 | Per-user calibration (your "slow" vs global "slow") | Thresholds that know you | M | 4 | NEXT |
| AI-094 | Opt-in crowd priors (new users inherit population normals) | Day-one accuracy | L | 4 | NEXT |
| AI-095 | Analyser accuracy leaderboard (which of the 22 earns trust) | Survival of the fittest analyser | M | 3 | NEXT |
| AI-096 | Auto-labeling from user actions (ignored alert = false positive) | Labels without labeling | M | 4 | NEXT |
| AI-097 | Drift-triggered re-calibration (your normal moved, follow it) | Models that age gracefully | M | 4 | NEXT |
| AI-098 | Synthetic-run generator for eval (edge cases on demand) | Test what reality rarely shows | M | 3 | NEXT |
| AI-099 | Feature-importance readout per verdict ("loss mattered 70%") | Glass-box AI | S | 3 | NEXT |
| AI-100 | Monthly model report ("your AI got 4% sharper") | Improvement you can see | S | 3 | NEXT |

## K. Pro/Team AI monetization (AI-101–105)

| ID | Title | Why it matters | Effort | Impact | Status |
|----|-------|----------------|--------|--------|--------|
| AI-101 | Fleet anomaly ranking (which of 50 machines hurts most) | Team triage in one view | L | 5 | NEXT |
| AI-102 | Cross-site comparison AI (office A vs office B, normalized) | Multi-site truth | L | 4 | NEXT |
| AI-103 | SLA-breach predictor with evidence packet | Sell prevention, not charts | L | 5 | NEXT |
| AI-104 | Natural-language fleet query ("show degrading sites") | Ask the whole network | L | 4 | NEXT |
| AI-105 | White-label diagnosis API (your AI, their dashboard) | Revenue from intelligence | XL | 4 | NEXT |

---
*105 items. F-group NOW items land in `netmax_ai_endpoint.py` + `netmax ai --verify-provider` this session; G-group on-device path is specified in `ml-algorithms-research.md`.*

*2026-10-04: Tier-0 stats shipped in `netmax_stats.py` (Welford/EWMA/CUSUM/MAD/STL-lite/Holt/changepoints + `summarize()`) — covers AI-013, AI-018, AI-025, AI-029 foundations. Analyser integration queued behind the provider rewire landing.*

*2026-10-04 merge verdict: `netmax_ai_endpoint.py` deleted after analysis — the provider transport (`netmax_ai_provider.py`) won on integration (11 analyser gates, committed). Its 4 unique capabilities (correct local ports — lmstudio/llamacpp shared Ollama's 11434, now fixed; gemini/deepseek/groq/mistral/openrouter presets; Keychain; `--detect-local`) were folded in. One CLI: `netmax model` = setup/verify/save/detect, `netmax ai --provider/--model/--llm-base` = per-run overrides.*
