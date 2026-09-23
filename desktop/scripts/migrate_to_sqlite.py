#!/usr/bin/env python3
"""W18 / audit F20: opt-in SQLite migration for NetMax Desktop.

DECISION (F20, 2026-09-08): the engine_store layer is ADOPTED as the
forward-looking store, but OPT-IN: history.jsonl remains the primary,
always-on store (atomic appends, corrupt-line tolerance); this tool
imports existing JSONL history into the SQLite store for users who want
SQL-grade queries and retention. Rationale: the layer is complete and
38/38 tests pass (desktop/engine_store/test_store.py), but the app's
read paths (HistoryStore.load) and the risk-free append path (JSONL
atomic write) are battle-tested — a silent format switch mid-audit-cycle
would change behavior with no user-visible benefit today.

Usage:
    python3 desktop/scripts/migrate_to_sqlite.py [--db PATH] [--jsonl PATH]

Defaults: db   = ~/Library/Application Support/NetMaxDesktop/history.db
          jsonl= ~/Library/Application Support/NetMaxDesktop/history.jsonl

The migration is idempotent ((ts, mode) pairs already present are
skipped — see engine_store.migrate_from_jsonl). Safe to re-run anytime.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from desktop.engine_store.store import Store

APP_SUPPORT = Path.home() / "Library" / "Application Support" / "NetMaxDesktop"


def main(argv: list[str]) -> int:
    db_path = APP_SUPPORT / "history.db"
    jsonl_path = APP_SUPPORT / "history.jsonl"

    args = argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--db" and i + 1 < len(args):
            db_path = Path(args[i + 1]).expanduser()
            i += 2
        elif args[i] == "--jsonl" and i + 1 < len(args):
            jsonl_path = Path(args[i + 1]).expanduser()
            i += 2
        else:
            print(f"unknown arg: {args[i]}", file=sys.stderr)
            return 2
    if i < len(args):
        return 2

    if not jsonl_path.exists():
        print(f"no history file at {jsonl_path} — nothing to migrate")
        return 0

    print(f"migrating {jsonl_path} -> {db_path}")
    db_path.parent.mkdir(parents=True, exist_ok=True)
    # 0600: same privacy posture as history.jsonl (audit F6).
    store = Store(str(db_path))
    imported, corrupt = store.migrate_from_jsonl([str(jsonl_path)])
    print(f"imported {imported} run(s), {corrupt} corrupt line(s) skipped")
    try:
        import os
        os.chmod(db_path, 0o600)
    except OSError as e:
        print(f"warning: could not chmod db: {e}", file=sys.stderr)

    total = len(store.list_runs())
    print(f"db now holds {total} run(s): {db_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
