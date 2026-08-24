#!/usr/bin/env python3
"""netmax_planconfig — plan-aware config from ~/.netmaxrc (BRAVO-B1-09).

Parses an INI file (default ``~/.netmaxrc``) for a ``[plan]`` section:

    [plan]
    down_mbps = 940
    up_mbps   = 35          ; optional

Contract
--------
- Only the ``[plan]`` section is read; unknown sections are ignored.
- Missing file → :data:`DEFAULTS`, no warnings.
- Malformed values, out-of-range values, or a broken file fall back to the
  default for that key and record a human-readable warning. Never raises on
  bad input.
- Validation: down/up must parse as a float with ``0 < value <= 10000``.

Public API used later for percentile scoring::

    load_config(path=None) -> {"down_mbps": float,
                               "up_mbps": float | None,
                               "warnings": list[str]}
"""

from __future__ import annotations

import configparser
import os
from pathlib import Path

__all__ = ["DEFAULTS", "MAX_MBPS", "RC_FILENAME", "load_config"]

#: Fallback plan when no config exists or a value is unusable.
DEFAULTS: dict = {"down_mbps": 1000.0, "up_mbps": None}

#: Inclusive upper bound for any *_mbps value; must also be strictly > 0.
MAX_MBPS = 10_000.0

#: Config file looked up in $HOME when no explicit path is given.
RC_FILENAME = ".netmaxrc"


def _validate(key: str, raw: str, warnings: list[str]) -> float | None:
    """Return a validated float for *key*, or ``None`` after recording a warning."""
    try:
        value = float(raw)
    except (TypeError, ValueError):
        warnings.append(
            f"[plan] {key}: {raw!r} is not a number; using default"
        )
        return None

    if not (0.0 < value <= MAX_MBPS):
        warnings.append(
            f"[plan] {key}: {value:g} outside allowed range "
            f"(0 < {key} <= {MAX_MBPS:g}); using default"
        )
        return None

    return value


def load_config(
    path: str | os.PathLike[str] | None = None,
) -> dict:
    """Load plan settings from *path* (default ``~/.netmaxrc``).

    Returns a dict with keys:

    - ``"down_mbps"``: validated download Mbps (float, never None).
    - ``"up_mbps"``: validated upload Mbps or ``None`` when absent/invalid.
    - ``"warnings"``: list of human-readable strings (empty when clean).
    """
    rc_path = Path(path).expanduser() if path is not None else (
        Path.home() / RC_FILENAME
    )

    warnings: list[str] = []

    if not rc_path.is_file():
        # No file at all is normal (first run): defaults, no warnings.
        return {
            "down_mbps": DEFAULTS["down_mbps"],
            "up_mbps": DEFAULTS["up_mbps"],
            "warnings": warnings,
        }

    parser = configparser.ConfigParser()

    try:
        parser.read(rc_path, encoding="utf-8")
    except (configparser.Error, OSError, UnicodeDecodeError) as exc:
        warnings.append(f"{rc_path}: unreadable ({exc}); using defaults")
        return {
            "down_mbps": DEFAULTS["down_mbps"],
            "up_mbps": DEFAULTS["up_mbps"],
            "warnings": warnings,
        }

    result: dict = {
        "down_mbps": DEFAULTS["down_mbps"],
        "up_mbps": DEFAULTS["up_mbps"],  # stays None unless valid below
        "warnings": warnings,
    }

    if not parser.has_section("plan"):
        # File exists but has nothing relevant: defaults, no warnings needed.
        return result

    for key in ("down_mbps", "up_mbps"):
        if not parser.has_option("plan", key):
            continue
        raw = parser.get("plan", key)
        value = _validate(key, raw, warnings)
        if value is None:
            continue
        result[key] = value

    return result


if __name__ == "__main__":  # pragma: no cover - manual smoke check
    print(load_config())
