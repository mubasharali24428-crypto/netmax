# NetMax Desktop — Dormant / Latent Bug Audit

**Scope:** all 74 `.swift` files under `desktop/SwiftNetMax/Sources/netmax-desktop/` (~20,950 lines)  
**Date:** 2026-09-23  
**Method:** full-file read of every source + verification greps; line numbers verified against current tree.

---

## CRITICAL

### C1. Post-run pipeline never called — menu bar, alerts, and reload notifications are dead after Mode Lab / Quick Test runs
- **File / lines:** `RunPostProcessor.swift:1-262` (definition); call sites: `ModeLabView.swift:811-814`, `MenuBarView.swift:249-289`, `WifiPanelView.swift:~405`
- **Severity:** CRITICAL
- **Category:** Error propagation / feature integration
- **Bug:** `RunPostProcessor.process` is the only production poster of `.netmaxHistoryDidChange` and the only preference-gated alert path, but no production code ever calls it — only its own DEBUG self-check does (`RunPostProcessor.swift:242`).
- **Trigger:** Complete any Mode Lab run, menu-bar Quick Test, or Wi-Fi panel run → `HistoryStore.append` succeeds, but `StatusPublisherHook.swift:74-78` never receives the change event, `StatusBarController` is not refreshed, and degradation alerts never evaluate.
- **Fix:** Call `RunPostProcessor.process(record)` immediately after each production `HistoryStore.append` (ModeLab, MenuBar Quick Test, WifiPanel), per the header contract at `RunPostProcessor.swift:25-31`.

### C2. ScheduleRunner re-evaluates the full history on every fire — notification spam
- **File / lines:** `ScheduleRunner.swift:237-249` → `Notifications.swift:203-204`
- **Severity:** CRITICAL
- **Category:** Notifications / correctness
- **Bug:** After each scheduled append, `NotificationCoordinator.shared.process(records: records)` runs `evaluateDegradation` over the **entire** history array, re-posting every historical degradation (same-day repeated fires re-queue old alerts). Master switch is checked; per-rule `NotificationPreferences` are not.
- **Trigger:** Enable scheduled checks; leave a grade-drop / high-loss / success→failure pair anywhere in history → every interval re-fires those old alerts.
- **Fix:** Evaluate only the final pair (reuse `RunPostProcessor.alerts(triggeredBy:in:)` + `deliverableAlerts`) and hand **those** alerts to the coordinator, not `records` wholesale.

### C3. `RunPostProcessor.deliverDegradationAlerts` also bypasses its own pair filter
- **File / lines:** `RunPostProcessor.swift:126-140`
- **Severity:** CRITICAL
- **Category:** Notifications / correctness
- **Bug:** Line 133 computes preference-filtered `pending` for the final pair only, then line 139 calls `NotificationCoordinator.shared.process(records: records)` with the **full** history — `pending` is computed and discarded (`_ =`).
- **Trigger:** Any future wiring of `RunPostProcessor.process` → coordinator re-evaluates whole history despite the file’s own comment claiming “exactly the alert we selected” (`RunPostProcessor.swift:136-138`).
- **Fix:** Post only `pending` (add a coordinator API that accepts `[DegradationAlert]` directly).

---

## HIGH

### H1. `NetContextProbe` failure returns `""` → treated as offline → Mode Lab refuses to run
- **File / lines:** `NetContext.swift:14-16` (contract), `:103-117` (run), `:84-89` (isOnline), `ModeLabView.swift:685-690`
- **Severity:** HIGH
- **Category:** Process / networking / correctness
- **Bug:** Header promises probe failure degrades to `(online: true, vpn: false)`; `run()` catch returns `""`, and `isOnline("")` returns `false`, so failure reads offline. Mode Lab hard-gates on `netContext.online`.
- **Trigger:** `/sbin/ifconfig` spawn fails (permissions, sandbox, missing binary) → user always sees “You appear to be offline” and cannot start any Mode Lab run, even while online.
- **Fix:** On probe failure return `NetContext(online: true, vpn: false)` (or make `detect()` treat empty `ifconfig` as unknown→online).

### H2. Menu-bar Quick Test and Target Speed never persist history
- **File / lines:** `MenuBarView.swift:249-268` (target path), `:271-289` (quick path)
- **Severity:** HIGH
- **Category:** Data / state
- **Bug:** Both paths run the engine then `reloadHistory()` with the comment “fresh run lands in the cards immediately”, but neither calls `HistoryStore.append`. Reload is a no-op for the new run.
- **Trigger:** Run Quick Test or Target Speed from the ⚡ menu → result text shows, but History / Dashboard / Reports / status bar never see a new record.
- **Fix:** After success, `HistoryStore.shared.append(...)` (and `RunPostProcessor.process`) with mode/params/raw, same as Mode Lab.

### H3. Target Speed button permanently disables after first use
- **File / lines:** `TargetSpeedView.swift:17`, `:88-96`; caller `MenuBarView.swift:~249`
- **Severity:** HIGH
- **Category:** SwiftUI state
- **Bug:** `isRunning = true` before `onRun`; nothing ever sets it back to `false` (callback has no completion, no observation of run end).
- **Trigger:** Click “Reach N Mbps” once → button stays disabled for the life of the view; second target run impossible without recreating the view.
- **Fix:** Reset `isRunning` in `onRun` completion (add a completion callback) or derive running state from `MenuBarView.status`.

### H4. `WifiEventEmitter` undrained pipes before `waitUntilExit` — subprocess deadlock
- **File / lines:** `WifiEventEmitter.swift:70-77`
- **Severity:** HIGH
- **Category:** Process / concurrency
- **Bug:** stdout/stderr `Pipe`s are installed and never read; `waitUntilExit()` blocks while the child blocks on a full pipe buffer (~64KB).
- **Trigger:** `netmax_wifievents.py --once` writes enough output to fill the buffer → `runOnce` hangs forever on the utility queue; `inFlight` stays `true` (`:41-44`) → all future `captureNow()` calls are no-ops.
- **Fix:** Use `FileHandle.nullDevice` for stderr, or drain both pipes (async readability / `readDataToEndOfFile`) before `waitUntilExit`.

### H5. `WifiEventEmitter.inFlight` / static state races
- **File / lines:** `WifiEventEmitter.swift:12-13`, `:37-45`
- **Severity:** HIGH
- **Category:** Concurrency
- **Bug:** `inFlight` is a non-atomic static `Bool` written from the calling thread and the queue; `lastSnapshot` (`:13`) is assigned never used (dead). `pythonPath` static initializer runs on first use (OK) but `inFlight` is a classic check-then-act race.
- **Trigger:** Concurrent `captureNow()` from overlapping ScheduleRunner fires / UI → double spawn or stuck `true`.
- **Fix:** Gate with `os_unfair_lock` / serial queue ownership of `inFlight`; delete unused `lastSnapshot`.

### H6. Daily digest toggle is a dead feature
- **File / lines:** `NotifyDigest.swift:18` (only integration note, never called); UI `SettingsView.swift:281-295`, binding `:330-343`
- **Severity:** HIGH
- **Category:** Dead code / misleading UI
- **Bug:** Settings exposes “Daily digest instead of individual alerts” bound to `netmax.notify.digest`, but production never calls `NotifyDigest.consider` or `flushIfDue` (only doc comment + self-check). Alerts always post individually (and only if C1/C2 paths run at all).
- **Trigger:** Enable digest → footer promises “ONE summary roughly every 24 hours” → nothing digests; behavior unchanged.
- **Fix:** Wire `NotifyDigest.consider` from the alert path and `flushIfDue` from `ScheduleRunner` tick (as the file header says), or remove/hide the toggle.

### H7. Interpreter Settings help text contradicts actual resolution
- **File / lines:** `SettingsView.swift:222`, `:240`, `:231`; `EngineClient.swift:30-47`; `AppPreferences.swift:147-149`
- **Severity:** HIGH
- **Category:** Misleading UI / honesty contract
- **Bug:** Footer/hint say empty override → “python3 from PATH”; `EngineClient` empty override → hard `/usr/bin/python3` (F11 security fix). Invalid path warning claims “fall back to python3 on PATH” but code also falls back to `/usr/bin/python3`. `AppPreferences.resolvedInterpreter` still returns bare `"python3"` and is unused by `EngineClient`.
- **Trigger:** User reads Settings, believes PATH lookup is used; or sets invalid path expecting PATH fallback docs.
- **Fix:** Update hint/footer/warning to `/usr/bin/python3`; delete or repoint dead `resolvedInterpreter`.

### H8. License trial starts on every first launch, including headless/dev
- **File / lines:** `LicenseGate.swift:64-69`, env overrides `:86-95`
- **Severity:** HIGH
- **Category:** License / trial logic
- **Bug:** `init` stamps a 14-day trial the first time defaults are empty — no explicit user action. `NETMAX_LICENSE_MODE` / `NETMAX_LICENSE_DISABLED` force tiers from the environment with no production guard.
- **Trigger:** Fresh install (or cleared defaults) → clock starts immediately; env var in a developer’s shell or a launchd plist silently forces Pro/Free.
- **Fix:** Start trial only on explicit “Start trial” / first gated feature use; compile-gate or log-warn env overrides outside DEBUG.

---

## MEDIUM

### M1. ScheduleRunner parses run seconds positionally from `args[1]`
- **File / lines:** `ScheduleRunner.swift:70`, `:218-220`
- **Severity:** MEDIUM
- **Category:** Latent correctness
- **Bug:** `Int(args[1])` assumes `runArgs == ["--seconds", "<n>"]`. Any future change to flag order/extra flags silently records wrong `params.seconds` (or defaults to 10).
- **Trigger:** Change `runArgs` to `["--streams","4","--seconds","10"]` → params become `seconds: 4`.
- **Fix:** Scan args for the `--seconds` flag; or parse from a typed struct, not raw argv.

### M2. Duplicate ScrollView anchor id — History Retention scrolls to Startup
- **File / lines:** `SettingsView.swift:255` (startup) and `:403` (historyRetention)
- **Severity:** MEDIUM
- **Category:** SwiftUI navigation/state
- **Bug:** Both sections use `.id(SettingsSection.startup.id)`.
- **Trigger:** Settings sidebar jump targeting History Housekeeping lands on Startup (or ambiguity in `scrollTo`).
- **Fix:** Add `SettingsSection.historyRetention` and use it at `:403`.

### M3. Conflicting duration / stream ranges across layers
- **File / lines:** `AppPreferences.Limits` (seconds/streams clamps), `ModeLabView.swift:827-828` (seed 5…30 / 2…16), `TargetSpeedView.swift:34` (1…32), `DurationEntryView` (5…21600)
- **Severity:** MEDIUM
- **Category:** Hardcoded values / consistency
- **Bug:** UI seed clamps seconds to ≤30 and streams to ≤16, prefs allow wider, Target Speed allows 32 streams and 10 s, DurationEntry allows 6 h — engine bridge validates `--seconds 5..30`.
- **Trigger:** DurationEntry sets seconds=600 → engine rejects or behaves differently than Mode Lab steppers imply; Target Speed can request 32 streams outside Mode Lab’s seeded max.
- **Fix:** Single source of truth for parameter ranges (catalog / prefs); UI clamps read from it.

### M4. Mode Lab “Stop” does not abort a multi-leg sequence
- **File / lines:** `ModeLabView.swift:574-577`, `:734-761`
- **Severity:** MEDIUM
- **Category:** Process control
- **Bug:** Stop sets `runStoppedByUser` and SIGKILLs current process; `runSequence()` never checks the flag between legs and always continues the chain; sequence path never sets `status` from stop.
- **Trigger:** Start sequence mode → press Stop mid-leg → next legs still launch (or UI shows stopped while chain continues).
- **Fix:** Check `runStoppedByUser` / observe `.netmaxRunStopped` at the top of each sequence iteration and break.

### M5. `StatusBarController.publish(store:)` vs `StatusPublisherHook` newest-record selection
- **File / lines:** `StatusPublisherHook.swift:96-105` (documented `.last`), `StatusBarController.publish(store:)` (`max { $0.ts < $1.ts }` pattern)
- **Severity:** MEDIUM
- **Category:** Consistency
- **Bug:** Two “newest record” algorithms on same-second `ts` ties (ISO8601 second granularity) can show different menu-bar lines depending on path (schedule fire vs change-hook).
- **Trigger:** Two runs in the same second; schedule path publishes `max(ts)`, hook path publishes file-order last.
- **Fix:** Always use file-order `.last` (hook’s rationale); implement once in `StatusBarController`.

### M6. Quiet hours not user-tunable despite comment
- **File / lines:** `Notifications.swift:177-180`
- **Severity:** MEDIUM
- **Category:** Dead / incomplete config
- **Bug:** Comment says “user-tunable via AppPreferences”; fields are hardcoded defaults with no prefs keys or Settings UI.
- **Trigger:** User expects to change 22:00–07:30 window — cannot.
- **Fix:** Persist under `netmax.notify.*` or correct the comment.

### M7. `HistoryStore.deleteMany` double-reads the file under lock
- **File / lines:** `HistoryStore.swift` (deleteMany path ~420-460 region)
- **Severity:** MEDIUM
- **Category:** Performance / I/O
- **Bug:** Reads the full JSONL twice (once to filter, once to rewrite) while holding `NSLock`.
- **Trigger:** Large history + bulk delete (UI multi-select) → main-thread-ish stall for writers.
- **Fix:** Single read → filter → atomic write (already the pattern in restore/retention).

### M8. `HistoryStore` / mutators still do not post `.netmaxHistoryDidChange`
- **File / lines:** `StatusPublisherHook.swift:14-19` (false claim), `HistoryStore.swift` (append/clear/delete have no post)
- **Severity:** MEDIUM
- **Category:** Documentation / integration
- **Bug:** Hook header says HistoryStore mutators post the notification; only `RunPostProcessor` (unwired) does. Clear/restore/delete also never notify observers.
- **Trigger:** Clear history from History toolbar → empty overlays / hook observers that rely on the name never refresh via notification (HistoryView has its own reload; overlays if adopted would not).
- **Fix:** Post `.netmaxHistoryDidChange` from HistoryStore mutators on main queue, or fix the hook comment and post from every caller.

### M9. Drop-in components compiled but never mounted (dead features)
- **File / lines:** `BloatStoryView.swift`, `WifiDashboardSection.swift`, `ReportsEmptyIntegration.swift`, `HistoryEmptyIntegration.swift`, `OnboardingScheduleHost.swift`, `OnboardingScheduleStep.swift`, `ModeLabErrorView.swift`, `BackgroundRunnerControlsView.swift`, `GlobalHotkey.swift` (`App.swift:45` commented)
- **Severity:** MEDIUM
- **Category:** Dead code
- **Bug:** Full implementations exist (some with a11y + self-checks) but no production call sites outside their own files/previews; Schedule Editor glossary even documents `BackgroundRunnerControlsView` as living elsewhere (`ScheduleEditorView.swift:152-153`) while the controls view is not in the Settings/Schedule Form.
- **Trigger:** N/A at runtime; cost is confusion + false sense of shipped features (empty-state overlays, background runner UI, bloat story, global hotkey).
- **Fix:** Wire intentionally or mark/remove; track in IMPROVEMENTS.

### M10. `LicenseGate.canUse` ignores which feature
- **File / lines:** `LicenseGate.swift:107-109`
- **Severity:** MEDIUM
- **Category:** License logic
- **Bug:** `feature` parameter unused — every paid feature is the same tier check. Fine if intentional; Feature enum implies differentiation that does not exist.
- **Trigger:** Expect Free to allow some Feature cases — all gated identically once trial ends.
- **Fix:** Document “all-or-nothing tier” or implement per-feature policy.

---

## LOW

### L1. `EngineClient.stopCurrent` SIGKILL PID-recycle window
- **File / lines:** `EngineClient.swift` (`stopCurrent` / `engineCurrentProcess`)
- **Severity:** LOW
- **Category:** Process
- **Bug:** Kill based on process handle after possible exit → theoretical PID reuse.
- **Trigger:** Engine exits between `isRunning` check and signal.
- **Fix:** Check `isRunning` immediately before each signal; prefer SIGTERM wait then SIGKILL only if still running.

### L2. `BackgroundRunner.xmlEscape` omits quotes/angles for attributes
- **File / lines:** `BackgroundRunner.swift` (xmlEscape)
- **Severity:** LOW
- **Category:** Process / launchd plist
- **Bug:** Escape incomplete if ever used for attribute values (currently path text nodes — OK).
- **Trigger:** Path containing `"` if used in attributes later.
- **Fix:** Escape `&<>"'` fully or restrict to text nodes with a comment.

### L3. Target Speed hardcoded `perStreamEstimate = 6.0`
- **File / lines:** `TargetSpeedView.swift:32-34`
- **Severity:** LOW
- **Category:** Hardcoded values
- **Bug:** Magic throughput-per-stream constant; estimate can be wildly wrong on gigabit or 2 Mbps links.
- **Trigger:** 1000 Mbps plan, 10 Mbps target → stream count vs actual throughput diverge.
- **Fix:** Label clearly as estimate (already partly done); consider adaptive estimate from last run.

### L4. Keyboard shortcut mapping (verified OK)
- **File / lines:** `KeyboardShortcuts.swift` vs `RootView` labels
- **Severity:** LOW
- **Category:** Verification note
- **Bug:** Mapping checked consistent with tab labels — **not** a bug; recorded so it is not re-audited.
- **Fix:** None.

### L5. `#if DEBUG` density (51 matches)
- **File / lines:** throughout; harnesses only under DEBUG in `App.swift:26-32`, `main.swift`
- **Severity:** LOW
- **Category:** Debug traps
- **Bug:** No release-path DEBUG traps found that would change production behavior incorrectly; self-checks are DEBUG-only by design.
- **Fix:** None required.

---

## IMPROVEMENTS (not bugs)

1. **Wire or delete drop-in views** (M9): BloatStory, WifiDashboardSection, empty-state integrations, ModeLabErrorView, BackgroundRunnerControlsView, OnboardingSchedule* — decide product scope.
2. **Single post-run entry point:** make every `HistoryStore.append` fan through `RunPostProcessor` (C1) so menu bar / notifications / reloads cannot be forgotten again.
3. **Notification architecture:** pair-scoped evaluation + per-rule prefs in ScheduleRunner (C2/C3); coordinator API taking `[DegradationAlert]`.
4. **Parameter range SSOT** (M3): one `ModeParameter` catalog driving prefs, Mode Lab, Target Speed, DurationEntry, bridge validation.
5. **HistoryStore change notification** (M8): post from mutators; keep hook comment honest.
6. **Unify newest-record selection** (M5) inside `StatusBarController`.
7. **Interpreter docs / `resolvedInterpreter` cleanup** (H7).
8. **License trial activation UX + env override policy** (H8).
9. **Persistent quiet hours** (M6) or fix comment.
10. **WifiEventEmitter hardening** (H4/H5): nullDevice or drain, atomic inFlight, delete `lastSnapshot`.
11. **Sequence-stop** (M4) and Target Speed completion (H3).
12. **Settings scroll anchors** (M2): enum case for every section id.
13. **Digest wiring or hide toggle** (H6).
14. **Quick Test persistence** (H2) — same append + post-process as Mode Lab.
15. **NetContext fail-open** (H1) to match documented contract.
16. **ScheduleRunner argv parsing** (M1): named-flag parse.
17. **Performance:** `deleteMany` single-read rewrite (M7); consider memory-mapping large JSONL later.

---

## Critical logic with ZERO test coverage

Package has **no SPM test target** (`Package.swift`); tests are plain `enum … { static func runAll() }` harnesses invoked from `main.swift` / DEBUG App init only.

| Critical logic | Existing coverage | Gap |
|---|---|---|
| `RunPostProcessor.process` production wiring | Self-check only (`RunPostProcessorSelfCheck`) | **No test asserts any Mode Lab / MenuBar / WifiPanel call site invokes `process`** — C1 would pass all self-checks |
| `RunPostProcessor.deliverDegradationAlerts` full-history bypass | Not covered (private path) | C3 invisible to `alerts`/`deliverableAlerts` unit checks |
| `ScheduleRunner.appendAndPublish` → `NotificationCoordinator.process` full history | `ScheduleRunnerSelfCheck` uses `notificationsAllowed: { false }` | Spam path never executed |
| `NotifyDigest.consider` / `flushIfDue` in production | `NotifyDigest` self-check | **Zero production callers** — feature untested end-to-end |
| `NetContextProbe.run` failure → online | Parse self-check with canned text only | Failure/empty `ifconfig` → `isOnline` never asserted against contract |
| `MenuBarView` Quick Test / Target Speed persistence | None | H2/H3 untested |
| `WifiEventEmitter.runOnce` pipe/process | None | H4/H5 untested |
| `TargetSpeedView.isRunning` lifecycle | None (no UI tests) | H3 untested |
| `StatusBarController.publish(store:)` vs hook `.last` tie-break | Hook self-check only | Divergent “newest” untested |
| `ModeLabView` sequence + Stop | None | M4 untested |
| `NotificationCoordinator.process` per-rule prefs | Preferences covered indirectly via `deliverableAlerts` self-check; coordinator not | Full-history + quiet-hours integration thin |
| `LicenseGate.canUse` feature differentiation | `LicenseGateTests` covers expired/pro feature calls | Ignores `feature` — tests do not catch M10 |
| `GlobalHotkey` | None + install commented out | Dead |
| `HistoryStore` mutators posting change notification | Hook self-check **simulates** the post manually | Production mutators never post (M8) untested |
| `ScheduleRunner` params parse (`args[1]`) | Self-check hardcodes `== ["--seconds","10"]` | M1 latent break not covered |
| `SettingsView` anchor ids | None (UI) | M2 not covered |
| Interpreter empty/override resolution in `EngineClient` | None observed | H7/docs drift |

**Test files present:** `HistoryStoreTests.swift`, `LicenseGateTests.swift`, `EngineIntegrityCheckTests.swift`, `TimelineTests.swift` (+ many `*SelfCheck` DEBUG enums).

---

## Verification notes

- Confirmed by grep: zero production `RunPostProcessor.process(` call sites; only `NotifyDigest` doc reference for `consider|flushIfDue`; `GlobalHotkey.install` commented at `App.swift:45`; duplicate `.id(SettingsSection.startup.id)` at `SettingsView.swift:255` and `:403`.
- No build/lint run for this audit (read-only analysis). Re-run greps above after any fix to confirm wiring.

---

## Status

**Snapshot: 2026-09-23, end of the improvements session** (H1–H7 / M1–M10 were being fixed in parallel by other agents; "fixed" below means verified in-tree by grep at this moment, not authorship). Verified with `bash desktop/scripts/run_swift_selftests.sh` → **all green (20 harnesses)**.

### CRITICAL

| ID | Status | Evidence / note |
|---|---|---|
| C1 | **FIXED** | `process(record)` called after every production append: `ModeLabView.swift:817`, `MenuBarView.swift:267` + `:295`, `WifiPanelView.swift:410`, `ScheduleRunner.swift:243-254` (publish + pair path). Header contract strengthened this session (MUST-after-append + site list). |
| C2 | **FIXED** | `ScheduleRunner.swift:249-252` evaluates only the final pair via `RunPostProcessor.alerts`/`deliverableAlerts`, hands `pending` to `coordinator.process(alerts:)`. |
| C3 | **FIXED** | `RunPostProcessor.swift:146-149` posts `pending` via `NotificationCoordinator.process(alerts:)` — not full history. |

### HIGH

| ID | Status | Evidence / note |
|---|---|---|
| H1 | **FIXED** | `NetContext.swift:30-34`: empty `ifconfig` ⇒ `NetContext(online: true, vpn: false)` before `isOnline("")` can run. |
| H2 | **FIXED** | Both ⚡ paths append + process: `MenuBarView.swift:260-267`, `:290-295`. |
| H3 | **FIXED** | `TargetSpeedView.swift:91-93` — `onRun` completion resets `isRunning = false`; `MenuBarView.swift:69-72` passes `finished`. |
| H4 | **FIXED** | `WifiEventEmitter.swift:81-82` — stdout/stderr → `FileHandle.nullDevice` (no undrained pipes before `waitUntilExit`). |
| H5 | **FIXED** | `WifiEventEmitter.swift:15,41-54` — `NSLock` guards `inFlight` check-then-act; dead `lastSnapshot` removed. |
| H6 | **FIXED** | `Notifications.swift:217` calls `NotifyDigest.consider`; `ScheduleRunner.swift:211` calls `flushIfDue` on tick. |
| H7 | **FIXED** | `SettingsView.swift:220,224,233,242` all say `/usr/bin/python3`; `AppPreferences.resolvedInterpreter` deleted. |
| H8 | **OPEN** | `LicenseGate.swift:64-69` still stamps trial on first launch; env overrides `:86-95` unguarded (product decision). |

### MEDIUM

| ID | Status | Evidence / note |
|---|---|---|
| M1 | **FIXED** | `ScheduleRunner.swift:72-76` flag-scan parse + self-check cases `:341-346`. |
| M2 | **FIXED** | `SettingsView.swift:405` uses unique `.id(SettingsSection.historyRetention.id)`. |
| M3 | **FIXED** | New `EngineParameterRanges.swift` SSOT (mirrors `engine_bridge.py RANGE_BOUNDS`); ModeLab `ModeParameter`, `ModeLabView` seed, `DurationEntryView`, `TargetSpeedView`, and `AppPreferences.Limits` comments all read from it. |
| M4 | **FIXED** | `ModeLabView.swift:713,744,756` check `runStoppedByUser` and `break` between/inside legs. |
| M5 | **FIXED** | `StatusBarController.swift:110-117` uses file-order `.last`, same as hook. |
| M6 | **FIXED** | Quiet hours persisted under `netmax.notify.quiet{Start,End}{Hour,Minute}` via `NotificationPreferences`; `NotificationCoordinator` reads the shared prefs; Settings “Quiet Hours” steppers with a11y ids. |
| M7 | **FIXED** | `HistoryStore.swift:429` — single read → filter → atomic write. |
| M8 | **FIXED** | `HistoryStore.swift:191` + `postHistoryDidChange()` (`:516-523`) from mutators. |
| M9 | **OPEN** | Drop-ins still unmounted (`App.swift:45` `GlobalHotkey.install` still commented; BloatStory/WifiDashboard/empty-integration/BackgroundRunnerControls/OnboardingSchedule* not mounted) — deferred as product decision (improvement 1). |
| M10 | **FIXED (documented)** | `LicenseGate.swift:108-109` documents all-or-nothing tiers; `feature` intentionally unused. |

### LOW

| ID | Status | Evidence / note |
|---|---|---|
| L1 | **FIXED** | `EngineClient.stopCurrent` captures PID while the handle is known-running; SIGKILL re-checks `process.isRunning` before signalling (narrows PID-recycle window). |
| L2 | **FIXED** | `BackgroundRunner.swift` `xmlEscape` now escapes `& < > " '` (this session). |
| L3 | **FIXED** | `TargetSpeedView.adaptivePerStreamEstimate()` derives Mbps/stream from the last history record (`params.streams` + `MetricExtractor.latestSpeedMbps`); falls back to 6.0. |
| L4 / L5 | **OK (n/a)** | No action required per audit. |

### IMPROVEMENTS

| # | Status |
|---|---|
| 1 (drop-ins) | OPEN — M9 product decision (M-agent lane). |
| 2 (single post-run entry) | **DONE** — contract documented in `RunPostProcessor.swift` header (this session); all append sites verified wired. |
| 3 (coordinator `[DegradationAlert]` API) | **DONE (pre-existing)** — `NotificationCoordinator.process(alerts:now:)` exists (`Notifications.swift:211`); `RunPostProcessor` + `ScheduleRunner` both use it. No duplicate added. |
| 4 (parameter range SSOT) | **DONE** — `EngineParameterRanges.swift` + all UI call sites. |
| 5 (M8 notification) | **DONE** (by M agent). |
| 6 (M5 newest-record) | **DONE** (by M/H agent). |
| 7 (resolvedInterpreter / H7 docs) | **DONE** — H7. |
| 8 (license trial UX) | OPEN — H8 (product decision). |
| 9 (quiet hours) | **DONE** — M6 persistence + Settings UI + coordinator wiring. |
| 10 (WifiEventEmitter hardening) | **DONE** — H4/H5. |
| 11 (sequence-stop + target completion) | **DONE** — M4 + H3. |
| 12 (settings anchors) | **DONE** — M2. |
| 13 (digest wiring) | **DONE** — H6. |
| 14 (Quick Test persistence) | **DONE** — H2. |
| 15 (NetContext fail-open) | **DONE** — H1. |
| 16 (ScheduleRunner argv) | **DONE** — M1. |
| 17 (deleteMany perf) | **DONE** — M7. |

**This session's edits (improvements lane):** `RunPostProcessor.swift` (C1 header contract), `BackgroundRunner.swift` (L2 xmlEscape), `AppPreferences.swift` (M3/improvement-4 SSOT comment), `AUDIT_REPORT.md` (this Status section). WifiPanelView verified already wired — no edit.

**Deferred-debt lane (follow-up session):** L1 (`EngineClient` PID capture), L3 (adaptive `perStreamEstimate`), M3 (`EngineParameterRanges` SSOT), M6 (quiet-hours persistence + Settings UI), Python `--adaptive` wiring (`netmax.py` + `AdaptiveController.initial_streams`), `_truncate` budget at every depth, `IncompleteRead`/`OSError` → `NetMaxError` in `netmax_fetch._read_block`. Regression tests: `tests/test_audit_deferred_debt.py`. Engine copies of `netmax.py` / `netmax_fetch.py` re-synced.

**Open at snapshot:** H8 (license trial — product decision), M9 (drop-in views — product decision).
