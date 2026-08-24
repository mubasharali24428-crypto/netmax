# Mission W5 — X1 QoE Timeline (marquee differentiator) — ALEX-FORCE ×20

Base: netmax-app @ `497cc11`. Concurrency: 20 agents simultaneously.
Topology: 20 builders in 4 squads of 5 + 4 verifier teams firing pipelined.

## Feature (roadmap X1)
Continuous QoE timeline: throughput/loss/jitter lanes with WiFi-event markers
(roams, RSSI drops, channel changes); before/after deltas on event hover;
correlation claims only when event ts matches sample within tolerance.

## Squads

### SQUAD 1 — Event capture (Python engine side)
| Lane | Task | Owns |
|---|---|---|
| E1 | CoreWLAN spike result doc + wifi event poller: detect SSID/BSSID/channel/RSSI changes via system_profiler polling loop | `netmax_wifievents.py` |
| E2 | Event store: JSONL append (ts, kind: roam/rssi_drop/channel_change, details), tolerant reader | `netmax_eventstore.py` |

### SQUAD 2 — Timeline data model (Swift)
| Lane | Task | Owns |
|---|---|---|
| S1 | TimelineEvent model + merged-series builder (samples + events → unified timeline rows) | `TimelineModel.swift` |
| S2 | Correlation engine: event↔sample matching within tolerance window; before/after delta computation; honest "no correlation" when none | `TimelineCorrelation.swift` |

### SQUAD 3 — Timeline UI
| Lane | Task | Owns |
|---|---|---|
| U1 | TimelineView: scrollable multi-lane chart (mbps/loss/jitter lanes stacked) using Canvas | `TimelineView.swift` |
| U2 | Event markers layer + detail popover (before/after deltas, correlation wording per law) | `TimelineEventMarkers.swift` |
| U3 | Timeline tab integration point + time-range selector (1h/24h/7d) | `TimelineRangePicker.swift` |

### SQUAD 4 — Tests & docs
| Lane | Task | Owns |
|---|---|---|
| D1 | TimelineModel + correlation unit tests (offline fixtures) | `TimelineTests.swift` |
| D2 | FEATURES.md timeline section + RELEASE-NOTES entry update | both docs (append sections only) |

## Contracts (ATLAS-fixed)
- **TC1:** TimelineRow = {ts, mbps?, lossPct?, jitterMs?, eventId?}; merge is by ts sort; missing metrics = nil (honest gaps).
- **TC2:** correlation tolerance = ±90s default (constant in TimelineCorrelation); wording law applies ("suggests", never "caused").
- **TC3:** event capture writes to ~/Library/Application Support/NetMaxDesktop/wifi_events.jsonl via E2's store.

## Merge law
Per-squad verifier teams (V-E, V-S, V-U+D) fire as squads complete. ATLAS
integrates: ScheduleRunner emits events post-run; HistoryView gains Timeline
sub-tab. Final gate = phase1 script + new timeline probes.
