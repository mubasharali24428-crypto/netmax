#!/usr/bin/env python3
"""SQLite persistence layer for NetMax Desktop (contract B1, BRAVO-B1-01).

Two surfaces, one store:

1. MODULE FUNCTIONS (this lane's contract):
       init_db(path) -> sqlite3.Connection
       insert_run(conn, record, commit=True) -> int
       load_runs(conn, limit=100) -> list[dict]
       migrate_from_jsonl(conn, jsonl_path) -> int
   `record` accepts history.jsonl entries {"timestamp", "mode", "results"},
   bridge envelopes {"success", "mode", "data", "error"}, or flat
   {"ts", "mode", "data"} shapes. Numeric leaves become samples
   (dotted-path metric names), grade*/verdict* string leaves become verdict
   rows (kind='grade'/'verdict'), bridge raw-text stdout becomes
   verdicts(kind='raw'), rssi/noise/channel become one wifi_context row.
   The FULL original record is preserved verbatim in runs.params_json.
   migrate_from_jsonl is idempotent: (ts, mode) pairs already in runs are
   skipped, so re-running against a grown file imports only new lines.

2. THE Store FACADE (seam agreed with lane B1-02's suite):
       Store(path).insert_run(*, started_at, mode, params) -> int
       .add_sample(run_id, seq, t_offset_ms, kind, value, unit)
       .set_verdict(run_id=…, grade, gain_pct, dropouts, summary)
       .set_wifi_context(run_id=…, ssid, bssid, rssi_dbm, …)
       .load_run(id) / .list_runs() / .load_all() / .clear()
       .migrate_from_jsonl([paths]) -> (imported, corrupt)
   Same tables underneath — the facade writes explicit rows, the module
   functions extract from record payloads.

Schema is the union of mission B1-01 (ts / metric+value / kind+value /
rssi+noise+channel) and architecture-doc §3 (05-app-architecture.md:
started_at / seq+t_offset_ms+kind+unit / grade+gain_pct+dropouts+summary /
ssid+bssid+band+link_rate_mbps); either lane's readers work unmodified.
WAL journal mode, FK cascade deletes, stdlib sqlite3 only, indexes on ts and
every child's run_id. Every statement is a static string with bound
parameters — no caller data ever reaches SQL text.
"""
from __future__ import annotations

import json
import re
import sqlite3
from collections.abc import Callable, Mapping
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# ── schema ───────────────────────────────────────────────────────────────────

SCHEMA = """
CREATE TABLE IF NOT EXISTS runs (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    ts             TEXT NOT NULL,
    started_at     TEXT NOT NULL DEFAULT '',
    finished_at    TEXT,
    mode           TEXT NOT NULL,
    engine_version TEXT NOT NULL DEFAULT '',
    "trigger"      TEXT NOT NULL DEFAULT 'manual',
    params_json    TEXT NOT NULL DEFAULT '{}'
);
-- idx_runs_started is the architecture-doc §3 name for the ts index
-- (mission B1-01 requires an index on ts; started_at mirrors ts 1:1).
CREATE INDEX IF NOT EXISTS idx_runs_started ON runs(started_at DESC);
CREATE INDEX IF NOT EXISTS idx_runs_ts ON runs(ts);

CREATE TABLE IF NOT EXISTS samples (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id      INTEGER NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
    seq         INTEGER,
    t_offset_ms INTEGER,
    kind        TEXT,
    metric      TEXT NOT NULL,
    value       REAL NOT NULL,
    unit        TEXT
);
CREATE INDEX IF NOT EXISTS idx_samples_run_id ON samples(run_id);
CREATE INDEX IF NOT EXISTS idx_samples_run ON samples(run_id, seq);

CREATE TABLE IF NOT EXISTS verdicts (
    id       INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id   INTEGER NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
    kind     TEXT NOT NULL,
    value    TEXT NOT NULL,
    grade    TEXT,
    gain_pct REAL,
    dropouts INTEGER,
    summary  TEXT
);
CREATE INDEX IF NOT EXISTS idx_verdicts_run_id ON verdicts(run_id);

CREATE TABLE IF NOT EXISTS wifi_context (
    run_id         INTEGER PRIMARY KEY REFERENCES runs(id) ON DELETE CASCADE,
    ssid           TEXT,
    bssid          TEXT,
    rssi_dbm       INTEGER,
    noise_dbm      INTEGER,
    channel        INTEGER,
    band           TEXT,
    link_rate_mbps INTEGER
);
"""

_SQL_INSERT_RUN = (
    "INSERT INTO runs (ts, started_at, finished_at, mode, engine_version, "
    '"trigger", params_json) VALUES (?, ?, ?, ?, ?, ?, ?)'
)
_SQL_ADD_SAMPLE = (
    "INSERT INTO samples (run_id, seq, t_offset_ms, kind, metric, value, unit) "
    "VALUES (?, ?, ?, ?, ?, ?, ?)"
)
_SQL_INSERT_SAMPLE = _SQL_ADD_SAMPLE
_SQL_INSERT_VERDICT = (
    "INSERT INTO verdicts (run_id, kind, value, grade, gain_pct, dropouts, "
    "summary) VALUES (?, ?, ?, ?, ?, ?, ?)"
)
_SQL_SET_VERDICT = _SQL_INSERT_VERDICT
_SQL_INSERT_WIFI = (
    "INSERT INTO wifi_context (run_id, rssi_dbm, noise_dbm, channel) "
    "VALUES (?, ?, ?, ?)"
)
_SQL_SET_WIFI = (
    "INSERT OR REPLACE INTO wifi_context (run_id, ssid, bssid, rssi_dbm, "
    "noise_dbm, channel, band, link_rate_mbps) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
)

# ── opening a database ───────────────────────────────────────────────────────

# Bump when SCHEMA changes in a non-idempotent way; init_db applies CREATE
# IF NOT EXISTS then stamps user_version so older files upgrade in place.
SCHEMA_VERSION = 1


def init_db(path: str | Path) -> sqlite3.Connection:
    """Open (creating if needed) the store at `path`; apply schema; WAL on.

    Parent directories are created automatically. The returned connection has
    Row factory, foreign keys ON, and a 5s busy timeout. WAL persists in the
    database file once set here. `PRAGMA user_version` is stamped with
    SCHEMA_VERSION after a successful apply (migration ladder for future
    ALTERs: read user_version, run stepwise migrations, then stamp).
    """
    target = Path(path)
    if str(target.parent) not in ("", "."):
        target.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(target))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA busy_timeout=5000")
    conn.executescript(SCHEMA)
    current = conn.execute("PRAGMA user_version").fetchone()[0]
    if current < SCHEMA_VERSION:
        # ladder point: when SCHEMA_VERSION grows, apply ALTERs here keyed on
        # `current` before stamping. CREATE IF NOT EXISTS already covers v1.
        conn.execute(f"PRAGMA user_version={SCHEMA_VERSION}")
    conn.commit()
    return conn


# ── record parsing (pure helpers, unit-testable offline) ─────────────────────

_META_KEYS = frozenset(
    {
        "ts", "timestamp", "time", "mode", "run_id", "id", "success", "error",
        # run configuration / metadata — never measurement payloads
        "params", "finished_at", "engine_version", "trigger",
    }
)
_SKIP_SAMPLE_KEYS = frozenset({"seconds", "streams", "count", "interval", "dropped"})
_GRADE_KEYS = frozenset({"grade", "bloat_grade", "bufferbloat_grade"})
_VERDICT_KEYS = frozenset({"verdict", "verdict_text", "summary", "advice"})
_WIFI_CONTAINERS = ("wifi_context", "wifi_info", "wifi", "network")
_WIFI_SAMPLE_KEYS = frozenset(
    {"rssi_dbm", "rssi", "signal_dbm", "noise_dbm", "noise", "channel", "ch"}
)
_MAX_DEPTH = 3


def _coerce_ts(value: Any) -> str | None:
    """Validated ISO-8601 string from an ISO string or epoch number; else None.

    Strings are returned with their original spelling (only whitespace
    stripped), so a stored ts round-trips exactly as the caller wrote it.
    Epoch numbers become UTC ISO-8601.
    """
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        try:
            return datetime.fromtimestamp(value, tz=timezone.utc).isoformat()
        except (OverflowError, OSError, ValueError):
            return None
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return None
        if re.fullmatch(r"-?\d+(\.\d+)?", text):
            return _coerce_ts(float(text))
        probe = text[:-1] + "+00:00" if text.endswith(("Z", "z")) else text
        try:  # validate only — 3.10 fromisoformat rejects the 'Z' suffix
            datetime.fromisoformat(probe)
        except ValueError:
            return None
        return text
    return None


def _ts_key(value: Any) -> str | None:
    """The (ts, mode) idempotency key component: the ts string as stored.

    runs.ts preserves the caller's spelling verbatim (_coerce_ts), so
    identities match only across IDENTICAL spellings — 'T' vs ' ' differ.
    Re-importing the very same line therefore dedupes, while a re-spelled
    instant is treated as a distinct run. Epoch numbers canonicalize to UTC
    ISO-8601 so numeric sources still dedupe stably.
    """
    return _coerce_ts(value)


def _as_int(value: Any) -> int | None:
    """Best-effort int (-31, -31.0, "-31" all work); None otherwise."""
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value) if value.is_integer() else None
    if isinstance(value, str):
        match = re.fullmatch(r"\s*(-?\d+)\s*", value)
        if match:
            return int(match.group(1))
    return None


def _payload(record: Mapping[str, Any]) -> Any:
    """The measurement payload inside a record.

    Order: data, then results, then params (facade records carry
    configuration there; its non-config numeric leaves still deserve sample
    rows), else the record minus meta keys. Inside any payload,
    _SKIP_SAMPLE_KEYS keeps pure run knobs (seconds/streams/...) out of
    samples.
    """
    for key in ("data", "results", "params"):
        value = record.get(key)
        if isinstance(value, (Mapping, list)):
            return value
    return {k: v for k, v in record.items() if k not in _META_KEYS}


def _numeric(value: Any) -> float | None:
    """Float for numbers (bools excluded) and numeric strings; else None."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value.strip())
        except ValueError:
            return None
    return None


def _collect_samples(
    node: Any, prefix: str = "", depth: int = 0, out: dict[str, float] | None = None
) -> dict[str, float]:
    """Flatten numeric leaves into {dotted.metric: value}; dns pairs included."""
    out = {} if out is None else out
    if depth > _MAX_DEPTH:
        return out
    if isinstance(node, Mapping):
        for key, value in node.items():
            path = f"{prefix}.{key}" if prefix else str(key)
            if key in _SKIP_SAMPLE_KEYS:
                continue
            number = _numeric(value)
            if number is not None:
                if key in _WIFI_SAMPLE_KEYS and not prefix:
                    continue  # wifi fields live in wifi_context, not samples
                out[path] = number
            elif isinstance(value, (Mapping, list)):
                _collect_samples(value, path, depth + 1, out)
    elif isinstance(node, list):
        # dns-style [[name, ms], ...] pairs -> "dns.<name>" metrics
        if node and all(
            isinstance(item, (list, tuple))
            and len(item) == 2
            and isinstance(item[0], str)
            and _numeric(item[1]) is not None
            for item in node
        ):
            for name, value in node:
                out[f"{prefix}.{name}" if prefix else str(name)] = float(value)
    return out


def _collect_verdicts(record: Mapping[str, Any], payload: Any) -> list[tuple[str, str]]:
    """(kind, value) rows: 'raw', 'grade', 'verdict' — order-stable, deduped."""
    found: list[tuple[str, str]] = []

    raw = record.get("result_raw")
    if isinstance(raw, str) and raw.strip():
        found.append(("raw", raw))

    # Bridge fallback for human-readable engine stdout: payload is exactly
    # {"raw": "<text>"} — keep the text verbatim as the run's raw verdict.
    if isinstance(payload, Mapping) and set(payload) == {"raw"}:
        text = payload["raw"]
        if isinstance(text, str) and text.strip():
            found.append(("raw", text))

    if isinstance(payload, Mapping):
        stack: list[tuple[Mapping[str, Any], int]] = [(payload, 0)]
        while stack:
            node, depth = stack.pop()
            if depth > _MAX_DEPTH:
                continue
            for key, value in node.items():
                if isinstance(value, str) and value.strip():
                    if key in _GRADE_KEYS:
                        found.append(("grade", value))
                    elif key in _VERDICT_KEYS:
                        found.append(("verdict", value))
                elif isinstance(value, Mapping) and depth < _MAX_DEPTH:
                    stack.append((value, depth + 1))

    seen: set[tuple[str, str]] = set()
    unique: list[tuple[str, str]] = []
    for row in found:
        if row not in seen:
            seen.add(row)
            unique.append(row)
    return unique


def _extract_wifi(payload: Any) -> tuple[int | None, int | None, int | None] | None:
    """(rssi_dbm, noise_dbm, channel) from the payload or a wifi_* sub-dict.

    When a wifi_* container holds them, the top-level payload's copies are
    ignored — the structured record wins and its keys stay out of samples.
    """
    nodes: list[Any] = [payload]
    if isinstance(payload, Mapping):
        nested = [
            payload[key]
            for key in _WIFI_CONTAINERS
            if isinstance(payload.get(key), Mapping)
        ]
        if nested:
            return _wifi_from_nodes(nested)
        return _wifi_from_nodes([payload])
    return _wifi_from_nodes(nodes)


def _wifi_from_nodes(
    nodes: list[Any],
) -> tuple[int | None, int | None, int | None] | None:
    for node in nodes:
        if not isinstance(node, Mapping):
            continue
        rssi = next(
            (
                v
                for v in (_as_int(node.get(k)) for k in ("rssi_dbm", "rssi", "signal_dbm"))
                if v is not None
            ),
            None,
        )
        noise = next(
            (
                v
                for v in (_as_int(node.get(k)) for k in ("noise_dbm", "noise"))
                if v is not None
            ),
            None,
        )
        channel = next(
            (
                v
                for v in (_as_int(node.get(k)) for k in ("channel", "ch"))
                if v is not None
            ),
            None,
        )
        if rssi is not None or noise is not None or channel is not None:
            return (rssi, noise, channel)
    return None


# ── writes (module functions) ────────────────────────────────────────────────


def insert_run(
    conn: sqlite3.Connection, record: Mapping[str, Any], *, commit: bool = True
) -> int:
    """Insert one run plus extracted samples/verdicts/wifi; returns the run id.

    Timestamp falls back to insertion time when the record carries none; a
    missing/empty `mode` raises ValueError (nothing is written). Optional
    record keys finished_at / engine_version / trigger land in their own
    columns (trigger defaults to 'manual'). The whole record is preserved
    verbatim as params_json. `commit=False` lets batch callers
    (migrate_from_jsonl) drive one transaction.
    """
    if not isinstance(record, Mapping):
        raise TypeError(f"record must be a mapping, got {type(record).__name__}")
    mode = record.get("mode")
    if not isinstance(mode, str) or not mode.strip():
        raise ValueError("record is missing a usable 'mode'")
    ts = _coerce_ts(record.get("ts", record.get("timestamp")))
    if ts is None:
        ts = datetime.now().isoformat(timespec="seconds")

    finished = record.get("finished_at")
    finished_text = finished.strip() if isinstance(finished, str) and finished.strip() else None
    version = record.get("engine_version")
    version_text = str(version) if version is not None else ""
    trigger = record.get("trigger")
    trigger_text = (
        trigger.strip()
        if isinstance(trigger, str) and trigger.strip()
        else "manual"
    )

    payload = _payload(record)
    samples = _collect_samples(payload)
    verdicts = _collect_verdicts(record, payload)
    wifi = _extract_wifi(payload)

    cur = conn.execute(
        _SQL_INSERT_RUN,
        (ts, ts, finished_text, mode.strip(), version_text, trigger_text,
         json.dumps(dict(record))),
    )
    run_id = cur.lastrowid
    if run_id is None:  # pragma: no cover - INSERT always yields a rowid
        raise sqlite3.IntegrityError("runs insert produced no rowid")
    conn.executemany(
        _SQL_INSERT_SAMPLE,
        [
            (run_id, None, None, None, metric, value, None)
            for metric, value in samples.items()
        ],
    )
    conn.executemany(
        _SQL_INSERT_VERDICT,
        [(run_id, kind, value, None, None, None, None) for kind, value in verdicts],
    )
    if wifi is not None:
        conn.execute(_SQL_INSERT_WIFI, (run_id, *wifi))
    if commit:
        conn.commit()
    return run_id


def migrate_from_jsonl(conn: sqlite3.Connection, jsonl_path: str | Path) -> int:
    """Import history.jsonl lines, skipping already-imported (ts, mode) pairs.

    Idempotent: safe to re-run against a grown file. Malformed lines and
    records without a usable timestamp/mode are skipped. Imported runs are
    tagged trigger='imported'. Commits once; returns the number of newly
    imported runs.
    """
    imported = 0
    seen = _seen_keys(conn)

    path = Path(jsonl_path)
    if not path.is_file():
        raise FileNotFoundError(f"no such file: {path}")

    with open(path, encoding="utf-8") as handle:
        for line in handle:
            stripped = line.strip()
            if not stripped:
                continue
            try:
                record = json.loads(stripped)
            except json.JSONDecodeError:
                continue
            if not isinstance(record, Mapping):
                continue
            if not _identity_ok(record, seen):
                continue
            tagged = dict(record)
            tagged["trigger"] = "imported"
            try:
                insert_run(conn, tagged, commit=False)
            except (TypeError, ValueError, sqlite3.Error):
                continue
            imported += 1
    conn.commit()
    return imported


def _identity_ok(record: Mapping[str, Any], seen: set[tuple[str, str]]) -> bool:
    """True when the record has a fresh (ts, mode) identity worth inserting.

    Timestamps are compared through their canonical form (_ts_key), so the
    same instant spelled differently does not import twice.
    """
    key_ts = _ts_key(record.get("ts", record.get("timestamp")))
    mode = record.get("mode")
    if key_ts is None or not isinstance(mode, str) or not mode.strip():
        return False  # no stable identity -> cannot dedupe; skip
    key = (key_ts, mode.strip())
    if key in seen:
        return False
    seen.add(key)
    return True


def _seen_keys(conn: sqlite3.Connection) -> set[tuple[str, str]]:
    """Canonical (ts, mode) identities of every run already in the table."""
    keys: set[tuple[str, str]] = set()
    for row in conn.execute("SELECT ts, mode FROM runs"):
        key_ts = _ts_key(row["ts"])
        if key_ts is not None:
            keys.add((key_ts, row["mode"]))
    return keys


def _read_jsonl(
    jsonl_path: str | Path, on_record: Callable[[Mapping[str, Any]], bool]
) -> tuple[int, int]:
    """Feed each valid JSON object line to `on_record` (True = accepted).

    Returns (accepted, corrupt) where corrupt counts torn/invalid lines and
    blank lines — the same tolerance on every read path.
    """
    path = Path(jsonl_path)
    if not path.is_file():
        raise FileNotFoundError(f"no such file: {path}")
    accepted = corrupt = 0
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            stripped = line.strip()
            if not stripped:
                corrupt += 1
                continue
            try:
                record = json.loads(stripped)
            except json.JSONDecodeError:
                corrupt += 1
                continue
            if not isinstance(record, Mapping):
                corrupt += 1
                continue
            try:
                if on_record(record):
                    accepted += 1
                else:
                    corrupt += 1
            except (TypeError, ValueError, sqlite3.Error):
                corrupt += 1
    return accepted, corrupt


# ── reads (module functions) ─────────────────────────────────────────────────


def load_runs(conn: sqlite3.Connection, limit: int = 100) -> list[dict[str, Any]]:
    """Newest `limit` runs with their samples/verdicts/wifi attached.

    Children are fetched whole and filtered in Python — desktop-scale tables,
    and it keeps every statement static and parameterized. Shape per run:
    {id, ts, started_at, mode, params, samples: {metric: value},
     verdicts: {kind: [values]}, wifi: {rssi_dbm, noise_dbm, channel}|None}.
    """
    rows = conn.execute(
        "SELECT id, ts, started_at, mode, params_json FROM runs "
        "ORDER BY ts DESC, id DESC LIMIT ?",
        (int(limit),),
    ).fetchall()
    wanted = {row["id"] for row in rows}

    def _children(sql: str) -> dict[int, list[tuple]]:
        grouped: dict[int, list[tuple]] = {}
        for row in conn.execute(sql):
            if row["run_id"] in wanted:
                grouped.setdefault(row["run_id"], []).append(tuple(row)[1:])
        return grouped

    samples_by_run = _children("SELECT run_id, metric, value FROM samples ORDER BY id")
    verdicts_by_run = _children("SELECT run_id, kind, value FROM verdicts ORDER BY id")
    wifi_by_run = {
        row["run_id"]: tuple(row)[1:]
        for row in conn.execute(
            "SELECT run_id, rssi_dbm, noise_dbm, channel FROM wifi_context"
        )
        if row["run_id"] in wanted
    }

    runs: list[dict[str, Any]] = []
    for row in rows:
        run_id = row["id"]
        try:
            params = json.loads(row["params_json"])
        except (json.JSONDecodeError, TypeError):
            params = {}
        samples: dict[str, float] = {}
        for metric, value in samples_by_run.get(run_id, []):
            samples[metric] = value
        verdicts: dict[str, list[str]] = {}
        for kind, value in verdicts_by_run.get(run_id, []):
            verdicts.setdefault(kind, []).append(value)
        wifi = wifi_by_run.get(run_id)
        runs.append(
            {
                "id": run_id,
                "ts": row["ts"],
                "started_at": row["started_at"],
                "mode": row["mode"],
                "params": params,
                "samples": samples,
                "verdicts": verdicts,
                "wifi": (
                    {"rssi_dbm": wifi[0], "noise_dbm": wifi[1], "channel": wifi[2]}
                    if wifi
                    else None
                ),
            }
        )
    return runs


# ── Store facade (seam with lane B1-02's suite) ──────────────────────────────


def _opt_int(value: Any) -> int | None:
    return None if value is None else int(value)


class Store:
    """Class facade over the same tables as the module functions.

    Owns its connection (init_db semantics: WAL, FKs ON, schema applied).
    """

    def __init__(self, path: str | Path) -> None:
        self._conn = init_db(path)

    def __enter__(self) -> Store:
        return self

    def __exit__(self, *_exc: object) -> bool:
        self.close()
        return False

    @property
    def conn(self) -> sqlite3.Connection:
        """The underlying connection (pragma checks, advanced queries)."""
        return self._conn

    def close(self) -> None:
        self._conn.close()

    # ── writes ──

    def insert_run(
        self,
        *,
        started_at: str | None = None,
        mode: str,
        params: Mapping[str, Any] | None = None,
        **extra: Any,
    ) -> int:
        """Insert a run row (+ any extracted rows); returns the new run id.

        `started_at` is stored verbatim (falls back to insertion time);
        finished_at / engine_version / trigger pass through when given.
        """
        if not isinstance(mode, str) or not mode.strip():
            raise ValueError("Store.insert_run requires a non-empty mode")
        record: dict[str, Any] = {
            "ts": started_at,
            "mode": mode,
            "params": dict(params) if params is not None else {},
        }
        for key in ("finished_at", "engine_version", "trigger"):
            if extra.get(key) is not None:
                record[key] = extra[key]
        return insert_run(self._conn, record)

    def add_sample(
        self,
        run_id: int,
        seq: int | None,
        t_offset_ms: int | None,
        kind: str,
        value: float,
        unit: str | None,
    ) -> None:
        """Append one explicit sample row (kind doubles as the metric name)."""
        self._conn.execute(
            _SQL_ADD_SAMPLE,
            (
                int(run_id),
                _opt_int(seq),
                _opt_int(t_offset_ms),
                str(kind),
                str(kind),
                float(value),
                None if unit is None else str(unit),
            ),
        )
        self._conn.commit()

    def set_verdict(
        self,
        *,
        run_id: int,
        grade: str | None = None,
        gain_pct: float | None = None,
        dropouts: int | None = None,
        summary: str | None = None,
    ) -> None:
        """Write the run's structured verdict (kind='final', value=summary)."""
        text = summary if summary is not None else ""
        self._conn.execute(
            _SQL_SET_VERDICT,
            (int(run_id), "final", text, grade, gain_pct, dropouts, summary),
        )
        self._conn.commit()

    def set_wifi_context(
        self,
        *,
        run_id: int,
        ssid: str | None = None,
        bssid: str | None = None,
        rssi_dbm: int | None = None,
        noise_dbm: int | None = None,
        channel: int | str | None = None,
        band: str | None = None,
        link_rate_mbps: int | None = None,
    ) -> None:
        """Upsert the run's WiFi context (channel may arrive as "36")."""
        self._conn.execute(
            _SQL_SET_WIFI,
            (
                int(run_id),
                ssid,
                bssid,
                _opt_int(rssi_dbm),
                _opt_int(noise_dbm),
                _as_int(channel),
                band,
                _opt_int(link_rate_mbps),
            ),
        )
        self._conn.commit()

    def clear(self) -> None:
        """Remove every row (children first, then runs)."""
        self._conn.execute("DELETE FROM samples")
        self._conn.execute("DELETE FROM verdicts")
        self._conn.execute("DELETE FROM wifi_context")
        self._conn.execute("DELETE FROM runs")
        self._conn.commit()

    # ── migration ──

    def migrate_from_jsonl(self, paths: list[str | Path]) -> tuple[int, int]:
        """Import history.jsonl files idempotently; returns (imported, corrupt).

        Skips already-imported (ts, mode) pairs, tolerates torn/blank lines
        (counted in `corrupt`), tags imports trigger='imported', and treats a
        missing file as a no-op.
        """
        seen = _seen_keys(self._conn)
        counts = [0, 0]

        def _accept(record: Mapping[str, Any]) -> bool:
            if not _identity_ok(record, seen):
                return False
            tagged = dict(record)
            tagged["trigger"] = "imported"
            insert_run(self._conn, tagged, commit=False)
            return True

        for path in paths:
            try:
                accepted, corrupt = _read_jsonl(path, _accept)
            except FileNotFoundError:
                continue
            counts[0] += accepted
            counts[1] += corrupt
        self._conn.commit()
        return counts[0], counts[1]

    # ── reads ──

    def load_run(self, run_id: int) -> dict[str, Any]:
        """One run with children: started_at/params dict/samples list/etc."""
        row = self._conn.execute(
            "SELECT id, ts, started_at, mode, params_json FROM runs WHERE id = ?",
            (int(run_id),),
        ).fetchone()
        if row is None:
            raise KeyError(f"no such run: {run_id}")

        try:
            raw_params = json.loads(row["params_json"])
        except (json.JSONDecodeError, TypeError):
            raw_params = {}
        params = raw_params
        if isinstance(raw_params, Mapping) and isinstance(raw_params.get("params"), Mapping):
            params = dict(raw_params["params"])

        samples: list[dict[str, Any]] = []
        for srow in self._conn.execute(
            "SELECT seq, t_offset_ms, kind, metric, value, unit FROM samples "
            "WHERE run_id = ? ORDER BY id",
            (int(run_id),),
        ):
            kind = srow["kind"] if srow["kind"] else srow["metric"]
            samples.append(
                {
                    "seq": srow["seq"],
                    "t_offset_ms": srow["t_offset_ms"],
                    "kind": kind,
                    "metric": srow["metric"],
                    "value": float(srow["value"]),
                    "unit": srow["unit"],
                }
            )

        verdicts: list[dict[str, Any]] = []
        for vrow in self._conn.execute(
            "SELECT kind, value, grade, gain_pct, dropouts, summary FROM verdicts "
            "WHERE run_id = ? ORDER BY id",
            (int(run_id),),
        ):
            verdicts.append(dict(vrow))

        wrow = self._conn.execute(
            "SELECT ssid, bssid, rssi_dbm, noise_dbm, channel, band, "
            "link_rate_mbps FROM wifi_context WHERE run_id = ?",
            (int(run_id),),
        ).fetchone()
        wifi = dict(wrow) if wrow is not None else None

        return {
            "id": row["id"],
            "ts": row["ts"],
            "started_at": row["started_at"],
            "mode": row["mode"],
            "params": params,
            "samples": samples,
            "verdicts": verdicts,
            "wifi": wifi,
        }

    def list_runs(self) -> list[dict[str, Any]]:
        """All runs, newest first: [{id, started_at, mode}]."""
        return [
            {"id": row["id"], "started_at": row["started_at"], "mode": row["mode"]}
            for row in self._conn.execute(
                "SELECT id, started_at, mode FROM runs ORDER BY ts DESC, id DESC"
            )
        ]

    def get_verdict(self, run_id: int) -> dict[str, Any]:
        """The run's structured verdict ({grade, gain_pct, dropouts, summary})."""
        row = self._conn.execute(
            "SELECT grade, gain_pct, dropouts, summary FROM verdicts "
            "WHERE run_id = ? AND (grade IS NOT NULL OR summary IS NOT NULL) "
            "ORDER BY CASE WHEN kind = 'final' THEN 0 ELSE 1 END, id LIMIT 1",
            (int(run_id),),
        ).fetchone()
        return dict(row) if row is not None else {}

    def get_wifi_context(self, run_id: int) -> dict[str, Any]:
        """The run's WiFi context dict, or {} when none was recorded."""
        row = self._conn.execute(
            "SELECT ssid, bssid, rssi_dbm, noise_dbm, channel, band, "
            "link_rate_mbps FROM wifi_context WHERE run_id = ?",
            (int(run_id),),
        ).fetchone()
        return dict(row) if row is not None else {}

    def load_all(self) -> list[dict[str, Any]]:
        """Every run with children attached (newest first)."""
        return load_runs(self._conn, limit=1_000_000)
