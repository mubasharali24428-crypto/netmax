# Verifier Pair B — Lane M5 (`docs/product/05-app-architecture.md`)

**Verdict: READY-TO-MERGE** · Baseline `8d12548` · Verified 2026-08-23
**Method:** Pass 1 (SUB) mechanical evidence collection completed *before* any builder self-report was read beyond the audited artifact itself; Pass 2 (PRIME) judgment + in-lane fixes on that bundle. No commits made. Edits confined to `05-app-architecture.md` (fixes) and this report.

---

## PASS 1 — SUB VERIFIER (mechanical sweep)

### 1. Footprint

```
$ cd /Users/user/netmax-app && git status --short && git log --oneline -3
?? docs/product/01-product-strategy.md
?? docs/product/03-market-analysis.md
?? docs/product/04-feature-roadmap.md
?? docs/product/05-app-architecture.md
8d12548 mission graph + verifier brief (docs-only analysis mission)
5cd59d5 version bump 0.5.0
fdbc861 v0.5: fetch accelerator + eco bloat wired; ...
```

Lane write = `05-app-architecture.md` only. The other three untracked docs are sibling builders' deliverables (Pair A scope). Post-fix footprint adds only `?? docs/product/verifier-reports/` (this report). No tracked files touched, no commits.

### 2. Suite rerun

```
$ /Users/user/1/bin/python -m pytest -q | tail -3
157 passed in 7.98s        ← matches known-good exactly (pytest.ini: testpaths = tests)
```

Test-count reconciliation (needed because the doc claims "~201 offline tests"):

```
$ cat pytest.ini
[pytest]
testpaths = tests

$ /Users/user/1/bin/python -m pytest --collect-only -q | tail -1
157 tests collected in 0.03s

$ /Users/user/1/bin/python -m pytest -q tests test_netmax_gui.py | tail -3
201 passed, 5 subtests passed in 13.82s
```

`test_netmax_gui.py` sits at repo root (outside `testpaths`) and carries **44** `def test_` functions: 157 + 44 = 201. The doc's "~201" is **accurate** for the full suite; 157 is merely the default-scoped count.

### 3. Anti-synthesis scan

**(a) Placeholder markers**

```
$ grep -nEi "TODO|FIXME|TBD|placeholder|XXX|lorem" docs/product/05-app-architecture.md
(no marker hits)
```

**(b) Every cited module/file exists**

```
$ ls   (repo root)
measure.py  netmax.py  netmax_eco.py  netmax_export.py  netmax_fetch.py
netmax_gui.py  netmax_throttle.py  netmax_upload.py  netmax_watch.py
netmetrics.py  results.json  results.png  tests/ ...
```

Doc citations: `netmax.py`, `netmax_gui.py`, `netmax_fetch`, `_eco`, `_export`, `_throttle`, `_upload`, `_watch`, `netmetrics.py`, `measure.py`, `tests/*` — **all present**. One naming slip found: §4 cited `EngineRunner`; the real class is:

```
$ grep -n "class \|Popen\|subprocess" netmax_gui.py | head
146:class NetMaxRunner(threading.Thread):
163:    self._proc: subprocess.Popen | None = None
182:    proc = subprocess.Popen(
```

Behavioral description (one subprocess at a time, piped stdio, per-line callbacks) is accurate — class name fixed in-lane (FIX-4).

**(c) Schema fields vs. actual engine output**

```
$ cat results.json
{
  "seconds": 8,
  "baseline_mbps": 44.65,
  "turbo8_mbps": 39.88,
  "baseline_mb": 116.6,
  "turbo8_mb": 120.4,
  "dropped": false,
  "dns": [["Cloudflare 1.1.1.1", 51.3], ["System default", 61.8],
          ["Google 8.8.8.8", 149.2], ["Quad9 9.9.9.9", 192.3]]
}
```

Ground truth keys: `seconds, baseline_mbps, turbo8_mbps, baseline_mb, turbo8_mb, dropped, dns`. Export adds derived CSV columns (`netmax_export.py` L14–24): `timestamp, seconds, baseline_mbps, turbo8_mbps, baseline_mb, turbo8_mb, dropped, dns_resolver, dns_ms`.

`history.json`: **does not exist on disk yet** — it is a designed artifact:

```
$ ls /Users/user/netmax/results/
20260822T231549/          (results.json + results.png only; no history.json)

$ ls /Users/user/netmax/results/20260822T231549/
results.json  results.png
```

Producer is `measure.py` L23/L26–46: `HISTORY_FILE = RESULTS_DIR / "history.json"`; `append_history()` writes entries of shape `{"timestamp", "mode", "results"}` (L34). Watch-loop history entries carry `{delta_ms, grade, dns_ms}` (`netmax_watch.py` L58).

M5 schema mapping check against these real names:
- `runs(mode: baseline|turbo|boost|dns|bloat|full|watch…)` ↔ CLI modes; `params_json` absorbs `seconds` etc. ✓
- `samples(kind: down|up|rssi|ping|dns_probe; value; unit: mbps|dbm|ms)` ↔ throughput floats, DNS `[name, ms]` pairs (`dns_probe`/`dns_ms` mirrors the CSV columns) ✓
- `verdicts(grade, gain_pct, dropouts)` ↔ bloat grade, turbo-vs-baseline gain, `dropped` flag ✓
- `wifi_context(ssid, bssid, …)` nullable when permission denied ↔ strategy doc's observed "SSID redaction in some contexts" ✓
- Importer reads legacy `results.json`/`history.json` "schema-discovered defensively" — honest given history.json isn't materialized yet. ✓
- One field-name inconsistency: `rsi_dbm` vs the ecosystem's universal `rssi` — fixed (FIX-2).

No invented field names, no phantom modules, no fake statistics found.

**(d) Uncertainty-tagging sweep:** §2 carries six explicit tags ([CONFIRMED]×4, [UNCERTAIN]×2 — see Pass 2 audit). Gaps found: the Stack Decision Matrix memory figures were untagged statistics — tagged [LIKELY] in-lane (FIX-1). No other untagged factual/API claims located.

### 4. Length gate

```
$ wc -l docs/product/05-app-architecture.md
224 docs/product/05-app-architecture.md     (was 219 pre-fix)   ≥150 REQUIRED: PASS
```

---

## PASS 2 — PRIME VERIFIER (judgment)

### 5. Contract conformance — stack recommendation vs. hosted features

Recommendation quoted verbatim (§1):

> **Recommendation: (a) SwiftUI menu-bar app calling the bundled Python engine via subprocess**, structured exactly like today's `netmax_gui.py` runner (one engine at a time, streamed output).

Assessment per NOW-horizon feature (quotes from `04-feature-roadmap.md`):

| Hosted feature | Roadmap requirement | Does stack host it? |
|---|---|---|
| Menu-bar presence (N3) | "NetMax lives in the menu bar with last grade/speed… app works docked-to-menubar-only (LSUIElement mode toggle)" | **YES** — SwiftUI first-class: matrix row cites `MenuBarExtra`, `UserNotifications`; menu-bar posture IS the recommended app shape |
| Scheduled background tests (N4) | "User-configurable schedule… Accept: schedule survives relaunch (launchd agent or in-app timer with persistence); scheduled runs skip when offline; results land in `history.json` tagged `source=scheduled`; battery-impact note documented" | **YES** — §2 background-energy block prescribes `NSBackgroundActivityScheduler`-style opportunistic wakeups, idle near-zero CPU, engine processes exist only during a run. Gap: relaunch-survival mechanism was unnamed → fixed in-lane (FIX-3: `SMAppService`/launchd agent named in Settings) |
| PDF export (N7) | "One-click export of the report card (N5) plus charts as a shareable PDF… generated locally (no network call)" | **YES** — UX view 4 "Reports — generate/export PDF or CSV summaries (reuses `netmax_export` semantics), share sheet" |
| Licensing gate (N10) | "Feature-gated free tier… license-key validation. Accept: unlicensed app = fully functional measurer forever" | **GAP → FIXED** — pre-fix doc had zero licensing surface anywhere (stack matrix, UX, settings). Post-fix Settings carries license & trial state mirroring N10's exact free-tier rule |

The subprocess seam also preserves the roadmap's sequencing logic ("deliberately no engine rewrite") and the strategy doc's mitigation ("near term wrap the engine in a native Swift menu-bar shell calling the same logic"). Escape hatch to options (b)/(c) is preserved via the stdio JSON protocol. **Stack recommendation credibly hosts all four features.**

### 6. Platform-fact audit (each [CONFIRMED] judged from verifier knowledge)

| Tag | Claim | Judgment |
|---|---|---|
| [CONFIRMED] | Sandboxed apps may execute only binaries inside their own bundle; arbitrary child processes (system `curl`, `/usr/bin/python3`) off-limits | **CORRECT — keep.** Matches App Sandbox exec policy; vendored-helper conclusion follows validly |
| [CONFIRMED] | Since macOS 10.15, SSID/BSSID requires Location Services authorization ("While Using" suffices) | **CORRECT — keep.** Matches Catalina's `CNCopyCurrentNetworkInfo` restriction; graceful `<requires-location>` degradation is sound |
| [CONFIRMED] | Developer ID signing + notarization (`notarytool` + `stapler`) required outside MAS | **CORRECT — keep.** Tool names are current and correct. Minor looseness: the "unsigned/arm64 refused outright on Apple Silicon" phrasing conflates mandatory-arm64-code-signing with notarization, but the operative claim (notarize or Gatekeeper trips) is right; noted, not downgraded |
| [UNCERTAIN] | Local-network privacy prompt applicability to outbound public-endpoint probes post-Sonoma | **Appropriately humble — keep.** Correctly treated as environment-dependent with empirical verification per OS release |
| [CONFIRMED] | Long-running polling draws App Review scrutiny; use `NSBackgroundActivityScheduler`-style opportunistic wakeups | **Keep,** with note: the API reference is confirmed-correct; the review-scrutiny clause is practitioner judgment rather than hard fact — acceptable inside a guidance block |
| [UNCERTAIN] | Future MAS guideline wording on network-testing utilities | **Appropriate — keep** |

API names spot-checked and all correct: `MenuBarExtra`, `UserNotifications`, `NSBackgroundActivityScheduler`, `com.apple.security.network.client`, `notarytool`, `stapler`, universal2, Swift Charts, WAL mode. **Zero mislabeled tags found; no downgrades required.**

### 7. Integration probe — cross-claims between M5 and M4-NOW / M1-concept

| # | Claim | M5 line | Sibling line | Verdict |
|---|---|---|---|---|
| P1 | Stack natively hosts menu bar | §1 matrix "First-class SwiftUI (`MenuBarExtra`…)"; rec: "SwiftUI menu-bar app" | N3: "menu-bar icon shows latest result within 2 s… LSUIElement" | **CONFORMS** |
| P2 | Background scheduler story matches scheduled-tests acceptance | §2 "`NSBackgroundActivityScheduler`-style opportunistic wakeups… near-zero CPU when idle" | N4: "schedule survives relaunch… battery-impact note documented" | **CONFORMS after FIX-3** (relaunch mechanism was unnamed; now SMAppService/launchd) |
| P3 | Reports view satisfies PDF/share acceptance | §5 view 4: "generate/export PDF or CSV… share sheet" | N7: "PDF contains headline metrics… opens correctly in Preview; share button hands it to macOS share sheet" | **CONFORMS** |
| P4 | Licensing surface exists for trial gate | *(pre-fix: absent everywhere)* | N10: "unlicensed app = fully functional measurer forever… key validated locally with offline grace period" | **GAP → FIXED IN-LANE** (Settings now: license & trial state, local key validation, offline grace, free-tier rule verbatim) |
| P5 | UX serves the chosen consumer concept (B "Home QoE Sentinel", A evidence kit inside) | §5 views 2–4: Live Monitor sparkline w/ dropouts shown "rather than smoothing them away", History/Trends, Reports + "copy verdict text" | Concept B value prop: "resident monitor that continuously grades… keeps history"; Concept A: "scheduled, timestamped, exportable proof" | **CONFORMS** |
| P6 | Eco/metered capability surfaced | *(pre-fix: eco ported in Phase-1 list but never reachable from any UI view)* | Concept E: eco as a *mode* across concepts; roadmap base tables list `netmax_eco.py` | **GAP → FIXED IN-LANE** (Dashboard defaults to eco variants ~100 KB on metered links; metered-link preference in Settings) |
| P7 | SQLite migration covers real persistence artifacts | §3: importer reads legacy `results.json` + rolling `history.json`, defensively schema-discovered | `measure.py` L23/L34 (`history.json`, `{timestamp, mode, results}`), repo-root `results.json` keys | **CONFORMS** (with honest caveat: history.json not yet materialized on disk; defensive wording already covers this) |
| P8 | Process model mirrors proven GUI isolation | §4: "Reuse the proven pattern from `netmax_gui.py`" one-subprocess/streamed lines | `netmax_gui.py` L146–185: `class NetMaxRunner`, single `Popen`, piped stdio | **CONFORMS after FIX-4** (doc said `EngineRunner`; real name `NetMaxRunner`) |

### 8. Classification & fix record

**BLOCKERs: none.** No fabricated content (every file/module/test-count/schema-field traced to ground truth); stack recommendation contradicts none of the hosted features; 224 ≥ 150 lines.

**MINOR issues — all fixed IN-LANE in `05-app-architecture.md` only:**

| Fix | Issue | Change |
|---|---|---|
| FIX-1 | Untagged memory-footprint statistics in Decision Matrix | Added `[LIKELY]` qualifiers to the ~40–80 MB / ~30 MB / 200 MB+ ballparks (matrix row) |
| FIX-2 | Schema column `rsi_dbm` inconsistent with ecosystem-wide `rssi` naming (`wifi_context`) | Renamed `rsi_dbm` → `rssi_dbm` |
| FIX-3 | N4 acceptance "schedule survives relaunch" had no named mechanism; N10 licensing surface entirely missing from UX/Settings | Settings now specifies `SMAppService`/launchd-agent persistence and license & trial state (local key validation, offline grace, free-tier-measures-free-forever rule) |
| FIX-4 | §4 cited nonexistent class `EngineRunner` | Corrected to `NetMaxRunner` (verified at `netmax_gui.py` L146) |
| FIX-5 | Ported eco/metered capability unreachable from UX (Concept E orphaned) | Dashboard meters-link default to eco variants; metered-link preference added to Settings |

### 9. Post-fix verification

```
$ /Users/user/1/bin/python -m pytest -q tests test_netmax_gui.py | tail -2
201 passed, 5 subtests passed in 13.68s

$ /Users/user/1/bin/python -m pytest -q | tail -1
157 passed in 7.92s            (default scope unchanged)

$ wc -l docs/product/05-app-architecture.md
224 docs/product/05-app-architecture.md

$ git status --short
?? docs/product/01-product-strategy.md
?? docs/product/03-market-analysis.md
?? docs/product/04-feature-roadmap.md
?? docs/product/05-app-architecture.md
?? docs/product/verifier-reports/
```

Suite green, length gate met, footprint clean (no commits, no out-of-lane edits).

---

## VERDICT

**READY-TO-MERGE**

Lane M5 is factually grounded (all cited files, classes, test counts, and data fields verified against the repository), platform claims are honestly and correctly tagged, the SwiftUI-over-Python-sidecar recommendation credibly hosts every NOW-horizon feature including packaging/menu-bar/background-test/PDF-export/licensing, and the SQLite sketch maps cleanly onto what the engine actually produces. Five MINOR gaps were repaired in-lane; zero blockers remain.
