# Mission W7 — POLISH CLUSTER (P2/P3/P5) + F2 hardening

Base: netmax-app @ `903b4fa`. Provider instability is ongoing: ALL lanes are
WRITE-FIRST (skeleton before probing), compressed scopes, ATLAS gates + merges.

## Lanes

| Lane | Task | Owns |
|---|---|---|
| W7-1 (P3, S) | Notification digests: NotificationPreferences gains `netmax.notify.digest` bool; NotificationCoordinator batches alerts when digest ON — stores pending alerts in defaults array `netmax.notify.pending`, flushed once/day (last flush ts key `netmax.notify.lastDigest`) into ONE summary notification ("2 degradations in the last 24h: bloat B→D, loss 0.2→1.4%"); ScheduleRunner tick calls flushIfDue() | Notifications.swift or new NotifyDigest.swift |
| W7-2 (P5a, M-part1) | Report card v2 data: ReportCardModel gains personal-baseline comparison — median mbps/loss/bloat-delta over prior 14 days per mode; grade trend arrows (▲ better ▼ worse — vs baseline, honest "no baseline yet" when <5 prior runs); expose in model + DEBUG self-checks | ReportCardModel.swift |
| W7-3 (P5b, M-part2) | Report card v2 UI: ReportCardShareView renders trend arrows beside each metric row w/ a11y labels ("trend: better than your 14-day baseline"); footer notes baseline window honestly | ReportCardShareView.swift |
| W7-4 (F2, S) | Bridge-layer range validation: engine_bridge.py validates --seconds 5..30 / --streams 1..32 / --count 1..100 BEFORE spawning engine; violations → envelope failure w/ clear text, exit 1 (mirror netmax.py bounds; single source table RANGE_BOUNDS at top of file); selftest + pytest cases for boundary values | desktop/bridge/engine_bridge.py + test_engine_bridge.py |
| W7-5 (P2, M) | Onboarding polish: OnboardingScheduleStep copy tightened; add feature-discovery hints — first History visit after ≥3 runs shows one-time .help()-style hint bar pointing at Quality Timeline button (defaults flag netmax.hints.timelineShown) | HistoryView.swift |

## Rules
- WRITE-FIRST: skeleton file immediately, probe second.
- Suite must stay green or grow; no refactors of working code.
- ATLAS merges lane-by-lane as completions land; final gate = build + suite + bundle + live probe.
