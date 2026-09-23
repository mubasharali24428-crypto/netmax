"""Trend analysis over NetMax history records (contract P2).

Reads the record shape persisted by HistoryStore.swift:

    {"ts": <ISO8601>, "mode": str, "params": {str: int}, "result_raw": str}

`result_raw` holds the engine's raw payload, which comes in two flavors in
this repo — pretty-printed JSON (e.g. netmax_fetch's
`{"bytes": …, "mbps": …}`) or tagged CLI text (e.g. `loaded increase:
+58.2 ms`, ping's `12.5% packet loss`). Parsing here is tolerant exactly like
the Swift side: whatever doesn't parse is skipped silently rather than fatal.

All functions are pure stdlib and deterministic — safe for offline tests.
"""

from __future__ import annotations

import json
import re
import statistics
from datetime import datetime

__all__ = [
    "SUPPORTED_METRICS",
    "anomalies",
    "deltas",
    "extract_series",
    "rolling_median",
]

# ── metrics ──────────────────────────────────────────────────────────────────

SUPPORTED_METRICS = ("mbps", "loss", "jitter", "loaded_increase")

# Metric → JSON key aliases (compared lowercased). `delta_ms` is what watch
# mode stores for the loaded-latency increase.
_JSON_ALIASES: dict[str, tuple[str, ...]] = {
    "mbps": (
        "mbps", "down_mbps", "up_mbps", "speed_mbps", "throughput_mbps",
        "bandwidth_mbps",
    ),
    "loss": (
        "loss", "packet_loss", "packet_loss_pct", "packet_loss_percent",
        "loss_pct", "loss_percent",
    ),
    "jitter": ("jitter", "jitter_ms", "jitter_msec"),
    "loaded_increase": (
        "loaded_increase", "loaded_increase_ms", "delta_ms",
        "latency_increase_ms", "load_delta_ms", "bufferbloat_ms",
    ),
}

_NUM = r"-?\d+(?:\.\d+)?"
_SIGNED = rf"[+-]?{_NUM}"  # engine prints e.g. "loaded increase:   +58.2 ms"

# Metric → ordered regexes over tagged text; first match wins per record.
_TEXT_PATTERNS: dict[str, tuple[re.Pattern[str], ...]] = {
    "mbps": (
        re.compile(rf"({_NUM})\s*(?:mbps|mbits/s|mb/s)", re.IGNORECASE),
    ),
    "loss": (
        # ping statistics block: "12.5% packet loss"
        re.compile(rf"({_NUM})\s*%\s*packet\s*loss", re.IGNORECASE),
        # tagged: "packet loss: 3%" / "loss = 0%"
        re.compile(rf"(?:packet\s+)?loss[^%\n]*?[=:]\s*({_NUM})\s*%",
                   re.IGNORECASE),
    ),
    "jitter": (
        # tagged: "jitter: 7.5 ms" / "jitter = 3.2ms" / "jitter 7.5"
        re.compile(rf"jitter[^-\d\n]*?({_SIGNED})", re.IGNORECASE),
        # value-first phrasing: "3.2 ms jitter"
        re.compile(rf"({_SIGNED})\s*ms\s+jitter\b", re.IGNORECASE),
        # ping stats line: "rtt min/avg/max/mdev = ... 4.810 ms"
        re.compile(rf"(?:mdev|stddev)\s*=\s*({_SIGNED})", re.IGNORECASE),
    ),
    "loaded_increase": (
        # run_bloat prints: "loaded increase:   +58.2 ms"
        re.compile(rf"loaded\s+increase\s*:?\s*({_SIGNED})", re.IGNORECASE),
        # prose: "latency increased by 42 ms" / "latency increase: 42 ms"
        re.compile(rf"latency\s+(?:increased\s+by|increase)\s*:?\s*({_SIGNED})",
                   re.IGNORECASE),
        # tagged JSON-ish text: "delta_ms=45.6" / "delta_ms\": 45.6"
        re.compile(rf"delta[_\s]*ms[\"':=\s]+({_NUM})", re.IGNORECASE),
    ),
}


def _is_number(value: object) -> bool:
    """True for real numbers — bools are ints in Python, so exclude them."""
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _coerce_number(value: object) -> float | None:
    """Best-effort float coercion ('38.05' → 38.05); None otherwise."""
    if _is_number(value):
        return float(value)  # type: ignore[arg-type]
    if isinstance(value, str):
        text = value.strip()
        try:
            return float(text)
        except ValueError:
            return None
    return None


def _find_json_value(payload: object, aliases: tuple[str, ...],
                     depth: int = 2) -> float | None:
    """Depth-limited search of decoded JSON for the first aliased key.

    Covers top-level payloads and one/two levels of nesting (lists included);
    iteration follows the payload's own key order, so results are stable.
    """
    if depth < 0:
        return None
    if isinstance(payload, dict):
        lowered = {str(k).lower(): v for k, v in payload.items()}
        for alias in aliases:
            if alias in lowered:
                number = _coerce_number(lowered[alias])
                if number is not None:
                    return number
        for value in lowered.values():
            if isinstance(value, (dict, list)):
                number = _find_json_value(value, aliases, depth - 1)
                if number is not None:
                    return number
    elif isinstance(payload, list):
        for item in payload:
            number = _find_json_value(item, aliases, depth)
            if number is not None:
                return number
    return None


def _parse_text(text: str, metric: str) -> float | None:
    """First matching tagged-text pattern wins; None when nothing matches."""
    for pattern in _TEXT_PATTERNS[metric]:
        match = pattern.search(text)
        if match:
            return float(match.group(1))
    return None


def _parse_ts(raw: object) -> object:
    """ISO8601 string → datetime; epoch numbers → UTC datetime.

    Anything unparseable is returned untouched so callers still get an
    ordering token instead of losing the point (tolerant, never raises).
    """
    if isinstance(raw, datetime):
        return raw
    if isinstance(raw, (int, float)) and not isinstance(raw, bool):
        try:
            return datetime.utcfromtimestamp(float(raw))
        except (OverflowError, OSError, ValueError):
            return raw
    if isinstance(raw, str):
        text = raw.strip()
        try:  # Python ≥3.11 accepts a trailing 'Z' directly.
            return datetime.fromisoformat(text)
        except ValueError:
            pass
        normalized = text.replace("Z", "+00:00").replace("z", "+00:00")
        try:
            return datetime.fromisoformat(normalized)
        except ValueError:
            return raw
    return raw


def _payload_of(record: object) -> tuple[object, object]:
    """Extract (ts, result_raw-payload) from a record; (None, None) if unfit.

    Accepts HistoryRecord-shaped dicts ({ts, mode, params, result_raw}),
    raw JSONL line strings encoding the same, and bare payloads.
    """
    if isinstance(record, str):
        try:
            record = json.loads(record)
        except ValueError:
            return None, None
    if not isinstance(record, dict):
        return None, None
    ts = _parse_ts(record.get("ts"))
    payload = record.get("result_raw", record.get("resultRaw"))
    if isinstance(payload, str):
        try:  # pretty-printed JSON is still valid JSON as a whole
            payload = json.loads(payload)
        except ValueError:
            pass  # keep the string; tagged-text parser takes it from here
    return ts, payload


def _metric_value(payload: object, metric: str) -> float | None:
    """Pull one metric out of a decoded-or-text payload; None if absent.

    Order: aliased JSON keys → bare numeric payload → tagged text →
    strings embedded inside JSON (envelope shapes like {"raw": "…"}).
    """
    if payload is None:
        return None
    number = None
    if isinstance(payload, (dict, list)):  # JSON flavor (incl. nested)
        number = _find_json_value(payload, _JSON_ALIASES[metric])
        if number is None:  # envelope: metric lives in an embedded string
            number = _find_embedded_text(payload, metric)
    elif isinstance(payload, (int, float)) and not isinstance(payload, bool):
        number = float(payload)
        return number
    if number is None and isinstance(payload, str):  # tagged-text flavor
        number = _parse_text(payload, metric)
    return number


def _find_embedded_text(payload: object, metric: str,
                        depth: int = 3) -> float | None:
    """Scan string values inside decoded JSON for tagged-text metrics.

    Covers envelope shapes like {"raw": "<full CLI output>"} where the
    engine's human-readable result is stored as a string inside JSON.
    Deterministic: walks keys/lists in order, first match wins.
    """
    if depth < 0:
        return None
    if isinstance(payload, str):
        return _parse_text(payload, metric)
    if isinstance(payload, dict):
        for value in payload.values():
            number = _find_embedded_text(value, metric, depth - 1)
            if number is not None:
                return number
    elif isinstance(payload, list):
        for item in payload:
            number = _find_embedded_text(item, metric, depth - 1)
            if number is not None:
                return number
    return None


def extract_series(records, metric: str) -> list[tuple[object, float]]:
    """Pull one metric out of history records → [(ts, value)] in file order.

    Tolerant like the Swift loaders: records that don't decode, lack the
    metric, or hold non-numeric values are skipped silently. Timestamps are
    parsed from ISO8601/epoch where possible and passed through verbatim
    otherwise, so ordering is never destroyed.

    Metrics: 'mbps', 'loss', 'jitter', 'loaded_increase'.
    """
    if metric not in SUPPORTED_METRICS:
        raise ValueError(
            f"unknown metric {metric!r}; expected one of {SUPPORTED_METRICS}")
    series: list[tuple[object, float]] = []
    for record in records:
        ts, payload = _payload_of(record)
        value = _metric_value(payload, metric)
        if value is not None:
            series.append((ts, value))
    return series


# ── trend math ───────────────────────────────────────────────────────────────

def rolling_median(series, window: int) -> list[tuple[object, float]]:
    """Trailing-window median at each point → [(ts, median)] (same length).

    Edges use the available prefix (window i+1 at index i). window must be a
    positive int; window=1 returns the series unchanged numerically.
    """
    if not isinstance(window, int) or isinstance(window, bool) or window < 1:
        raise ValueError("window must be an int >= 1")
    out: list[tuple[object, float]] = []
    values = [float(v) for _, v in series]
    for i, (ts, _) in enumerate(series):
        lo = max(0, i + 1 - window)
        out.append((ts, statistics.median(values[lo:i + 1])))
    return out


def deltas(series) -> list[tuple[object, float]]:
    """Consecutive differences → [(later_ts, v[i] − v[i−1])]; [] under 2 pts."""
    return [(series[i][0], float(series[i][1]) - float(series[i - 1][1]))
            for i in range(1, len(series))]


def anomalies(series, k: float = 3.0, window: int = 7):
    """Flag points deviating more than k MADs from their rolling median.

    Returns [(index, ts, value)] for every point whose absolute residual
    from rolling_median(series, window) exceeds k × MAD, where MAD is the
    median of all residuals across the series. If MAD collapses to 0 (flat
    signal with isolated spikes), any nonzero residual is flagged — an exact
    departure from an otherwise-constant window is the anomaly. Input is
    never mutated; [] for empty series.
    """
    if not series:
        return []
    rolled = rolling_median(series, window)
    residuals = [float(v) - float(m) for (_, v), (_, m) in zip(series, rolled)]
    mad = statistics.median(abs(r) for r in residuals)

    flagged: list[tuple[int, object, float]] = []
    for i, ((ts, value), residual) in enumerate(zip(series, residuals)):
        if mad > 0.0:
            if abs(residual) > k * mad:
                flagged.append((i, ts, float(value)))
        elif residual != 0.0:
            flagged.append((i, ts, float(value)))
    return flagged
