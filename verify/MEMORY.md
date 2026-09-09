# NetMax Verifier — Memory Index

Engagement: upgrade pass (W18) — 2026-09-09T10:54:25.468Z
Target: /Users/user/netmax-app (SwiftUI menu-bar app + Python engine)

## Prior state entering (verified fresh this round)
- Suite 192/192 (before AND after W18 changes); bridge selftest 3/3; deep seal VALID (adhoc).
- F2-F19 fixed and now COMMITTED as 561a7de (W17). F1 blocked on Apple Developer account. F20 was open.

## W18 round — new state
- NF2 resolved: audit fixes committed (was 678 uncommitted lines).
- NF1 resolved: /Applications copy identical to fixed build (not stale).
- F20 DECIDED + IMPLEMENTED: SQLite adopted OPT-IN via desktop/scripts/migrate_to_sqlite.py
  (38/38 store tests; dry-run: 51 runs imported, 0 corrupt, 0600). JSONL stays primary.
- F2 follow-up IMPLEMENTED: EngineIntegrityCheck.swift (startup warn when engine dir
  group/world-writable) + 5-check harness tests + CI engine-perm gate + deep-seal gate.
- CI upgraded: store suite, deep seal, engine perms, honest counts (was "177 tests").
- docs/THREAT-MODEL.md added (audit P2-16). RELEASE-NOTES v0.7.0-draft. Settings count 157→192.
- Swift release rebuilt clean (no warnings). Bundle rebuilt, deep seal VALID, launched LIVE,
  stayed running; bridge dns run success:true; watch mode grade A live.
- DMG rebuild: in progress (bash-5), then final commit.

## New findings (W18, all resolved or info)
- NF3 (INFO, fixed): SettingsView said "157 offline tests" — suite is 192.
- NF4 (INFO, fixed): ci.yml said "177 tests" — rewritten.

## Open items for next engagement
- F1: notarization — buy Apple Developer account, run desktop/scripts/notarize.sh (pipeline ready).
- Future: SQL-grade views in Reports tab on top of history.db (F20 adoption path).
- Future: promote Swift unit tests into a real XCTest target (Package.swift has none today).
