# P0 Pair C — Verifier Report: Lane B4 (bundle scripts) + artifact

**Pair:** C of THE VERIFIERS · **Mission:** NetMax desktop Phase 0 · **Date:** 2026-08-23
**Owned vertical:** `desktop/scripts/build_app.sh`, `desktop/scripts/verify_phase0.sh`, `desktop/README.md` + artifact `desktop/build/NetMaxDesktop.app`
**Method:** PASS 1 mechanical sweep (all commands re-run by verifier, raw output pasted) → PASS 2 prime judgment.
**Hard rules honored:** no commits made; no installs performed; edits confined to owned files + this report.

---

## PASS 1 — Mechanical sweep

### 1. Git footprint

```
$ cd /Users/user/netmax-app && git status --short
?? desktop/
```

Entire deliverable is one untracked path (`desktop/`) — exactly the lane footprint. Nothing tracked was modified. Artifact dir `desktop/build/` sits inside it (README documents `build/` as OUTPUT ONLY / gitignored-on-merge).

### 2. Syntax checks

```
$ bash -n desktop/scripts/build_app.sh && echo OK
build_app.sh: SYNTAX OK
$ bash -n desktop/scripts/verify_phase0.sh && echo OK
verify_phase0.sh: SYNTAX OK
$ shellcheck …
SHELLCHECK NOT INSTALLED — skipped (no installs allowed)
```

shellcheck unavailable on this machine; skipped per no-install rule. Both scripts pass `bash -n`.

### 3. Reproducible rebuild (verifier-rerun from clean-ish state)

```
$ rm -rf desktop/build && ./desktop/scripts/build_app.sh 2>&1 | tail -6
Internal requirements count=0 size=12
[build_app] bundle: /Users/user/netmax-app/desktop/build/NetMaxDesktop.app
[build_app]     total size: 324K
[build_app]     binary:      212K  MacOS/NetMaxDesktop
[build_app]     resources:   10 file(s)
[build_app] DONE
BUILD_EXIT=0
```

Rebuilt after deleting the previous bundle: reproducible, exit 0.

### 4. Structural audit of artifact

```
$ find . -print | sort        # inside desktop/build/NetMaxDesktop.app
./Contents/Info.plist
./Contents/MacOS/NetMaxDesktop
./Contents/Resources/engine/engine_bridge.py
./Contents/Resources/engine/netmax.py
./Contents/Resources/engine/netmax_eco.py
./Contents/Resources/engine/netmax_export.py
./Contents/Resources/engine/netmax_fetch.py
./Contents/Resources/engine/netmax_gui.py
./Contents/Resources/engine/netmax_throttle.py
./Contents/Resources/engine/netmax_upload.py
./Contents/Resources/engine/netmax_watch.py
./Contents/Resources/engine/netmetrics.py
./Contents/_CodeSignature/CodeResources

$ plutil -lint Contents/Info.plist
Contents/Info.plist: OK          (rc=0)

$ /usr/libexec/PlistBuddy -c 'Print :LSUIElement' \
    -c 'Print :CFBundleIdentifier' -c 'Print :LSMinimumSystemVersion' Contents/Info.plist
true
com.netmax.desktop
13.0                              (rc=0)

$ codesign -v --deep .
CODESIGN_V_RC=0                   (silent = valid)

$ ls Contents/Resources/engine/ | sort   → 10 files (above)
```

Contract match: binary in MacOS/, engine resources complete (engine_bridge.py + 9 netmax*.py + netmetrics.py), plist keys exact, ad-hoc signature validates on disk including nested code.

### 5. Binary sanity

```
$ file Contents/MacOS/NetMaxDesktop
Contents/MacOS/NetMaxDesktop: Mach-O 64-bit executable arm64
```

Expected Mach-O arm64 executable — confirmed.

### 6. Merge-gate rerun (verifier-executed, end-to-end)

```
$ bash desktop/scripts/verify_phase0.sh ; echo VERIFY_EXIT=$?
=== [deps] dependency files from B1–B3
[PASS] deps all present after 0s wait
=== [a] swift build -c release
Build complete! (0.11s)
[PASS] a swift build -c release green
=== [b] full pytest suite (expect 157 passed)
    157 passed in 7.95s
[PASS] b pytest summary contains '157 passed'
=== [c] desktop/bridge/test_engine_bridge.py
    36 passed in 0.05s
[PASS] c 36 passed
=== [d] engine_bridge.py selftest
    selftest: 3/3 checks passed
[PASS] d selftest exit 0
=== [e] .app bundle present
[PASS] e /Users/user/netmax-app/desktop/build/NetMaxDesktop.app/Contents/MacOS exists
=== [f] codesign -v
[PASS] f valid on disk
=== [g] plutil lint + LSUIElement
    …/Info.plist: OK
    LSUIElement=true
[PASS] g plist OK, LSUIElement=true
===== PHASE 0 GATE: PASS (8/8 steps green) =====
VERIFY_EXIT=0
```

All 8 steps are offline and were re-run by this verifier; none require network or credentials.

### 7. Anti-synthesis scan

```
$ grep -nE 'TODO|FIXME|echo PASS$' scripts/build_app.sh scripts/verify_phase0.sh
(no matches)
```

Script-level audit (full read of both scripts):
- Every `[PASS]` emission flows through `report()` and is reached only after a command whose output/rc was captured in the same step (deps→`wait_for`; a→`swift build` rc; b/c→pytest rc + literal `157 passed` grep against captured output; d→selftest rc; e→directory test; f→`codesign -v` capture; g→`plutil -lint` output + PlistBuddy value). No PASS string is emitted unconditionally anywhere.
- Gate summary `PASS (8/8)` prints only when `$FAIL -eq 0`; otherwise FAIL list + exit 1.

README overstatement scan:

```
$ grep -niE 'app store|notariz|ready for|distribution' README.md
70:- The app is **not notarized**. Gatekeeper will block it for other users … We are **not faking or working around** any of this.
73:### Next-step checklist for real signing/notarization
77:- [ ] Enroll in Apple Developer Program; accept the latest agreement in App Store Connect.
81:      (the --options runtime hardening + trusted timestamp are required for notarization).
82:… xcrun notarytool submit NetMaxDesktop.zip …
```

App Store/App Store Connect mentions occur only inside the future-work checklist gated on a **paid Apple Developer Program account ($99/yr)**. No claim of current notarization or distribution readiness anywhere. Honest.

---

## PASS 2 — Prime judgment

**Script correctness**
- `set -euo pipefail` present in both scripts ✅. Failure propagation is honest: `build_app.sh` `die`s on missing upstream lanes (B1/B2 guards), lets `swift build`/`cp`/`codesign` failures propagate via `set -e`, and self-lints the generated plist. `verify_phase0.sh` deliberately wraps nonfatal steps in `set +e` blocks, records real rcs, accumulates FAIL, and exits nonzero on any failure — verified live (exit 0 on all-pass path).
- Bundle assembly is idempotent (`rm -rf "$APP"` then rebuild) — confirmed by clean rebuild in §3.
- `nullglob` handled correctly around the netmax*.py glob with an explicit die if empty; `netmetrics.py` presence checked separately. Matches contract exactly.

**README honesty re ad-hoc signing** — exemplary. States plainly: `-s -` signs without identity; signature proves integrity, not authorship; **not notarized**, Gatekeeper will block other users; practical story is build-yourself / right-click Open / clear quarantine; explicit "we are not faking or working around any of this"; correct paid-account checklist (Developer ID cert + `--options runtime --timestamp`, notarytool, stapler, spctl). Nothing overstated.

**Artifact vs contract** — all five contract points verified with pasted evidence above (§4–5): bundle exists w/ arm64 binary, engine resources complete, plist keys exact (`com.netmax.desktop`, `LSUIElement=true`, min 13.0), ad-hoc `codesign -v --deep` valid, gate fully offline-rerunnable.

**Findings (non-blocking observations, no fix required)**
- MINOR (observation): `verify_phase0.sh` line 125 assigns `LINT_RC` which is never read (the verdict correctly keys off `LINT_OUT` containing `OK`). Dead variable only; behavior correct.
- MINOR (observation): step b pins the literal `157 passed` — intentional Phase 0 pin per mission contract, but will need updating as tests grow.
- MINOR (observation): default interpreter path `/Users/user/1/bin/python` is machine-specific; acceptable for a single-machine P0 and documented in README with the `NETMAX_PYTHON` override.
- SUSPICION (resolved, informational): none. No fabricated-output indicators found; shellcheck absence is environmental, noted per protocol.

**Fix-loop classification:** zero BLOCKERs; MAJOR/MINOR items requiring in-lane fixes: none. No fixes applied, therefore no post-fix rerun needed (both scripts already re-run green by verifier in §3 and §6).

## Verdict

All contract points verified with real, pasted execution evidence; reproducible build; gate 8/8 offline-green; documentation honest about signing limits.

READY-TO-MERGE
