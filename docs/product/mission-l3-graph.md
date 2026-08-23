# Mission L3 — Productization: customization + real features

Base: `3bdd46b`. User review drove scope: "no customization, no other features."

## Lanes (disjoint ownership; all new files unless noted)

| Lane | Feature | Owns |
|---|---|---|
| A | **Mode Lab** — run ALL 10 engine modes from the UI; params: streams (2–16 stepper), seconds (5–30), count (5–50); live status; results panel | `ModeLabView.swift` |
| B | **History + Trends** — every run appended locally; trends chart; clear-history | `HistoryStore.swift`, `HistoryView.swift` |
| C | **Settings** — default streams/seconds/count, interpreter override text field, reset onboarding button; persisted | `AppPreferences.swift`, `SettingsView.swift` |
| D | **Report export** — save last result as CSV or JSON via NSSavePanel (reuses `netmax_export.py` logic patterns) | `ReportExport.swift`, `ReportsView.swift` |

## Shared contracts (ATLAS-fixed)
- **P1 prefs keys** (UserDefaults, prefix `netmax.prefs.`): `defaultStreams`(Int,8) `defaultSeconds`(Int,10) `defaultCount`(Int,10) `pythonOverride`(String,""). Lane C writes the UI; A/B read via `AppPreferences` only — never UserDefaults directly.
- **P2 history record** (JSON line in `~/Library/Application Support/NetMaxDesktop/history.jsonl`): `{"ts": iso8601, "mode": str, "params": {...}, "result_raw": str}`. Store owns read/write/clear; views consume.
- **P3 wiring:** ATLAS integrates tabs (Dashboard / Mode Lab / History / Reports / Settings) into RootView post-delivery — builders do NOT edit RootView/App/MenuBarView.

## Rules
No git, no installs, offline-safe tests where applicable (B: store unit tests; D: format tests). Each lane verifies its own `swift build` green before reporting.
