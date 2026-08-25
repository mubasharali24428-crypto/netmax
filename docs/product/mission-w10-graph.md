# Mission W10 — NEXT UPGRADES (P4 + P6 + R5 groundwork)

Base: netmax-app @ `fd1ab63`. ATLAS-direct (provider instability persists).

## Lanes

| Lane | Task | Owns |
|---|---|---|
| W10-1 (P4) | Menu-bar popover mini-timeline: compact sparkline strip (last 20 mbps, Theme.accent, 28pt tall) under the metric-card row in MenuBarView; reuses SparklineView; taps through to full timeline sheet; honest empty-state ("run a test") | MenuBarView.swift |
| W10-2 (P6a) | A11y round-2 audit: VO-walk every tab via accessibility labels inventory; fix missing labels/hints/trait mismatches found; contrast check on secondary text over materials | report + small fixes across views |
| W10-3 (R5 groundwork) | String externalization prep: extract user-facing literals in RootView/MenuBarView/HistoryView into a Strings enum (netmax.strings pattern) WITHOUT changing visible text — pure refactor enabling future i18n | new AppStrings.swift + touched views |
| W10-4 (P2b) | Feature discovery cards: first-launch Settings section "What NetMax can do" — 4 rows (Timeline, Report Cards, Automation, Shortcuts) each with icon + one-line pitch + deep-link action | SettingsView.swift |

## Rules
Write-first per lane. Suite green or grows. No behavior changes except where stated.
Gate: build release + suite + bundle + live probe → single commit.
