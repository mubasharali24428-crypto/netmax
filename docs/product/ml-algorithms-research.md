# ML/DL Algorithms for NetMax — Research Verdict (2026-10-04)

**One-line verdict:** ship classical statistics in pure stdlib now (EWMA/CUSUM/STL-lite);
add a streaming layer later; put deep learning on-device (CoreML/ONNX tiny models),
never as a server dependency. The literature converges: on small noisy telemetry,
simple methods match or beat deep ones — depth wins only with scale + labels we lack.

## What the literature says (2024–2026)

- **Reconstruction beats proximity on temporal data.** A 2026 SCADA benchmark
  (AE vs LSTM-AE vs OCSVM vs Isolation Forest): plain autoencoder AUC 0.9667;
  Isolation Forest kept ranking power (AUC 0.86) but its decision boundary
  collapsed under class imbalance (Macro-F1 0.43). Lesson: score = reconstruction
  error with a percentile threshold, not a proximity boundary.
  (MDPI Computers 2026, doi:10.3390/computers18020096)
- **Hybrids win on network/IoT data.** IF + LSTM-Autoencoder weighted fusion:
  F1 0.937, AUC 0.974 on UNSW-NB15/N-BaIoT, +6–12pp over either alone; cascade
  variant F1 0.93. Lesson: pair a cheap partitioner (IF) with a temporal
  validator (LSTM-AE) and fuse scores. (JAAFR 2026; JTOS 2026)
- **Classical wins on small noisy series.** SARIMA (F1 0.256) edged both
  Isolation Forest (0.233) and LSTM-AE (0.110) on industrial smart-meter data;
  all suffered false positives (precision ≤ 0.20). Lesson: with dozens of runs,
  not millions, statistics generalize and deep nets overfit noise.
  (MDPI IJFS 2026)
- **Foundation models shrank to the edge.** NanoForecast (200K–6.5M params,
  ONNX, Raspberry Pi, Apache-2.0) and TinyCast (146K params, INT8, 0.6 MB)
  do zero-shot probabilistic forecasting on CPU. A sub-10MB forecaster inside
  the Mac app is now realistic — no server, no key, no privacy review.
- **Online/streaming is a solved library problem.** Incremental learners
  (Welford O(1) stats, Half-Space Trees, ADWIN drift, CUSUM/EWMA detectors)
  update one observation at a time — exactly the watch-daemon shape.
  (incre-ml; River lineage; Meta Kats CUSUM reference implementation)
- **Changepoints deserve their own algorithm.** PELT (O(T) exact) and binary
  segmentation beat sliding windows for "when did my line change" — the core
  ISP-degradation question. (Chronos/PELT; ruptures lineage)

## Recommendation tiers for NetMax

### Tier 0 — ship now, pure stdlib, zero deps (matches engine constraint)

| Algorithm | Job in NetMax | Why first |
|-----------|---------------|-----------|
| EWMA + control bands | Per-metric drift score | O(1), online, explainable |
| CUSUM (two-sided) | Level-shift detection (plan change, throttling onset) | The ISP question, directly answered |
| STL-lite residual z-score | Seasonal anomaly (evening congestion vs real fault) | Separates pattern from problem |
| Welford mean/variance | Running stats for every history lane | Every Tier-1 method needs these |
| Holt-Winters / SES | 24h speed forecast with bands | Forecasts from day one of data |
| PELT-lite (BIC penalty) | "Your line changed on Oct 2" | Exact changepoints, no window tuning |
| Modified z-score (MAD) | Robust point-anomaly flag | Immune to the outlier it detects |

### Tier 1 — optional extra, still local (`pip install netmax[ml]`)

| Algorithm | Job | Cost |
|-----------|-----|------|
| Isolation Forest (sklearn) | Cross-metric outlier ranking | Heavy dep; gate behind extra |
| River Half-Space Trees + ADWIN | Streaming anomaly + drift in watch daemon | Pure-python friendly, small |
| Mini-autoencoder (numpy) | Reconstruction-error score per run | ~100 lines, no framework |

### Tier 2 — on-device deep learning (Swift/CoreML side, never engine dep)

| Model | Job | Size |
|-------|-----|------|
| LSTM-AE → CoreML | Routine verdict scorer, offline | Few MB quantized |
| NanoForecast-class tiny transformer (ONNX) | Quantile forecasts on-device | 1.4–26 MB |
| Apple Foundation Models | Natural-language explanations on new OSes | 0 bytes shipped |

### Tier 3 — server-side only (Team tier, never in the Mac app)

Zero-shot foundation forecasters (Chronos-2/TimesFM wrappers), fleet-wide
clustering, population priors for cold start. Revenue funds the GPUs.

## What NOT to do

1. No sklearn/scipy/torch in the engine — the pure-stdlib guarantee is a
   distribution feature (no pip install, HOMEbrew-clean). ML lives in Tier-0
   stdlib code, optional extras, or the Swift side.
2. No cloud-only intelligence for core verdicts — airplane-mode must still
   grade your network (AI-074).
3. No point forecasts without bands — a number without uncertainty is the
   dishonesty this product exists to kill (AI-018).
4. No proximity-only detectors as sole gate — threshold collapse under
   imbalance is empirically documented; fuse or reconstruct.

## Sources

- Darban et al., "Deep Learning for Time Series Anomaly Detection: A Survey",
  ACM Computing Surveys 57(1), 2024.
- Huang et al., "Deep Learning Advancements in Anomaly Detection",
  IEEE IoT-J 12(21), 2025.
- Hybrid IF+LSTM-AE (UNSW-NB15, F1 0.937): JAAFR 2026; cascade variant: JTOS 2026.
- SARIMA-vs-IF-vs-LSTM-AE smart-meter benchmark: MDPI IJFS 2026.
- Meta Kats CUSUM detector (reference implementation).
- NanoForecast (Apache-2.0, ONNX edge); TinyCast (146K params, INT8).
- incre-ml (incremental: Welford, HST, CUSUM/EWMA, ADWIN, conformal).
