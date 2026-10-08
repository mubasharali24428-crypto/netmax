"""Local regression detection (Gate G-05): the "detect" step of the paid workflow.

Evaluates recent measurement history and raises an alert only when a metric
breaches its threshold 3 consecutive times (the accepted rule). Alerts can be
dismissed for a bounded time or disabled entirely; both are honored before any
history is read.
"""

import json
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

REGRESSION_MIN_SAMPLES = 20
REGRESSION_CONSECUTIVE_BREACHES = 3


def check_regression_alert(
    samples: List[float], threshold: float, is_latency: bool = True
) -> bool:
    """
    Evaluates at least 20 local samples.
    Triggers an alert ONLY if 3 consecutive threshold breaches occur.
    """
    if len(samples) < REGRESSION_MIN_SAMPLES:
        return False

    consecutive_breaches = 0
    for sample in samples:
        # If latency, higher is worse (breach). If throughput, lower is worse (breach).
        breach = (sample > threshold) if is_latency else (sample < threshold)
        if breach:
            consecutive_breaches += 1
            if consecutive_breaches >= REGRESSION_CONSECUTIVE_BREACHES:
                return True
        else:
            consecutive_breaches = 0

    return False


# ── History integration ────────────────────────────────────────────────────

def _app_support_dir() -> Path:
    return Path.home() / "Library" / "Application Support" / "NetMaxDesktop"


def _state_path() -> Path:
    override = os.environ.get("NETMAX_REGRESSION_STATE")
    if override:
        return Path(override)
    return _app_support_dir() / "regression_state.json"


def get_regression_state() -> Dict[str, Any]:
    """Return the persisted regression state (never raises on corrupt data)."""
    try:
        raw = _state_path().read_text(encoding="utf-8")
        state = json.loads(raw)
        if isinstance(state, dict):
            return {
                "disabled": bool(state.get("disabled", False)),
                "dismissed_until": state.get("dismissed_until"),
            }
    except (OSError, json.JSONDecodeError):
        pass
    return {"disabled": False, "dismissed_until": None}


def _write_state(state: Dict[str, Any]) -> None:
    """Atomic write, mode 0600 (may contain no secrets, but stay consistent)."""
    path = _state_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def set_regression_disabled(disabled: bool) -> Dict[str, Any]:
    """Enable or disable regression alerting entirely."""
    state = get_regression_state()
    state["disabled"] = bool(disabled)
    _write_state(state)
    return state


def dismiss_regression_alert(hours: float = 24) -> Dict[str, Any]:
    """Snooze regression alerts for a bounded time (default 24h)."""
    if hours <= 0:
        raise ValueError("dismissal window must be positive")
    state = get_regression_state()
    state["dismissed_until"] = (
        datetime.now(timezone.utc) + timedelta(hours=hours)
    ).isoformat()
    _write_state(state)
    return state


def _dismissal_active(state: Dict[str, Any]) -> bool:
    until = state.get("dismissed_until")
    if not until:
        return False
    try:
        return datetime.fromisoformat(str(until)) > datetime.now(timezone.utc)
    except ValueError:
        return False


def load_metric_series(
    metric: str, history_path: Optional[str] = None, limit: int = 20
) -> List[float]:
    """Load the most recent numeric samples of a metric from history rows."""
    import netmax_history

    path = (
        Path(history_path)
        if history_path
        else _app_support_dir() / "history.jsonl"
    )
    series: List[float] = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(record, dict):
                continue
            row = netmax_history.normalize(record)
            value = row.get(metric)
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                series.append(float(value))
    return series[-limit:] if limit > 0 else []


def check_regression_from_history(
    metric: str,
    threshold: float,
    is_latency: bool = True,
    history_path: Optional[str] = None,
) -> Dict[str, Any]:
    """Evaluate real history for a regression, honoring dismiss/disable state."""
    state = get_regression_state()
    if state["disabled"]:
        return {
            "alert": False,
            "suppressed": True,
            "reason": "regression alerting is disabled",
            "samples": 0,
        }
    if _dismissal_active(state):
        return {
            "alert": False,
            "suppressed": True,
            "reason": f"dismissed until {state['dismissed_until']}",
            "samples": 0,
        }
    series = load_metric_series(metric, history_path)
    alert = check_regression_alert(series, threshold, is_latency)
    return {
        "alert": alert,
        "suppressed": False,
        "reason": "3 consecutive breaches" if alert else "no regression detected",
        "samples": len(series),
    }
