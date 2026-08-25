# Mission W12 — FIX THE 200 + IMPLEMENT THE 100 (5 ALEX TEAMS)

Base: netmax-app @ `1a29e9e`. Inputs: audit-w11/team-a-issues.md (200 issues)
+ suggestions-100.md (100 ranked). Provider instability ongoing → ALL lanes
WRITE-FIRST, compressed scopes, ATLAS gates per batch.

## Team → work mapping (5 teams × parallel batches)

### TEAM-1 "Safety Nets" — HIGH-tier fixes first (user's daily pain)
| Lane | Issue(s) | Deliverable |
|---|---|---|
| T1-a | W11-A-093 undo absent | Undo for Clear History: soft-delete to Trash-style "cleared-history.jsonl" holding bin + Undo banner 30s after clear + "Restore last cleared" in History toolbar |
| T1-b | W11-A-091 search absent | History search bar: filters by mode/verdict/date substring on result_raw; live filtering |
| T1-c | W11-A-029 digest toggle invisible | NotificationDigest toggle row in Settings notifications section binding netmax.notify.digest |
| T1-d | W11-A-042 droppedFlags unused | ModeLabView shows inline note when envelope has droppedFlags ("measured without --count") |
| T1-e | W11-A-134 updates absent | Sparkle-feel placeholder: Settings About section gains "Check for Updates" stub that honestly reports build date + links release page |

### TEAM-2 "Discoverability" — labels, tooltips, wayfinding (audit 001-060 cluster)
| Lane | Issues | Deliverable |
|---|---|---|
| T2-a | 006,007,008,059 | Popover: running progress spinner, status badge tooltip explaining grade, pin-popover toggle so outside-clicks don't dismiss mid-review |
| T2-b | 011,012,013,041 | ModeLab: mode description visible pre-selection, parameter ranges shown inline under fields, progress bar during long runs |
| T2-c | 015,025,026,124 | Timeline: hover value readout, lane legend row, event count summary line |
| T2-d | 031,032,046 | Schedule tab: launchd jargon glossary tooltips, next-run indicator also shown on Dashboard card |

### TEAM-3 "Consistency & Words" — language unification (audit 098-148)
| Lane | Issues | Deliverable |
|---|---|---|
| T3-a | 098,099,100,147 | Terminology law: single glossary enum; sweep views → "run" (noun), "measure" (verb); title-case headers, sentence-case buttons everywhere |
| T3-b | 088,148,149 | Units clarity: Mbps tooltip "megabits per second — what ISPs advertise"; jargon tooltips on jitter/bufferbloat first mention |
| T3-c | 101,102,133,179 | Trust surfaces: Settings About gains Privacy ("nothing leaves your Mac — verified: no network code outside measurement"), methodology link, licenses row |

### TEAM-4 "Structure & Flow" — layout/flow fixes (audit 150-166)
| Lane | Issues | Deliverable |
|---|---|---|
| T4-a | 150,151 | Settings grouped nav: section picker at top scrolling to anchor; History split: Trends collapsible by default |
| T4-b | 152,153,154 | Mode Lab: config/results side-by-side at wide widths (stacks narrow); right-click context menu on history rows (Open/Copy/Delete) |
| T4-c | 164,165,157 | State persistence: remember last mode+params+filters across launches; draft-schedule warning banner on tab switch; relative timestamps refresh uniformly via shared timer |

### TEAM-5 "Suggestions Wave 1" — top-20 from suggestions-100.md
| Lane | Suggestions | Deliverable |
|---|---|---|
| T5-a | S-001 global hotkey ⌥⌘R; S-002 popover one-tap run (done—verify); S-019 notification click→tab | Hotkey center integration + notification action wiring |
| T5-b | S-008 ISP-plan comparison; S-010 export buttons on toolbar; S-032 test duration setting | Report card plan-line, History export buttons, Quick Test duration picker |
| T5-c | S-033 menu-bar label format pref; S-041 grade hover explanations; S-057 confidence indicator | MenuBar label format picker, grade tooltips, sample-size badge |
| T5-d | S-058 auto-retry once; S-059 quiet hours; S-073 retention setting | Scheduler retry-once, notify quiet-hours window, history retention days |

## Sequencing
Batches of ≤8 lanes. Batch 1 = all TEAM-1 + T2-a/T3-a (highest user pain).
Each lane: write-first, suite green, ATLAS gate (build+suite+bundle+probe).

## Deliverable docs
docs/product/audit-w11/fixed-in-w12.md updated per merged batch with evidence.
