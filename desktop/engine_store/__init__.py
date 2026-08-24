"""engine_store — SQLite persistence layer for NetMax Desktop (contract B1).

Two surfaces over the same tables:

Module functions (B1-01 contract):

    init_db(path) -> sqlite3.Connection
    insert_run(conn, record, *, commit=True) -> int
    load_runs(conn, limit=100) -> list[dict]
    migrate_from_jsonl(conn, jsonl_path) -> int

Class facade (seam with the B1-02 suite):

    Store(path) with .insert_run / .add_sample / .set_verdict /
    .set_wifi_context / .load_run / .list_runs / .load_all /
    .get_verdict / .get_wifi_context / .migrate_from_jsonl([paths]) /
    .clear

See store.py module docstring for the schema, accepted record shapes, and
extraction rules.
"""
from __future__ import annotations

from .store import (
    Store,
    init_db,
    insert_run,
    load_runs,
    migrate_from_jsonl,
)

__all__ = ["Store", "init_db", "insert_run", "load_runs", "migrate_from_jsonl"]
