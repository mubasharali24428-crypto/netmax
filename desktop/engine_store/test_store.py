#!/usr/bin/env python3
"""Offline pytest suite for desktop/engine_store/store.py (contracts B1/D1, BRAVO-B1-02).

Two layers are pinned:

* the ``Store`` path-based adapter (coordinator-mandated API:
  insert_run / add_sample / load_run / list_runs) — round-trip insert/load;
* the persistence guarantees from the brief — migration idempotency (run
  twice → same count), corrupt-JSONL line tolerance, WAL pragma set,
  index existence.

Every database lives under tmp_path — no real user data, no network, no
subprocess, fully offline. Until sibling lane B1-01 lands its Store adapter,
the whole module skips honestly instead of failing.

Run: python -m pytest desktop/engine_store/test_store.py -q
"""
from __future__ import annotations

import json
import sqlite3
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
STORE_DIR = REPO_ROOT / "desktop" / "engine_store"
if str(STORE_DIR) not in sys.path:
    sys.path.insert(0, str(STORE_DIR))

try:
    import store as st
    HAVE_STORE = True
except ImportError:  # store.py hasn't landed yet
    st = None
    HAVE_STORE = False

HAVE_ADAPTER = bool(HAVE_STORE and hasattr(st, ("Store")))

pytestmark = [
    pytest.mark.skipif(not HAVE_STORE, reason="desktop/engine_store/store.py (B1-01) has not landed"),
    pytest.mark.skipif(not HAVE_ADAPTER, reason="B1-01 Store(path) adapter not landed yet"),
]

# ── contract constants ───────────────────────────────────────────────────────

TABLES = {"runs", "samples", "verdicts", "wifi_context"}
INDEXES = {"idx_runs_ts", "idx_samples_run_id", "idx_verdicts_run_id"}

TS_A = "2026-08-20T09:00:00"
TS_B = "2026-08-21T09:00:00"
TS_C = "2026-08-22T09:00:00"


# ── helpers (the ONLY adaptation surface — see coordinator note) ─────────────


def _open(tmp_path, name="db.sqlite3"):
    """Open a Store the way B1-01 named it; adapt HERE, not across the suite."""
    cls = getattr(st, "Store", None) or getattr(st, "EngineStore", None)
    if cls is None:  # belt-and-braces; module-level skip usually fires first
        pytest.skip("B1-01 Store(path) adapter not landed yet")
    path = tmp_path / name
    return cls(str(path)), path


def _conn_of(store_obj):
    """Best-effort discovery of the adapter's live sqlite3.Connection."""
    for attr in ("_conn", "_db", "conn", "_connection"):
        c = getattr(store_obj, attr, None)
        if isinstance(c, sqlite3.Connection):
            return c
    return None


def _needs_conn(store_obj):
    c = _conn_of(store_obj)
    if c is None:
        pytest.skip("adapter does not expose its connection; pragma checked via file header instead")
    return c


def _imported(res):
    """migrate_from_jsonl may return an int or an (imported, skipped) pair."""
    return res[0] if isinstance(res, tuple) else res


def _skipped(res):
    return res[1] if isinstance(res, tuple) and len(res) > 1 else None


def _call_migrate(store_obj, paths):
    """Run migration through the adapter if it offers one, else module fns."""
    fn = getattr(store_obj, "migrate_from_jsonl", None)
    if callable(fn):
        return fn([Path(p) for p in paths])
    c = _conn_of(store_obj)
    if c is None:
        pytest.skip("no migration seam on Store adapter yet")
    total = 0
    for p in paths:
        total += st.migrate_from_jsonl(c, Path(p))
    return total


def _rows(db_path, sql, args=()):
    """Independent read-only view onto the database file."""
    c = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        return c.execute(sql, args).fetchall()
    finally:
        c.close()


def _table_names(db_path):
    return {
        r[0] for r in _rows(db_path, "SELECT name FROM sqlite_master WHERE type='table'")
        if not r[0].startswith("sqlite_")
    }


def _index_names(db_path):
    # sql IS NOT NULL filters auto-indexes created by UNIQUE constraints
    return {
        r[0]
        for r in _rows(
            db_path,
            "SELECT name FROM sqlite_master WHERE type='index' AND sql IS NOT NULL",
        )
    }


def _sample_pairs(samples, kinds_hint=()):
    """Normalize load_run()['samples'] entries to {(kind, value)} pairs.

    Dict entries use kind/metric + value; sequence rows are scanned for the
    inserted kind string followed by its numeric value.
    """
    hints = set(kinds_hint)
    pairs = set()
    for entry in samples:
        if isinstance(entry, dict):
            kind = entry.get("kind", entry.get("metric"))
            pairs.add((str(kind), float(entry["value"])))
        else:
            seq = list(entry)
            for i, item in enumerate(seq):
                if isinstance(item, str) and (not hints or item in hints):
                    for num in seq[i + 1:]:
                        if isinstance(num, (int, float)) and not isinstance(num, bool):
                            pairs.add((item, float(num)))
                            break
                    break
    return pairs


LEGACY_THREE = "\n".join([
    json.dumps({"timestamp": TS_A, "mode": "baseline",
                "results": {"download_mbps": 300.25}}),
    json.dumps({"timestamp": TS_B, "mode": "turbo",
                "results": {"download_mbps": 480.0, "grade": "A-"}}),
    json.dumps({"timestamp": TS_C, "mode": "bloat",
                "results": {"download_mbps": 290.5, "summary": "under load"}}),
]) + "\n"


def _write_jsonl(tmp_path, lines, name="history.jsonl"):
    p = tmp_path / name
    p.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return p


# ── round-trip insert / load ────────────────────────────────────────────────


class TestRoundTrip:
    def test_insert_then_load_preserves_core_fields(self, tmp_path):
        s, _ = _open(tmp_path)
        run_id = s.insert_run(started_at=TS_A, mode="turbo",
                              params={"streams": 8, "seconds": 10})
        assert isinstance(run_id, int)
        loaded = s.load_run(run_id)
        assert loaded["mode"] == "turbo"
        assert loaded["started_at"].replace("Z", "") == TS_A
        assert loaded["params"] == {"streams": 8, "seconds": 10}

    def test_added_samples_round_trip_with_kind_and_value(self, tmp_path):
        s, _ = _open(tmp_path)
        rid = s.insert_run(started_at=TS_B, mode="full", params={"streams": 4})
        s.add_sample(rid, seq=0, t_offset_ms=0, kind="down", value=940.5,
                     unit="mbps")
        s.add_sample(rid, seq=1, t_offset_ms=5000, kind="up", value=42.0,
                     unit="mbps")
        pairs = _sample_pairs(s.load_run(rid)["samples"], kinds_hint=("down", "up"))
        assert pairs >= {("down", 940.5), ("up", 42.0)}

    def test_sample_values_are_numeric(self, tmp_path):
        s, _ = _open(tmp_path)
        rid = s.insert_run(started_at=TS_A, mode="baseline", params={})
        s.add_sample(rid, seq=0, t_offset_ms=250, kind="ping", value=12.25,
                     unit="ms")
        for _, value in _sample_pairs(s.load_run(rid)["samples"], ("ping",)):
            assert isinstance(value, float)

    def test_params_accept_nested_mapping(self, tmp_path):
        s, _ = _open(tmp_path)
        rid = s.insert_run(started_at=TS_A, mode="dns",
                           params={"resolvers": ["1.1.1.1", "8.8.8.8"],
                                   "count": 25})
        assert s.load_run(rid)["params"]["count"] == 25

    def test_each_run_keeps_its_own_samples(self, tmp_path):
        s, _ = _open(tmp_path)
        r1 = s.insert_run(started_at=TS_A, mode="one", params={})
        r2 = s.insert_run(started_at=TS_B, mode="two", params={})
        s.add_sample(r1, seq=0, t_offset_ms=0, kind="down", value=111.0,
                     unit="mbps")
        s.add_sample(r2, seq=0, t_offset_ms=0, kind="down", value=222.0,
                     unit="mbps")
        mine = _sample_pairs(s.load_run(r1)["samples"], ("down",))
        other = _sample_pairs(s.load_run(r2)["samples"], ("down",))
        assert mine == {("down", 111.0)}
        assert other == {("down", 222.0)}

    def test_ids_increase_monotonically(self, tmp_path):
        s, _ = _open(tmp_path)
        id1 = s.insert_run(started_at=TS_A, mode="a", params={})
        id2 = s.insert_run(started_at=TS_B, mode="b", params={})
        assert id2 > id1

    def test_inserted_runs_appear_in_list_runs(self, tmp_path):
        s, _ = _open(tmp_path)
        s.insert_run(started_at=TS_A, mode="alpha", params={})
        s.insert_run(started_at=TS_B, mode="beta", params={})
        s.insert_run(started_at=TS_C, mode="gamma", params={})
        listed = s.list_runs()
        assert len(listed) == 3
        assert {row.get("mode") for row in listed} == {"alpha", "beta", "gamma"}

    def test_blank_or_missing_mode_is_rejected_without_a_partial_write(self, tmp_path):
        s, db_path = _open(tmp_path)
        with pytest.raises(ValueError):
            s.insert_run(started_at=TS_A, mode="", params={})
        with pytest.raises(ValueError):
            s.insert_run(started_at=TS_A, mode="   ", params={})
        n = _rows(db_path, "SELECT COUNT(*) FROM runs")[0][0]
        assert n == 0, "rejected records must leave no partial rows"

    def test_data_survives_close_and_reopen(self, tmp_path):
        s, _db_path = _open(tmp_path)
        # numeric params leaf "k" also lands as a kind-less sample row
        # (B1-01 contract: numeric leaves depth<=3 -> samples)
        rid = s.insert_run(started_at=TS_A, mode="durable", params={"k": 1})
        s.add_sample(rid, seq=0, t_offset_ms=0, kind="down", value=7.5,
                     unit="mbps")
        del s
        s2, _ = _open(tmp_path, name="db.sqlite3")  # same file, new handle
        loaded = s2.load_run(rid)
        assert loaded["mode"] == "durable"
        assert loaded["params"] == {"k": 1}
        assert _sample_pairs(loaded["samples"], ("down",)) == {
            ("down", 7.5), ("k", 1.0),
        }


# ── migration idempotency (run twice → same count) ───────────────────────────


class TestMigrationIdempotency:
    def test_migrate_twice_leaves_same_row_count(self, tmp_path):
        legacy = _write_jsonl(tmp_path, LEGACY_THREE.splitlines())
        s, db_path = _open(tmp_path, "mig.sqlite3")

        first = _call_migrate(s, [legacy])
        second = _call_migrate(s, [legacy])

        assert _imported(first) == 3
        assert _imported(second) == 0, "(ts, mode) key must dedupe on re-run"
        n = _rows(db_path, "SELECT COUNT(*) FROM runs")[0][0]
        assert n == 3, f"duplicate rows after re-migrate: {n}"
        modes = {r[0] for r in _rows(db_path, "SELECT DISTINCT mode FROM runs")}
        assert modes == {"baseline", "turbo", "bloat"}
        skipped = _skipped(second)
        if skipped is not None:
            assert skipped >= 3

    def test_grown_file_reimports_only_new_lines(self, tmp_path):
        legacy = _write_jsonl(tmp_path, LEGACY_THREE.splitlines())
        s, db_path = _open(tmp_path, "grow.sqlite3")
        assert _imported(_call_migrate(s, [legacy])) == 3
        with open(legacy, "a", encoding="utf-8") as fh:
            fh.write(json.dumps({"timestamp": "2026-08-23T09:00:00",
                                 "mode": "boost",
                                 "results": {"gain_pct": 18.0}}) + "\n")
        assert _imported(_call_migrate(s, [legacy])) == 1
        assert _rows(db_path, "SELECT COUNT(*) FROM runs")[0][0] == 4

    def test_timestamp_spellings_are_distinct_identities_stored_verbatim(self, tmp_path):
        """B1-01 final contract: _coerce_ts preserves caller spelling so a
        stored ts round-trips byte-exact; therefore the (ts, mode) idempotency
        key matches only across IDENTICAL spellings ('T' vs ' ' differ), while
        re-importing the very same line dedupes (covered by test above)."""
        first = _write_jsonl(tmp_path, [
            json.dumps({"timestamp": "2026-08-20T09:00:00", "mode": "turbo",
                        "results": {"download_mbps": 1.0}}),
        ], name="h1.jsonl")
        second = _write_jsonl(tmp_path, [
            json.dumps({"timestamp": "2026-08-20 09:00:00", "mode": "turbo",
                        "results": {"download_mbps": 1.0}}),
        ], name="h2.jsonl")
        s, db_path = _open(tmp_path, "spelling.sqlite3")
        assert _imported(_call_migrate(s, [first])) == 1
        assert _imported(_call_migrate(s, [second])) == 1
        stored = [r[0] for r in _rows(db_path, "SELECT ts FROM runs ORDER BY id")]
        assert stored == ["2026-08-20T09:00:00", "2026-08-20 09:00:00"]

    def test_epoch_timestamps_normalize_to_iso_and_dedupe(self, tmp_path):
        lines = [json.dumps({"timestamp": 1756006800, "mode": "w",
                             "results": {"download_mbps": 5.0}})] * 2
        legacy = _write_jsonl(tmp_path, lines, name="epoch.jsonl")
        s, db_path = _open(tmp_path, "epoch.sqlite3")
        assert _imported(_call_migrate(s, [legacy])) == 1
        (ts,) = _rows(db_path, "SELECT ts FROM runs")[0]
        assert "T" in ts  # canonical ISO-8601, not a bare epoch number

    def test_missing_legacy_file_raises_or_is_reported_as_noop(self, tmp_path):
        s, _ = _open(tmp_path)
        try:
            res = _call_migrate(s, [tmp_path / "nope.jsonl"])
        except FileNotFoundError:
            return  # loud failure is fine
        assert _imported(res) == 0  # silent success must at least import nothing


# ── corrupt JSONL line tolerance ─────────────────────────────────────────────


class TestCorruptJsonlTolerance:
    def test_torn_blank_and_non_dict_lines_skipped_good_rows_kept(self, tmp_path):
        lines = [
            json.dumps({"timestamp": TS_A, "mode": "turbo",
                        "results": {"download_mbps": 100.0}}),
            "{not valid json!!",                    # torn mid-write
            "",                                     # blank line
            "[1, 2, 3]",                            # valid JSON, not an object
            json.dumps({"timestamp": TS_B, "mode": "eco",
                        "results": {"download_mbps": 55.0}}),
        ]
        legacy = _write_jsonl(tmp_path, lines, name="mixed.jsonl")
        s, db_path = _open(tmp_path, "corrupt.sqlite3")
        imported = _imported(_call_migrate(s, [legacy]))
        assert imported == 2, "good rows must survive corrupt neighbours"
        assert _rows(db_path, "SELECT COUNT(*) FROM runs")[0][0] == 2
        modes = {r[0] for r in _rows(db_path, "SELECT DISTINCT mode FROM runs")}
        assert modes == {"turbo", "eco"}

    def test_records_without_stable_identity_are_skipped_not_fatal(self, tmp_path):
        """No usable ts or no usable mode ⇒ cannot dedupe ⇒ skipped."""
        lines = [
            json.dumps({"mode": "orphan", "results": {}}),      # no timestamp
            json.dumps({"timestamp": TS_A, "results": {}}),     # no mode
            json.dumps({"timestamp": "garbage", "mode": "x"}),  # unusable ts
            json.dumps({"timestamp": TS_B, "mode": "", "data": {}}),
            json.dumps({"timestamp": TS_C, "mode": "good",
                        "results": {"download_mbps": 1.0}}),
        ]
        legacy = _write_jsonl(tmp_path, lines, name="identity.jsonl")
        s, db_path = _open(tmp_path, "identity.sqlite3")
        assert _imported(_call_migrate(s, [legacy])) == 1
        assert _rows(db_path, "SELECT COUNT(*) FROM runs")[0][0] == 1

    def test_truncated_tail_does_not_lose_preceding_good_rows(self, tmp_path):
        """Crash mid-write leaves a torn LAST line; earlier rows survive."""
        good = "".join(
            json.dumps({"timestamp": ts, "mode": f"m{i}", "results": {}}) + "\n"
            for i, ts in enumerate((TS_A, TS_B))
        )
        legacy = tmp_path / "torn_tail.jsonl"
        legacy.write_text(good + '{"timestamp": "2026-08-23T0', encoding="utf-8")
        s, db_path = _open(tmp_path, "tail.sqlite3")
        assert _imported(_call_migrate(s, [legacy])) == 2
        assert _rows(db_path, "SELECT COUNT(*) FROM runs")[0][0] == 2


# ── WAL pragma ───────────────────────────────────────────────────────────────


class TestWalPragma:
    def test_journal_mode_is_wal_on_the_store_connection(self, tmp_path):
        s, _ = _open(tmp_path)
        c = _needs_conn(s)
        try:
            mode = c.execute("PRAGMA journal_mode").fetchone()[0]
            assert str(mode).lower() == "wal"
        finally:
            pass  # the adapter owns this connection; never close it here

    def test_wal_pragma_persisted_in_file_header(self, tmp_path):
        """WAL is durable: header write/read version bytes must be (2, 2)."""
        s, db_path = _open(tmp_path)
        s.insert_run(started_at=TS_A, mode="walprobe", params={})
        header = db_path.read_bytes()[:20]
        assert len(header) == 20
        assert (header[18], header[19]) == (2, 2), (
            f"WAL not enabled: header versions={(header[18], header[19])} "
            "(journal modes: legacy/delete=1, wal=2)"
        )

    def test_foreign_keys_enforced_on_store_connection(self, tmp_path):
        s, _ = _open(tmp_path)
        c = _needs_conn(s)
        assert c.execute("PRAGMA foreign_keys").fetchone()[0] == 1

    def test_busy_timeout_configured(self, tmp_path):
        s, _ = _open(tmp_path)
        c = _needs_conn(s)
        assert c.execute("PRAGMA busy_timeout").fetchone()[0] > 0


# ── schema shape / index existence ───────────────────────────────────────────


class TestSchemaAndIndexes:
    def test_contract_tables_exist(self, tmp_path):
        _, db_path = _open(tmp_path)
        assert TABLES <= _table_names(db_path)

    def test_contract_indexes_exist(self, tmp_path):
        _, db_path = _open(tmp_path)
        missing = INDEXES - _index_names(db_path)
        assert not missing, f"missing indexes: {sorted(missing)}"

    def test_index_definitions_cover_their_key_columns(self, tmp_path):
        _, db_path = _open(tmp_path)
        runs_ix = {r[2] for r in _rows(db_path, "PRAGMA index_info(idx_runs_ts)")}
        samples_ix = {r[2] for r in _rows(db_path, "PRAGMA index_info(idx_samples_run_id)")}
        assert "ts" in runs_ix, f"idx_runs_ts does not cover ts: {runs_ix}"
        assert "run_id" in samples_ix, f"idx_samples_run_id misses run_id: {samples_ix}"

    def test_runs_table_has_contract_columns(self, tmp_path):
        _, db_path = _open(tmp_path)
        cols = {r[1] for r in _rows(db_path, "PRAGMA table_info(runs)")}
        assert {"id", "ts", "mode", "params_json"} <= cols

    def test_schema_creation_is_idempotent_on_reopen(self, tmp_path):
        _, db_path = _open(tmp_path)
        _s2, _ = _open(tmp_path, name="db.sqlite3")  # second init on same file
        assert TABLES <= _table_names(db_path)


# ── referential integrity ────────────────────────────────────────────────────


class TestForeignKeyCascade:
    def test_deleting_a_run_removes_its_children(self, tmp_path):
        s, _ = _open(tmp_path)
        c = _needs_conn(s)
        rid = s.insert_run(started_at=TS_A, mode="full", params={})
        s.add_sample(rid, seq=0, t_offset_ms=0, kind="down", value=1.0,
                     unit="mbps")
        c.execute("DELETE FROM runs WHERE id=?", (rid,))
        c.commit()
        for table in ("samples", "verdicts", "wifi_context"):
            n = c.execute(
                f"SELECT COUNT(*) FROM {table} WHERE run_id=?", (rid,)
            ).fetchone()[0]
            assert n == 0, f"{table} rows survived cascade delete"


# ── pure parsing helpers (unit level; skipped if B1-01 renames them) ─────────

def _requires(name):
    return pytest.mark.skipif(
    not (HAVE_STORE and hasattr(st, name)), reason=f"store.{name} absent"
)


class TestPureHelpers:
    @_requires("_coerce_ts")
    @pytest.mark.parametrize("bad", ["", "   ", "garbage", None, True, [], {}])
    def test_coerce_ts_rejects_junk(self, bad):
        assert st._coerce_ts(bad) is None

    @_requires("_coerce_ts")
    def test_coerce_ts_accepts_iso_strings_and_epoch_numbers(self):
        assert st._coerce_ts(TS_A) == TS_A
        parsed = st._coerce_ts(1756006800)
        assert parsed is not None and "T" in parsed

    @_requires("_as_int")
    def test_as_int_handles_strings_floats_and_bools(self):
        assert st._as_int("-31") == -31
        assert st._as_int(-31.0) == -31
        assert st._as_int(True) is None
        assert st._as_int("-31.5") is None

    @_requires("_extract_wifi")
    def test_extract_wifi_prefers_nested_wifi_container(self):
        payload = {"wifi_context": {"rssi_dbm": -40, "channel": "6"},
                   "rssi_dbm": -99}
        assert st._extract_wifi(payload) == (-40, None, 6)

    @_requires("_collect_samples")
    def test_collect_samples_drops_engine_control_keys(self):
        out = st._collect_samples(
            {"streams": 8, "seconds": 9, "download_mbps": 12.0}
        )
        assert out == {"download_mbps": 12.0}
