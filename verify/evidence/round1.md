# Round evidence log — 2026-09-09T10:51:52.171Z

## Stage 0 recon
- git: W17 commit 561a7de protects audit fixes (678 lines). Tree clean before W18 work.
- pytest: 192 passed (8.01s) — BEFORE and AFTER W18 changes.
- bridge selftest: 3/3 passed — BEFORE and AFTER.
- codesign (old build): adhoc, seal VALID; no pycache in bundle (0).
- appdata: all files 0600 (history.jsonl, privacy.salt, wifi_baseline.json, wifi_events.jsonl).
- running app was /Applications copy — VERIFIED IDENTICAL to fixed build (same mtime/content:
  wifievents refs 2=2, effective_timeout 2=2, engine files 21=21).

## W18 changes implemented
1. EngineIntegrityCheck.swift — startup check (audit F2 follow-up) + wired in App.init.
2. EngineIntegrityCheckTests.swift — 5-check offline harness (repo convention).
3. migrate_to_sqlite.py — F20: opt-in SQLite adoption (38/38 store tests; dry-run imported 51 runs, 0600).
4. ci.yml — deep-seal gate, engine-perm gate, store suite, honest counts.
5. docs/THREAT-MODEL.md — audit P2 item 16.
6. RELEASE-NOTES.md v0.7.0-draft; SettingsView test count 157→192.
7. Swift release rebuild: clean, no warnings (22.92s). Bundle rebuild: see bash-4 result.

## New findings (W18)
- NF1: RESOLVED-not-a-bug — /Applications copy identical to fixed build.
- NF2: RESOLVED — audit fixes committed as 561a7de (was uncommitted).
- NF3 (INFO): SettingsView advertised "157 offline tests" while suite was 192 — fixed.
- NF4 (INFO): ci.yml said "177 tests" — superseded by rewrite.
