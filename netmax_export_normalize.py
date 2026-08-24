"""Normalize engine measurement records into canonical export rows (BRAVO-B1-05).

Bridge between what the engines persist and what report exports consume:

* CLI/engine runs persist ``results/<ts>/results.json`` — a flat dict of
  scalars plus a ``dns`` list (see ``measure.py``; rendered by
  ``netmax_export.py``).
* The desktop app appends one JSON line per run to ``history.jsonl``
  (contract P2): ``{"ts", "mode", "params", "result_raw"}`` where
  ``result_raw`` is the engine payload serialized as a STRING (see
  ``desktop/SwiftNetMax/Sources/netmax-desktop/HistoryStore.swift``;
  rendered by ``ReportExport.swift``).

``to_records()`` accepts either shape (or an iterable mixing both, including
raw JSONL lines) and returns canonical row dicts carrying every column in
``COLUMNS``; ``to_csv()`` renders them under a STABLE header — fields a
source lacks become empty cells, never shifted positions.

Conventions shared with the existing exporters:

* ``timestamp`` leads every row; DNS measurements fan out to one row per
  resolver with the scalar cells repeated (cf. ``netmax_export._write_csv``
  and ``ReportExporter.csvText``).
* ``dns`` tolerates the shapes the engines emit: ``[["1.1.1.1", 12.3], …]``,
  ``[{"resolver"/"name": …, "ms"/"dns_ms": …}, …]``, or a plain
  ``{"resolver": ms}`` mapping (rows sorted by resolver) — same tolerance
  as ``ReportExporter.dnsRows``.
* Run parameters (``params``) win over scalars inside ``result_raw`` — they
  are the authoritative inputs (cf. ``ReportExport.swift`` scalarFields).
* ``gain_pct`` is taken from the record when present, otherwise computed as
  ``(turbo8_mbps / baseline_mbps - 1) * 100`` rounded to 1 decimal; left
  empty when the inputs to compute it are missing.
* Booleans render lowercase (``true``/``false``), matching ReportExporter.

Pure stdlib; importing this module pulls in neither ``netmax`` nor AppKit.
"""

from __future__ import annotations

import csv
import io
import json

__all__ = ["COLUMNS", "to_csv", "to_records"]

#: Canonical export columns, in output order (BRAVO-B1-05 schema).
COLUMNS = [
    "timestamp",
    "mode",
    "seconds",
    "streams",
    "baseline_mbps",
    "dropped",
    "gain_pct",
    "note",
    "turbo8_mbps",
    "dns_resolver",
    "dns_ms",
]

# Scalar columns resolved by lookup (everything except the per-resolver pair);
# timestamp/gain_pct get dedicated handling below.
_SCALAR_COLUMNS = [
    c for c in COLUMNS if c not in ("timestamp", "dns_resolver", "dns_ms")
]

_TS_KEYS = ("timestamp", "ts")
_PAYLOAD_KEYS = ("result_raw", "result", "results")
_DNS_NAME_KEYS = ("resolver", "name")
_DNS_MS_KEYS = ("ms", "dns_ms")


def to_records(records, context=None):
    """Map engine records to canonical row dicts (one per DNS resolver).

    Accepts an iterable of dicts shaped like an engine ``results.json``
    blob, a desktop ``history.jsonl`` line (parsed or as a raw JSON string),
    or a merge of the two. Each input yields one canonical dict per DNS
    resolver (scalars repeated); inputs without DNS yield a single row with
    empty ``dns_resolver``/``dns_ms`` cells.

    Field resolution per column, first match wins: top-level record field,
    then ``params``, then the embedded result payload, then ``context``
    (optional dict of caller-supplied defaults, e.g. a batch timestamp).

    Raises ValueError if an item is not a JSON object (or a JSON string
    containing one).
    """
    rows: list[dict] = []
    for index, rec in enumerate(records):
        rows.extend(_normalize_record(_as_object(index, rec), context))
    return rows


def to_csv(rows) -> str:
    """Render canonical rows as CSV text with the stable ``COLUMNS`` header.

    Rows may omit columns (or carry extras) — every emitted line still has
    exactly one cell per column of ``COLUMNS``; missing values become empty
    cells. LF line endings, trailing newline (matches ReportExporter).
    """
    buf = io.StringIO()
    writer = csv.writer(buf, lineterminator="\n")
    writer.writerow(COLUMNS)
    for row in rows:
        writer.writerow([_cell(row.get(col, "")) for col in COLUMNS])
    return buf.getvalue()


# ── internals ────────────────────────────────────────────────────────────────


def _as_object(index, rec):
    """Coerce one input item to a dict; JSONL lines are parsed transparently."""
    if isinstance(rec, str):
        try:
            rec = json.loads(rec)
        except ValueError as exc:
            raise ValueError(f"record {index} is not valid JSON: {exc}") from exc
    if not isinstance(rec, dict):
        raise ValueError(
            f"record {index} is not a JSON object: {type(rec).__name__}"
        )
    return rec


def _normalize_record(rec, context):
    """Return the canonical row(s) for one record (DNS fan-out applied)."""
    ctx = context if isinstance(context, dict) else {}
    payload, params = _split_record(rec)

    scalars: dict = {}
    for col in _SCALAR_COLUMNS:
        scalars[col] = _lookup(col, rec, params, payload, ctx, default="")
    scalars["timestamp"] = _lookup(
        "timestamp", rec, {}, {}, ctx, aliases=_TS_KEYS, default=""
    )
    scalars["gain_pct"] = _resolve_gain_pct(rec, params, payload)

    rows = []
    for name, ms in _dns_pairs(payload):
        row = dict(scalars)
        row["dns_resolver"], row["dns_ms"] = name, ms
        rows.append({col: _cell(row[col]) for col in COLUMNS})
    return rows


def _lookup(col, rec, params, payload, ctx, *, aliases=(), default=""):
    """First-match resolution: record → params → payload → context."""
    sources = (rec, params, payload, ctx)
    keys = (col,) + tuple(aliases)
    for src in sources:
        if not isinstance(src, dict):
            continue
        for key in keys:
            if key in src:
                return src[key]
    return default


def _split_record(rec):
    """Split a record into (result_payload, params).

    Envelope records (contract P2) carry the payload under ``result_raw``
    (a JSON *string*), ``result`` or ``results``; flat records
    (``results.json``) ARE their own payload. Unparseable ``result_raw``
    yields an empty payload — envelope identity survives, measurement cells
    end up empty rather than the record being dropped.
    """
    params = rec.get("params")
    params = params if isinstance(params, dict) else {}
    for key in _PAYLOAD_KEYS:
        raw = rec.get(key)
        if isinstance(raw, dict):
            return raw, params
        if isinstance(raw, str):
            try:
                parsed = json.loads(raw)
            except ValueError:
                return {}, params
            return (parsed, params) if isinstance(parsed, dict) else ({}, params)
    return rec, params


def _resolve_gain_pct(rec, params, payload):
    """Explicit ``gain_pct`` if any layer has one; else derive from A/B Mbps."""
    for src in (rec, params, payload):
        if isinstance(src, dict) and "gain_pct" in src:
            return src["gain_pct"]
    baseline = _number(rec, params, payload, key="baseline_mbps")
    turbo = _number(rec, params, payload, key="turbo8_mbps")
    if baseline is None or turbo is None or baseline <= 0:
        return ""
    return round((turbo / baseline - 1.0) * 100.0, 1)


def _number(*sources, key):
    for src in sources:
        if isinstance(src, dict) and key in src:
            value = src[key]
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                return value
    return None


def _dns_pairs(payload):
    """Extract ``[(resolver, ms), …]`` from the payload's ``dns`` field.

    Tolerates ``[[name, ms], …]``, ``[{"resolver"/"name": …, "ms"/"dns_ms":
    …}, …]``, a ``{name: ms}`` mapping (sorted by name), and absence — the
    latter three degenerate cases yield one blank-pair row so scalars still
    export (same spirit as ReportExporter.dnsRows).
    """
    dns = payload.get("dns") if isinstance(payload, dict) else None
    if isinstance(dns, dict):
        return [(name, dns[name]) for name in sorted(dns)]
    if isinstance(dns, list):
        pairs = []
        for entry in dns:
            if isinstance(entry, (list, tuple)):
                if len(entry) >= 2:
                    pairs.append((entry[0], entry[1]))
            elif isinstance(entry, dict):
                name = next((entry[k] for k in _DNS_NAME_KEYS if k in entry), "")
                ms = next((entry[k] for k in _DNS_MS_KEYS if k in entry), "")
                pairs.append((name, ms))
        return pairs or [("", "")]
    return [("", "")]


def _cell(value):
    """Render one CSV cell: lowercase bools, trimmed floats, '' for null."""
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, float):
        return _fmt_float(value)
    if isinstance(value, str):
        return value
    return str(value)


def _fmt_float(value):
    text = str(value)
    return text[:-2] if text.endswith(".0") else text
