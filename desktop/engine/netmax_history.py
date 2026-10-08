#!/usr/bin/env python3
"""Turn real NetMax history records into the flat rows the analysers read.

This module exists because of a bug found against a live network, not in
tests. The analysers in netmax_ai*.py consume flat numeric fields
(`mbps`, `loss_pct`, `hour`, ...). What the app actually stores is:

    {"ts": "<ISO8601>", "mode": "baseline",
     "params": {...}, "result_raw": "single-stream 1 stream(s) 14.1 Mbps ..."}

so every analyser read **zero** samples from real history while passing
every test written against synthetic flat fixtures. `ts` is an ISO8601
string, the metrics live inside a nested human-readable `result_raw`
blob, and the hour-of-day never appears at all.

Two lessons are encoded here rather than left to memory:
  1. Fixtures must be shaped like production data, or they certify nothing.
     Every regex below is taken from output captured off a live run, and
     `test_netmax_history.py` feeds these exact strings.
  2. A parser for prose must never invent a number. Every extractor
     returns None when the text does not contain that metric, so "not
     measured" stays distinguishable from zero.

`normalize()` is the single entry point; `run_ai_analysis` calls it on
every history row so all 26 analysers benefit without touching them.
"""

from __future__ import annotations

import json
import io
import os
import re
import stat
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

_MCP_HISTORY_MAX_BYTES = 10 * 1024 * 1024
_MCP_HISTORY_MAX_ROWS = 100_000

# ── timestamp ────────────────────────────────────────────────────────────────

_TS_FORMATS = (
    "%Y-%m-%dT%H:%M:%S%z",
    "%Y-%m-%dT%H:%M:%S.%f%z",
    "%Y-%m-%dT%H:%M:%SZ",
    "%Y-%m-%dT%H:%M:%S",
    "%Y-%m-%d %H:%M:%S",
)


def parse_timestamp(value: Any) -> tuple[float | None, int | None]:
    """Return (unix_seconds, local_hour) from whatever shape ts arrived in.

    The app writes ISO8601 with a Z; older rows and hand-written history
    files use unix floats or other ISO variants. A numeric input is
    treated as unix seconds ONLY when it is plausibly one — a bare integer
    like 20261004 is a date, not an epoch.
    """
    if value is None:
        return None, None
    if isinstance(value, bool):
        return None, None
    if isinstance(value, (int, float)):
        seconds = float(value)
        if not (1_000_000_000 < seconds < 4_000_000_000):
            return None, None          # not an epoch; do not guess
        return seconds, datetime.fromtimestamp(seconds).hour

    text = str(value).strip()
    if not text:
        return None, None
    if text.endswith("Z"):
        text = text[:-1] + "+0000"
    for fmt in _TS_FORMATS:
        try:
            parsed = datetime.strptime(text, fmt)
        except ValueError:
            continue
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.timestamp(), parsed.hour
    # Last resort: a numeric string.
    try:
        return parse_timestamp(float(text))
    except ValueError:
        return None, None


# ── metric extraction from result_raw ────────────────────────────────────────

# Each pattern is anchored on real captured output. Group 1 is the value.
_PATTERNS: dict[str, re.Pattern[str]] = {
    # "single-stream   1 stream(s)     14.1 Mbps   (16 MB in 10s)"
    "mbps": re.compile(r"([+-]?\d+(?:\.\d+)?)\s*Mbps\b"),
    # "upload: 6.2 Mbps"
    "upload_mbps": re.compile(r"upload[^0-9+-]{0,20}([+-]?\d+(?:\.\d+)?)\s*Mbps", re.I),
    # "packet loss: 0.0%"
    "loss_pct": re.compile(r"packet loss[^0-9+-]{0,12}([+-]?\d+(?:\.\d+)?)\s*%", re.I),
    # "jitter: 64.3 ms"
    "jitter_ms": re.compile(r"jitter[^0-9+-]{0,12}([+-]?\d+(?:\.\d+)?)\s*ms", re.I),
    # "idle latency: 12.0 ms" / "latency under load: 180 ms"
    "idle_latency_ms": re.compile(
        r"idle latency[^0-9+-]{0,12}([+-]?\d+(?:\.\d+)?)\s*ms", re.I),
    "loaded_latency_ms": re.compile(
        r"(?:latency under load|loaded latency)[^0-9+-]{0,12}"
        r"([+-]?\d+(?:\.\d+)?)\s*ms", re.I),
    # "eco-bloat: +0.0 ms (estimated grade A+, ~100 KB used)"
    "bloat_delta_ms": re.compile(
        r"(?:eco-)?bloat[^0-9+-]{0,12}([+-]?\d+(?:\.\d+)?)\s*ms", re.I),
    # "estimated grade A+" / "grade C".
    # The lookahead is not \b: after "A+" the next char is often punctuation
    # (", " or " ("), and \b requires a word/non-word transition, so \b
    # FAILS there and the alternation silently backtracks to match bare "A"
    # — losing the "+" that distinguishes the best grade from the second.
    "bloat_grade": re.compile(r"grade\s+(A\+|A|B|C|D|E|F)(?![A-Za-z0-9])"),
    # "(16 MB in 10s)"
    "seconds": re.compile(r"\(\s*[\d,]+\s*MB in\s*([+-]?\d+(?:\.\d+)?)s\)", re.I),
    # wifi: "rssi_dbm: -23"
    "rssi": re.compile(r"rssi_dbm:\s*(-?\d+(?:\.\d+)?)"),
    "noise": re.compile(r"noise_dbm:\s*(-?\d+(?:\.\d+)?)"),
    # "Google 8.8.8.8          193.5 ms  ← fastest"
    "dns_ms": re.compile(
        r"^\s*\d+\.\s+\S.*?([\d.]+)\s*ms", re.M),
    # bloat delta = loaded - idle, when both are present
}

# A grade letter is categorical, not numeric — keep it out of the numeric
# extraction path so `_numeric` cannot coerce it to 0.
_STRING_FIELDS = ("bloat_grade",)


def _numeric(text: str, key: str) -> float | None:
    pattern = _PATTERNS.get(key)
    if pattern is None:
        return None
    match = pattern.search(text or "")
    if not match:
        return None
    try:
        return float(match.group(1))
    except (TypeError, ValueError):
        return None


def _string(text: str, key: str) -> str | None:
    pattern = _PATTERNS.get(key)
    if pattern is None:
        return None
    match = pattern.search(text or "")
    return match.group(1) if match else None


def extract_metrics(result_raw: str, mode: str = "") -> dict[str, Any]:
    """Pull every recognisable metric out of one run's raw text.

    Absent metrics are OMITTED, never zero — "jitter not measured" and
    "jitter 0 ms" are opposite claims and several analysers branch on
    presence.
    """
    text = result_raw or ""
    out: dict[str, Any] = {}

    for key in _PATTERNS:
        if key in _STRING_FIELDS:
            value = _string(text, key)
        else:
            value = _numeric(text, key)
        if value is not None:
            out[key] = value

    # bloat_delta_ms is the honest measure when both latencies are present.
    loaded = out.pop("loaded_latency_ms", None)
    idle = out.get("idle_latency_ms")
    if loaded is not None and idle:
        out["bloat_delta_ms"] = round(loaded - idle, 2)

    # An explicitly "upload"-labelled figure must never become `mbps`.
    # Otherwise an upload run's rate is read as download throughput by every
    # downstream analyser — a wrong number rather than a missing one, which
    # is the more dangerous of the two.
    if _PATTERNS["upload_mbps"].search(text or ""):
        out.pop("mbps", None)
    if "upload" not in (mode or "").lower():
        # A download run contains no upload measurement at all. Recording
        # one anyway would let a downstream "is upload healthy?" check pass
        # on a download figure.
        out.pop("upload_mbps", None)

    return out


def normalize(record: dict[str, Any]) -> dict[str, Any]:
    """One history record -> a flat row the analysers can consume.

    A record already in flat form (the synthetic fixtures the tests use) is
    passed through with only its timestamp normalised, so both shapes work.
    """
    if not isinstance(record, dict):
        return {}

    row: dict[str, Any] = {}
    mode = str(record.get("mode") or "")
    if mode:
        row["mode"] = mode

    seconds, hour = parse_timestamp(record.get("ts"))
    if seconds is not None:
        row["ts"] = seconds
    if hour is not None:
        row["hour"] = hour

    raw = record.get("result_raw")
    if isinstance(raw, str) and raw.strip():
        row.update(extract_metrics(raw, mode))

    # Carry through any flat numeric fields the record already had, so a
    # hand-written or already-normalised history still works.
    for key, value in record.items():
        if key in {"ts", "result_raw", "mode", "params", "history"}:
            continue
        if key in _STRING_FIELDS:
            if isinstance(value, str) and value not in row:
                row[key] = value
        elif (isinstance(value, (int, float)) and not isinstance(value, bool)
                and value == value):
            row.setdefault(key, value)

    # Stream count lives in params; the analysers want a flat `streams`.
    params = record.get("params")
    if isinstance(params, dict):
        streams = params.get("streams")
        if isinstance(streams, int) and not isinstance(streams, bool):
            row["streams"] = streams

    return row


def normalize_all(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [row for row in (normalize(r) for r in records) if row]


def load_and_normalize(path: str) -> list[dict[str, Any]]:
    """Read a history JSONL file and return flat rows.

    Tolerates corrupt lines exactly as the engine's own history reader does,
    so one bad line cannot silently drop the whole file.
    """
    file = Path(path).expanduser()
    if not file.exists():
        raise FileNotFoundError(f"history file not found: {file}")
    records: list[dict[str, Any]] = []
    for line in file.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(record, dict):
            records.append(record)
    return normalize_all(records)


def load_mcp_history(path: str) -> list[dict[str, Any]]:
    """Read only the canonical app history through no-follow descriptors."""
    home = Path.home()
    expected = home / "Library" / "Application Support" / "NetMaxDesktop" / "history.jsonl"
    if Path(path).expanduser() != expected:
        raise ValueError("MCP history must use the canonical NetMaxDesktop history file")
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    directory_fd = file_fd = -1
    try:
        home_stat = home.lstat()
        if not stat.S_ISDIR(home_stat.st_mode) or home_stat.st_uid != os.getuid():
            raise ValueError("MCP history home is not a user-owned directory")
        directory_fd = os.open(home, directory_flags)
        for component in ("Library", "Application Support", "NetMaxDesktop"):
            child_fd = os.open(component, directory_flags, dir_fd=directory_fd)
            child_stat = os.fstat(child_fd)
            if not stat.S_ISDIR(child_stat.st_mode) or child_stat.st_uid != os.getuid():
                os.close(child_fd)
                raise ValueError("MCP history parent is not a user-owned directory")
            os.close(directory_fd)
            directory_fd = child_fd
        file_fd = os.open("history.jsonl", os.O_RDONLY | os.O_NOFOLLOW,
                          dir_fd=directory_fd)
        file_stat = os.fstat(file_fd)
        if (not stat.S_ISREG(file_stat.st_mode) or file_stat.st_uid != os.getuid()
                or file_stat.st_mode & 0o022):
            raise ValueError("MCP history must be a user-owned, non-writable regular file")
        if file_stat.st_size > _MCP_HISTORY_MAX_BYTES:
            raise ValueError("MCP history exceeds the 10 MiB limit")
        with os.fdopen(file_fd, "rb") as stream:
            file_fd = -1
            data = stream.read(_MCP_HISTORY_MAX_BYTES + 1)
    except OSError as exc:
        raise ValueError(f"cannot safely open MCP history: {exc}") from exc
    finally:
        if file_fd >= 0:
            os.close(file_fd)
        if directory_fd >= 0:
            os.close(directory_fd)
    if len(data) > _MCP_HISTORY_MAX_BYTES:
        raise ValueError("MCP history exceeds the 10 MiB limit")
    records = []
    row_count = 0
    for line in io.BytesIO(data):
        if not line.strip():
            continue
        row_count += 1
        if row_count > _MCP_HISTORY_MAX_ROWS:
            raise ValueError("MCP history exceeds the 100,000-row limit")
        try:
            record = json.loads(line)
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
        if isinstance(record, dict):
            records.append(record)
    return normalize_all(records)


# ── Coherent history ─────────────────────────────────────────────────────────

def build_coherent(rows: list[dict[str, Any]], *, mode: str = "") -> list[dict[str, Any]]:
    """Merge measurements of different kinds onto one timeline.

    The analysers want rows where one row carries several metrics at a
    moment in time; real history stores one metric per run. Joining on the
    nearest timestamp within `window_s` is what makes a root-cause or
    digital-twin analysis possible at all.

    Refuses to invent rows: a timestamp with no counterpart within the
    window simply does not appear in the output.
    """
    if not rows:
        return []
    stamped = [r for r in rows if isinstance(r.get("ts"), (int, float))]
    if not stamped:
        return []
    stamped.sort(key=lambda r: r["ts"])

    usable = [r for r in stamped
              if not mode or str(r.get("mode", "")) == mode] or stamped

    merged: list[dict[str, Any]] = []
    window = 900.0          # 15 minutes: long enough to pair a bloat run
                             # with the baseline either side of it
    for anchor in usable:
        base_ts = anchor["ts"]
        combined: dict[str, Any] = {"ts": base_ts, "hour": anchor.get("hour")}
        for row in stamped:
            if abs(row["ts"] - base_ts) <= window:
                for key, value in row.items():
                    if key in ("ts", "hour") or value is None:
                        continue
                    # First writer wins: the anchor's own metrics are the
                    # most direct measurement of that moment.
                    combined.setdefault(key, value)
        if len(combined) > 2:      # ts + hour + at least one metric
            merged.append(combined)
    return merged
