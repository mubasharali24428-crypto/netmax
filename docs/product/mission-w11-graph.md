# Mission W11 — UX AUDIT: 200 ISSUES + 100 SUGGESTIONS (user-triggered)

> USER VERDICT (direct quote): "I don't like that in order to use the main
> feature I have to move around the app; the menu bar is not helping; the
> icons in menu bar don't have names; I can only set timer in the tab in
> seconds — what if I want minutes or hours; there is no touch-and-type
> feature. Why did you not point out these basic issues?"
>
> These five complaints are FINDING #1-5 of the audit and are FIXED FIRST.

## Confirmed core issues (from user review)
1. **Main feature buried:** running a test requires navigating tabs; the
   popover should BE the product (one-click run always visible).
2. **Menu bar icon unhelpful:** static bolt; no name/label/status at a glance.
3. **Tab icons unlabeled:** icon-only sidebar items give no words.
4. **Schedule intervals too coarse + wrong unit:** fixed [5,15,30,60] min list,
   no free entry, no hours display ("1440 minutes" absurd), no seconds option
   for testing, no direct text input.
5. **No touch-and-type:** steppers/pickers where a text field belongs.

## Structure
- **TEAM-A "Find & Fix":** 200-issue audit across every surface; fix the top
  ~40 mechanically (labels, units, fields, placement); document the rest with
  severity. Findings ledger format: ID / surface / issue / severity / status.
- **TEAM-B "Suggest 100":** 100 concrete improvement suggestions ranked by
  impact×effort, each grounded in a file path or screenshot-able surface;
  no vague "improve UX" filler — every suggestion names its change.
- Both write-first. ATLAS gates fixes per batch (build+suite+bundle+probe).

## Deliverables
1. docs/product/audit-w11/team-a-issues.md (≥200 rows)
2. docs/product/audit-w11/fixed-in-w11.md (what changed, evidence)
3. docs/product/suggestions-100.md (≥100 ranked suggestions)

## Hard rule
User's 5 issues fixed and verified before anything else merges.
