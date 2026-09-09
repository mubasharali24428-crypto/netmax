# NetMax Verifier — Engagement Report (W18)

**Date:** 2026-09-08 · **Agent:** NetMax Verifier (merged prompt)
**Target:** NetMaxDesktop, /Users/user/netmax-app
**Commits this engagement:** 561a7de (W17 — protects audit fixes), 538172c (W18 — upgrades)

---

## 1. Executive summary

The app works: 192/192 engine+bridge tests, bridge selftest 3/3, all engine
modes live-verified through the real bridge (dns run success, watch grade A),
and the rebuilt app runs stably in the menu bar. Security posture is strong for
a pre-notarization local app — every audit fix F2–F19 is confirmed intact, and
this pass added the two remaining hardening items: a startup engine-integrity
check (F2 follow-up) and the F20 storage decision (SQLite adopted opt-in).
Ship-ready **except** F1 notarization, which remains blocked solely on an Apple
Developer account — the pipeline is written, dry-run-verified, and waiting.

## 2. Vulnerability & defect list (fresh evidence this round)

| ID | Sev | Description | Evidence | Status |
|---|---|---|---|---|
| NF1 | High (ops) | 678 lines of audit fixes uncommitted — one bad checkout from loss | git status pre-W17: 24 modified files | **fixed** — committed 561a7de |
| NF2 | Med (claimed) | Running /Applications copy suspected stale | compared binaries: wifievents refs 2=2, effective_timeout 2=2, engine files 21=21 — identical | **not a bug** — closed |
| NF3 | Low (honesty) | Settings said "engine: 157 offline tests" (actual: 192) | SettingsView.swift:495 | **fixed** — W18 |
| NF4 | Low (CI) | CI label claimed "177 tests"; no seal/perm gates | .github/workflows/ci.yml | **fixed** — rewritten W18 |
| F20 | Med (decision) | Unused SQLite layer — adopt or remove | 38/38 store tests pass; migration dry-run imported 51 runs | **decided+implemented** — opt-in migration |
| F2' | Med (residual) | No runtime defense if engine dir becomes writable post-install | new EngineIntegrityCheck + CI gate | **implemented** — startup warn |

**Chain analysis (Stage 3):** the one realistic chain — *ad-hoc signature (F1) +
user-writable engine (F2) + scheduled LaunchAgent runs (F14)* — is now broken at
**two** links: the integrity check warns on tampered perms at startup, and CI's
engine-perm gate prevents shipping a bad bundle. The chain fully dies when F1
(notarization) lands, since tamper then breaks the seal itself.

## 3. Rectification log (every change, suite counts before/after)

| Change | Before → After |
|---|---|
| Commit W17 (protect fixes) | dirty tree (24 files) → clean |
| EngineIntegrityCheck.swift + App wiring | new code; 192/192 maintained |
| EngineIntegrityCheckTests (5 checks) | all 5 PASS |
| migrate_to_sqlite.py (F20) | dry-run: 51 runs, 0 corrupt, 0600 |
| ci.yml rewrite | YAML valid; adds 3 gates + store suite |
| docs/THREAT-MODEL.md | new (audit P2-16) |
| RELEASE-NOTES v0.7.0-draft, Settings 157→192 | honesty fixes |
| Swift release rebuild | clean, **0 warnings** |
| Bundle + DMG rebuild | deep seal VALID; DMG 1.6M signed |

Final battery: **pytest 192/192 · store 38/38 · bridge 3/3 · deep-seal VALID ·
app LIVE · DMG rebuilt** — all after the last change (fix-verify discipline).

## 4. Improvement roadmap (Stage 5, ranked by value/effort)

1. **Notarize (F1)** — buy the Apple Developer account, run
   `desktop/scripts/notarize.sh`, re-staple. Everything else is done; this is
   the single remaining ship-blocker. *(high value, trivial effort once account exists)*
2. **Promote the SQLite layer into the Reports tab** — history.db is now
   migratable; surface trend queries (grade-over-time, mode comparisons) on
   top of it. *(high value, medium effort)*
3. **Real XCTest target** — Package.swift has none; the two harness files
   (HistoryStoreTests, EngineIntegrityCheckTests) convert 1:1 into XCTest
   methods. *(moderate value, low effort)*
4. **SMAppService for the LaunchAgent** (F14 follow-up) — modern API, drops
   raw plist management. *(moderate, low)*
5. **Sparkle-style updates post-notarization** — Settings already has the
   releases-page URL stub. *(high value post-notarization, medium effort)*

## 5. Verdict

```
PASS_WITH_FIXES
```

Issues found this engagement (uncommitted work, stale-count honesty, missing
CI gates, open F20/F2 residuals) were all **fixed in-session**; full suite
green after every change; live app verified through the real bridge and
rebuilt artifacts. F1 notarization remains blocked on an external credential
(Apple Developer account) — runbook already in the audit and README.

## 6. Memory handoff

- `verify/MEMORY.md` — full round log, open items for next engagement
- `verify/exhausted.md` — checks done this engagement (don't redo)
- `verify/evidence/round1.md` — raw evidence for every claim above
- Next engagement starts warm: read MEMORY.md first.
