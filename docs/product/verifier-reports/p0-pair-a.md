# P0 Pair A — B1 shell × B3 onboarding seam (verifier report)

- **Date:** 2026-08-23 (PDT)
- **Verifier lane:** Pair A of THE VERIFIERS, Mission P0 (NetMax desktop)
- **Vertical under review:** Lane B1 (Package.swift, App.swift, MenuBarView.swift, EngineClient.swift) × Lane B3 (OnboardingFlow.swift, OnboardingView.swift)
- **Baseline commit:** `b7ad013 P0 graph: signed shell + onboarding, contracts C1/C2 fixed`
- **Verdict: READY-TO-MERGE**

---

## PASS 1 — Mechanical sweep (real pasted output)

### 1. Footprint vs owned paths

```
$ git log --oneline -1 && git status --short
b7ad013 P0 graph: signed shell + onboarding, contracts C1/C2 fixed
?? desktop/
```

Footprint is exactly one untracked `desktop/` tree containing the six owned Swift files plus build artifacts. No stray edits to tracked files.

### 2. Shared UserDefaults key

```
$ grep -rn 'netmax.onboarding.complete' desktop/   # .o/binary matches omitted
desktop/SwiftNetMax/Sources/netmax-desktop/OnboardingFlow.swift:19://  "netmax.onboarding.complete" — B1's shell reads the same key to decide
desktop/SwiftNetMax/Sources/netmax-desktop/OnboardingFlow.swift:40:    static let completionKey = "netmax.onboarding.complete"
desktop/SwiftNetMax/Sources/netmax-desktop/OnboardingView.swift:145:        // Persist the exact shared key ("netmax.onboarding.complete", Bool)
```

Key matches the contract **exactly** and is centralized in `OnboardingConstants.completionKey`; `setCompleted(true)` writes `UserDefaults.standard.bool/set` Bool under it. B1 does **not** read the key anywhere in its four files (`App.swift` header comment explicitly defers the onboarding gate to the merge step). Per task instructions this is a **known merge-step item → MINOR, not a blocker**; no fix applied by the verifier (would be cross-lane wiring at the PairA seam).

### 3. Protocol conformance + honest-limits steps

```
OnboardingFlow.swift:26: /// Contract C2 — ATLAS-fixed; do not alter without coordinator sign-off.
OnboardingFlow.swift:27: protocol OnboardingFlow {
OnboardingFlow.swift:28:     var isComplete: Bool { get }
OnboardingFlow.swift:29:     mutating func advance()
OnboardingFlow.swift:30: }
OnboardingFlow.swift:44: struct DefaultOnboardingFlow: OnboardingFlow {
```

- Signature is byte-equivalent to contract C2 in docs/product/mission-p0-graph.md lines 26–28.
- `static let totalSteps = 4`; `steps` array has exactly **4** elements.
- `isComplete` = `stepIndex >= totalSteps`; `advance()` guarded idempotent; `init(stepIndex:)` clamps into range (no crash path from corrupted state).
- Step copy ↔ README "Honest limits — read this first" mapping verified line-by-line:

| README | OnboardingFlow.steps | Match |
|---|---|---|
| cannot exceed ISP cap / scamware | step 1 "Your ISP cap is the ceiling" | ✅ |
| turbo/boost gains only when contended | step 2 "Gains need a contended pipe" | ✅ |
| router QoS overrides everything | step 3 "Router QoS overrides everything" | ✅ |
| dropouts real (airtime starvation), not smoothed | step 4 "Dropouts reported honestly" | ✅ |

### 4. Anti-synthesis scan

```
$ grep -nE 'TODO|FIXME|fatalError|unimplemented' Package.swift Sources/netmax-desktop/*.swift
(no matches — exit 1)

$ grep -rnE 'as!|[a-zA-Z_\)\]]!(\.|\s|\)|$)|!\.' Sources/netmax-desktop/*.swift | grep -v '!=' | grep -v '"!'
(no matches — exit 1)
```

- No TODO/FIXME/fatalError/unimplemented markers in any of the 6 Swift files.
- No force unwraps (`!`, `as!`) anywhere; JSON parsing uses optional-binding chains throughout.
- API inventory (all real macOS 13 SwiftUI/Foundation; nothing invented):

```
8 accessibilityLabel      5 accessibilityIdentifier  3 keyboardShortcut
3 buttonStyle             3 borderedProminent        3 accessibilityValue
3 accessibilityHint       2 foregroundStyle          2 accessibilityHidden
2 accessibilityElement    2 ProgressView             1 textSelection
1 menuBarExtraStyle       1 accessibilityAddTraits   1 MenuBarExtra
```

`MenuBarExtra` + `.menuBarExtraStyle(.window)` are genuine macOS 13 APIs. EngineClient uses only Foundation (`Process`, `Pipe`, `Bundle`, `JSONSerialization`, continuations) — no fabricated symbols.

- **C1 envelope keys check:** EngineClient parses exactly `{success, data, error}`:

```
EngineClient.swift:87:  if obj["success"] as? Bool == true,
EngineClient.swift:88:     let data = obj["data"] {
EngineClient.swift:92:  let message = (obj["error"] as? String)
```

Matches contract C1 envelope shape; failure path surfaces the bridge's `error` string via `LocalizedError`.

### 5. Build proof (run by verifier)

```
$ cd desktop/SwiftNetMax && swift package clean && swift build 2>&1 | tail -3
[10/12] Linking netmax-desktop
[11/12] Applying netmax-desktop
Build complete! (5.88s)          ← clean full rebuild, exit 0

$ swift build -c release 2>&1 | tail -2
[4/5] Linking netmax-desktop
Build complete! (4.23s)          ← release, exit 0
```

Both configurations compile green from a cleaned build dir.

---

## PASS 2 — Prime judgment

### Honest-limits footer (MenuBarView)

Honored. `MenuBarView.swift:52`:

```swift
Text("Cannot exceed your ISP cap — gains appear only under contention.")
    .font(.footnote)
    .foregroundStyle(.secondary)
```

Persistent footnote covering the two headline limits (ISP ceiling, contention-only gains); steps 3–4 live in onboarding. Consistent with the product requirement that honesty is "not decoration".

### Accessibility

Present and substantive: **8 accessibilityLabel**, **3 accessibilityValue**, **3 accessibilityHint**, `.accessibilityElement(children:.combine)` so VoiceOver reads each step title+body as one element, `.accessibilityAddTraits(.isHeader)`, progress bar carries label + "Step x of 4" value while the duplicate visible caption is `accessibilityHidden(true)` (correct de-dup), decorative icon hidden. MenuBarView labels the button, results area, and status badge (children ignored, value = status). WCAG-AA claim in the file header is consistent with system semantic colors only.

### Keyboard navigation

Plausible and idiomatic: Back button has `.keyboardShortcut(.leftArrow, modifiers: [])`; Continue has `.keyboardShortcut(.defaultAction)` (Return) and is re-applied on the completion screen's "Get started". Buttons are natively focusable under Full Keyboard Access. Back is also disabled at stepIndex 0 with a matching programmatic guard in `goBack()` — belt and suspenders.

### Force unwraps on runtime paths

None found (scan in §4 returned zero matches). All fallible paths use `guard let`/`if let`; process spawn errors are converted to typed `EngineClientError`.

---

## Findings & classification

| # | Severity | Finding | Action |
|---|---|---|---|
| F1 | MINOR | B1 shell never reads `"netmax.onboarding.complete"`; App.swift shows MenuBarView directly with an explicit comment deferring the gate to the merge step | Known merge-step item per task spec — leave for coordinator seam insertion |
| F2 | MINOR (observation) | `EngineClient.python.split(separator: " ")` splits `/usr/bin/env python3` on whitespace, so a `NETMAX_PYTHON` override containing spaces in a path would break argv | In-lane cosmetic hardening possible; not a P0 contract violation, left as-is |
| F3 | INFO | OnboardingView debug-only `stepIndexOverride` init is correctly fenced inside `#if DEBUG` | None |

No BLOCKERs (compiles clean both configs, C1/C2 contracts intact, no fabricated APIs). No MAJORs (no force unwraps, accessibility and keyboard nav present). MINORs require no code change before merge.

## Files touched by verifier

- Created: `docs/product/verifier-reports/p0-pair-a.md` (this report — the only new file).
- Edited: none (no in-lane fixes required).

VERDICT: READY-TO-MERGE
