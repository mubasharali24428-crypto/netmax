# NetMax Terminology Law

TEAM-3 "Consistency & Words" (W12, lanes T3-a/T3-b/T3-c). This is the single
source of truth for user-facing language. Every view sweep must conform to it;
new copy must be written against it. Audit issues covered: W11-A-098, 099,
100, 147, 148, 149.

## Core terms

| Term | Role | Law |
|---|---|---|
| **run** | noun only | One measurement session and its saved history record. "a run", "Past Runs", "no speed run yet", "last 20 runs". Never a verb for taking a reading. |
| **measure** | verb | The action the user takes. "Measure in Mode Lab", "measure your line". Never "run a test", "do a check", "take a measurement". |
| **Quick Test** | proper noun | Product name of the fast mode (menu-bar / Dashboard button). Always two capitalized words. The sanctioned button label is "Run Quick Test" — sentence case plus proper noun. Generic readings never use the word "test". |
| **NetMax**, **Mode Lab**, **Quality Timeline** | proper nouns | Fixed spelling everywhere, including inside sentences. |

## Capitalization

- **Headers and section titles:** Title Case — "Mode Lab Defaults", "Alert Rules", "Past Runs".
- **Buttons and interactive controls:** sentence case — "Clear history", "Delete all history", "Reset onboarding", "Got it".
- Proper nouns stay capitalized inside sentence-case copy ("Run Quick Test", "Measure in Mode Lab").
- Tab labels (RootView) are grandfathered and excluded from the button rule.

## Units & jargon tooltip registry (first mention only)

Tooltips are attached with `.help()` at the term's first visible mention in a
surface — never repeated per occurrence.

| Term | Canonical tooltip | Placed at |
|---|---|---|
| Mbps | Megabits per second — the unit ISPs advertise | DashboardCardsView · Latest Speed card |
| jitter | Variation in ping delay — lower is steadier | *reserved* — first mention lives on the Quality Timeline "Jitter" lane label (QoETimelineView, outside TEAM-3's owned paths); apply this exact copy when that surface is next edited |
| bufferbloat | Latency increase under load — hurts video calls | DashboardCardsView · Bufferbloat card; BloatStoryView · story card header |

## Trust surfaces (W11-A-101, 102, 133)

The Settings → About section carries three standing rows:

- **Privacy** — All data stays on this Mac. The app makes no telemetry calls.
- **Methodology** — Grades use Waveform/DSLReports-style latency-under-load rubric.
- **Licenses** — SwiftUI · Apple engines · no third-party runtime deps

Copy changes to these rows must go through this doc first.

## W12 sweep record (evidence for fixed-in-w12)

Before → after, user-visible strings only (behavior untouched):

| File | Before | After |
|---|---|---|
| MenuBarView | "Starts a short NetMax engine test…" | "Starts a short Quick Test…" |
| MenuBarView | a11y "Engine test results" | "Quick Test results" |
| MenuBarView | "run a test to assess" | "no runs to assess yet" |
| MenuBarView | "Run a test to see your speed trend" | "Measure to see your speed trend" |
| RootView | help "Dashboard — run tests, …" | "Dashboard — live metrics and Quick Test (⌘1)" |
| HistoryView | "Run a measurement to see its trend here." | "Measure to see its trend here." |
| HistoryView | "No measurements yet. Start a run…" | "No runs yet. Measure in Mode Lab…" |
| HistoryView | "Clear History" / "Delete All History" | "Clear history" / "Delete all history" |
| HistoryView | help "Delete all saved measurement history" | "Delete all saved runs" |
| SettingsView | "Reset Onboarding" (×2) | "Reset onboarding" |
| SettingsView | "A measurement fails…" / footer "every measurement" | "A run fails…" / "every run" |
| DashboardCardsView | "run a test to assess" | "no runs to assess yet" |
| DashboardCardsView | "No measurements yet" (empty state) | "No runs yet" |
| DashboardCardsView | help "Reload measurement history from disk" | "Reload saved runs from disk" |
