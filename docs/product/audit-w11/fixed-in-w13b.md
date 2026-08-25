# W13B — Fixed/Delivered in This Wave (evidence log)

Base `e20ce55` → HEAD. Gates: swift release build ✓ · pytest 184 ✓ (grew
from 177: +7 netcontext offline tests) · bundle re-signed ✓ · live probe ✓.

## TEAM-UA "Honest Context" — commit ea9aacb
| Suggestion | Shipped as |
|---|---|
| S-049 VPN notice | netmax_netcontext.py get_context() (tunnel-iface w/ route = VPN; idle utuns ignored) + ModeLab amber warning |
| S-048 offline detection | Blocks run with honest message; 7 new offline tests |
| S-098 network change detection | HistoryRecord.network field (backward compatible), same-network baseline filtering, one-time change banner |
| S-028 annotations | HistoryRecord.note field, right-click Add Note…, italic display |
| S-057 confidence indicator | "low n" tag on <5-sample modes (dashboard + history) |
| S-079/S-080 privacy | Settings About privacy rows: local-only, no telemetry, endpoints cited |

## TEAM-UB "Power & Delight" — commit 7b2d672
| Suggestion | Shipped as |
|---|---|
| S-013 saved presets | PresetStore (netmax.presets) + picker + Save Preset… |
| S-027 test sequences | Sequence toggle chaining boost→bloat, persisted (netmax.sequences) |
| S-009 monthly report | Monthly Summary card (30-day stats) via existing PDF machinery |
| S-075 run diff | Compare checkbox mode → side-by-side metrics sheet |
| S-051 week-over-week | Per-card delta line vs prior-7d median, honest thin-data fallbacks |
| S-029 groundwork | 24-cell hour-of-day coverage strip under sparkline |
| S-035 bulk delete | Multi-select edit mode + confirmed bulk delete |
| S-073 retention policy | Keep-N-days stepper (0=forever), enforced at load |
| S-074 archive-on-prune | Pruned records → archive-history.jsonl, never destroyed |
| S-019 notification→tab | NotificationsDelegate: tap opens popover to relevant tab |
| S-061 changelog | What's New sheet on version change (@AppStorage seenVersion) |
| S-100 feedback form | About → GitHub Discussions link |

## Audit HIGH-tier status after W13B
All 10 HIGH items resolved or decision-gated. Remaining open items are MED/LOW
polish plus XL/decision-gated bets (i18n extraction, Sparkle/$99 cert, mesh,
AI assistant) — tracked in team-a-issues.md and UPGRADE_10X.md.
