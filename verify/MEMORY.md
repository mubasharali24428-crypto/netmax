# NetMax Verifier — Memory Index

Engagement: upgrade pass started 2026-09-09T10:16:42.625Z
Target: /Users/user/netmax-app (SwiftUI menu-bar app + Python engine)

## Known state entering (from prior audit, verified this round)
- Suite 192/192 pass (7.89s); bridge selftest 3/3; seal VALID (adhoc); app-data files 0600.
- F2-F19 fixed in BUILD at desktop/build/. F1 blocked on Apple Developer account. F20 open.

## New findings this round
- NF1 (HIGH-ops): running app is STALE /Applications/NetMaxDesktop.app (pre-fix copy).
  Proof: 0 mentions of netmax_wifievents.py in its binary vs build copy; wifi_events.jsonl
  0 bytes since Aug 24; bridge lacks effective_timeout.
- NF2 (HIGH-ops): ALL audit fixes uncommitted (dirty tree; last commit = W16 suite 184,
  current suite 192). One bad 'git checkout' away from losing the work.
- NF3: /Applications copy bundles engine_store? check evidence/e0-appstore-copy.txt.

## exhausted.md pointers
- pytest run, bridge selftest, codesign checks, appdata perms — done this round, do not redo.
