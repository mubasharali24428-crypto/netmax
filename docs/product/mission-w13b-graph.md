# Mission W13B — "HONEST CONTEXT + FULL SUGGESTIONS SPRINT" (2 ULTIMATE teams)

Base: netmax-app @ `e20ce55`. Provider instability ongoing → WRITE-FIRST,
compressed scopes, ATLAS gates per batch, direct execution on delegate death.

## TEAM-ULTIMATE-A "Honest Context" (the trust wave)
Every feature deepens the brand: measure honestly, explain plainly.

| Lane | Suggestions | Deliverable |
|---|---|---|
| UA-1 | S-049 VPN notice + S-048 offline detection | Detect VPN/utun interfaces active during a run → amber note "Results may reflect VPN routing"; no connectivity → clear "You're offline" state instead of raw errors. Owns: netmax_wifievents.py or new netmax_netcontext.py (Python probe) + ModeLabView note UI |
| UA-2 | S-098 network change detection | Track SSID/BSSID per run in history; on network change show one-time banner "Your network changed — baselines reset" and scope baseline comparisons to same-network runs. Owns: HistoryStore.swift (add network column), ReportCardModel.swift (filter), HistoryView banner |
| UA-3 | S-028 annotations + S-057 confidence tag | Runs gain optional user annotation ("moved router"); HistoryRow shows edit affordance + displays it; thin-sample runs (<5) get honest "low n" tag on dashboard + history rows |
| UA-4 | S-079 privacy label + S-080 telemetry stance | Settings → Privacy section: "What leaves your Mac" table (nothing — with proof: grep count of network calls cited); visible telemetry = off statement |

## TEAM-ULTIMATE-B "Power & Delight" (the rest of the 100)
| Lane | Suggestions | Deliverable |
|---|---|---|
| UB-1 | S-013 saved presets + S-027 test sequences | Mode Lab: save current streams+seconds as named preset (UserDefaults list); chain 2+ modes to run back-to-back with one click |
| UB-2 | S-009 monthly PDF + S-014 run diff | Reports tab gains "Monthly Summary" card (auto-generated from last 30 days: tests run, avg speed, worst grade, anomalies count); pick any 2 runs → side-by-side diff view |
| UB-3 | S-051 week-over-week card + S-029 heatmap groundwork | Dashboard gains "vs last week" delta line per metric; hour-of-day coverage data collected (timestamp already there) → simple 24-cell strip showing when you've tested |
| UB-4 | S-034/S-035/S-073 housekeeping | History: bulk multi-select delete; retention setting (keep N days, 0=forever) enforced at load; archive-to-file on prune |
| UB-5 | S-019 notification→tab + S-061 changelog + S-100 feedback form | UNUserNotificationCenter delegate: tap opens popover to relevant tab; in-app "What's New" sheet on version change; Help menu → feedback link |

## Rules
- WRITE-FIRST every lane; skeleton before probing.
- Suite green or grows; no refactors of working code.
- Owned paths strictly per lane; cross-lane seams documented in headers.
- ATLAS: gate per team (build+suite+bundle+probe), merge per team,
  fixed-in-w13.md evidence log. Direct-execution fallback on delegate death.

## Explicitly deferred (decision-gated or XL): S-086 mesh, S-095 AI, S-099 crowd, R1 notarization ($99).
