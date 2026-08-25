# W12 — Fixed in This Wave (evidence log)

Base `1a29e9e` → HEAD. All gates: swift release build ✓ · pytest 177 ✓ ·
bundle re-signed ✓ · live probe ✓.

## User-reported (fixed first)
| # | Issue | Fix | Commit |
|---|---|---|---|
| U1 | Main feature buried in tabs | Quick Test = first, full-width, large button in popover; "Testing…" state; Target Speed directly beneath | e28f53c |
| U2 | Menu-bar icon unhelpful | Label shows "⚡ NetMax" before first run; live status after | e28f53c |
| U3 | Tab icons unlabeled | Names + tooltips on every tab | e28f53c |
| U4 | Intervals minute-only/fixed | Human-unit presets ("1 hour", "1½ hours") + 5-min stepper to 24 h + custom entry appears in picker | e28f53c |
| U5 | No touch-and-type | Stepper numeric control across full range; plan-cap stepper in Settings | e28f53c / 4beb11c |

## USER-IDEA: Target Speed mode
- Settings → "My Internet Plan" stepper (5 Mbps…1 Gbps, step 5), shared key `netmax.plan.mbps`.
- Popover Target Speed card: segmented targets = fractions of YOUR plan (2/4/5/8/10 for a 10 Mbps plan).
- Computes streams needed (~6 Mbps/stream est., clamped to engine 1–32), runs turbo with that parallelism.
- Honest shortfall line baked into the UI.
Commit 4beb11c.

## TEAM-1 Safety Nets (audit 093/091/029/042/134)
- Undo for Clear History: soft-delete to holding bin + restore merge (T1-a) — merged via batch commit 4beb11c tree state.
- History search bar filtering mode/verdict/date (T1-b) — same.
- Digest toggle surfaced in Settings notifications section w/ footer explainer (T1-c) — verified on disk (digestGateBinding present).
- droppedFlags inline note in Mode Lab (T1-d) — landed.
- Check-for-Updates honest stub linking releases (T1-e).

## TEAM-2 Discoverability — commit 092f3ad
Pin toggle (documented MenuBarExtra limitation) · grade-letter tooltip from real rubric · running spinner · mode descriptions pre-run · parameter range captions · run progress for >10 s runs · timeline hover readout · lane legend · event-count line · launchd glossary tooltips · next-auto-check indicator.

## TEAM-3 Consistency — commits a7339a9 + c3bceda (fix)
Glossary law doc · 16-string sweep · Mbps/bufferbloat/jargon tooltips at first mention · About trust rows (privacy/methodology/licenses). Regression caught at gate: sweep re-introduced broken relativeStamp; repaired c3bceda.

## TEAM-4 Structure & Flow — absorbed into 4beb11c tree
Settings section navigator w/ anchors · collapsible Trends (>50 runs) · Mode Lab side-by-side ≥700pt · history row context menu (open/copy/delete) + atomic HistoryStore.delete(record:) · lastTab/mode/params persistence · unsaved-draft banner.

## TEAM-5 Suggestions Wave 1 — commit ab53319
⌥⌘R global hotkey (global+local NSEvent monitors posting .netmaxRerunLast; idempotent install/uninstall) · plan comparison line on report card header · (remaining sub-items queued for next wave: menu-bar label format picker, quiet hours, retention stepper, auto-retry).

## Audit coverage after W12
Fixed: user 5/5 · HIGH tier 5/5 · MED/LOW fixed this wave: 14 · Remaining tracked in team-a-issues.md (mostly L/XL or decision-gated).
