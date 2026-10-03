#!/usr/bin/env python3
"""Scheduling policy for NetMax — power-aware and predictive (P3 items 35/45).

Two questions a fixed scheduler cannot answer:

- **Should this run at all right now?** A 20%-battery laptop mid-call is the
  wrong moment to saturate the link for 30 seconds. `power_policy` turns a
  power state into a concrete adjustment.
- **When is this run worth doing?** A full diagnostic at 19:30 measures your
  neighbours' streaming, not your line. `predict_windows` reads history and
  says when the measurement would actually be informative.

Both return plain data plus a human-readable reason. Neither changes
anything on its own — the caller decides what to do, which keeps this
module free of side effects and trivially testable.
"""

from __future__ import annotations

import json
import re
import statistics
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# ── 45. power-aware scheduling ────────────────────────────────────────────────


@dataclass
class PowerState:
    """What we know about the machine's power source.

    `percent` is None when unknown — a desktop with no battery reports 100
    on AC, but we must not assume that from a failed read.
    """
    on_ac: bool = True
    percent: float | None = None
    source: str = "unknown"          # ac | battery | unknown
    low_power_mode: bool = False

    @property
    def is_battery(self) -> bool:
        return self.source == "battery"


@dataclass
class PowerPolicy:
    """A scheduling decision derived from a power state."""
    run: bool = True
    #: Multiplier on a scheduled test's duration; 1.0 means leave it alone.
    duration_scale: float = 1.0
    #: Multiplier on watch/poll intervals; longer means gentler.
    interval_scale: float = 1.0
    #: Modes to skip entirely under this power state.
    skip_modes: list[str] = field(default_factory=list)
    reason: str = ""
    source: str = "local"

    def to_dict(self) -> dict[str, Any]:
        return {
            "run": self.run, "duration_scale": self.duration_scale,
            "interval_scale": self.interval_scale,
            "skip_modes": list(self.skip_modes), "reason": self.reason,
            "source": self.source,
        }


# Below this, a scheduled saturating test is more likely to annoy than inform.
LOW_BATTERY_PCT = 20.0
# Below this, defer entirely unless the user forced it.
CRITICAL_BATTERY_PCT = 10.0
# A kernel traffic shaper is CPU work; on a low battery it is the wrong cost.
STRICT_POWER_Hungry = {"limit_strict"}


def read_power_state() -> PowerState:
    """Best-effort power state via `pmset -g batt`.

    Returns an `unknown` state rather than raising when the command is
    missing or unparseable — an unreadable power state must not stop a
    scheduled run, only stop us pretending we know the answer.
    """
    try:
        proc = subprocess.run(["pmset", "-g", "batt"],
                              capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return PowerState()
    if proc.returncode != 0:
        return PowerState()

    text = proc.stdout
    state = PowerState()
    if "AC Power" in text:
        state.on_ac, state.source = True, "ac"
    elif "Battery Power" in text:
        state.on_ac, state.source = False, "battery"

    match = re.search(r"(\d{1,3})%", text)
    if match:
        pct = float(match.group(1))
        state.percent = min(100.0, pct)

    if re.search(r"lowpowermode\s+1", text) or "low power mode" in text.lower():
        state.low_power_mode = True
    return state


def power_policy(state: PowerState, *, forced: bool = False) -> PowerPolicy:
    """Turn a power state into a scheduling decision.

    `forced` means the user explicitly asked for this run, which overrides
    every deferral but never the hardware reality (a 3% battery still gets
    its duration scaled down).
    """
    pct = state.percent
    on_ac = state.on_ac and state.source != "battery"

    # Desktop / no battery: nothing to do.
    if on_ac or (pct is None and not state.is_battery):
        return PowerPolicy(
            run=True, duration_scale=1.0, interval_scale=1.0,
            skip_modes=[],
            reason=("on AC power" if on_ac
                    else "no battery reported — no power constraint"),
        )

    if pct is None:
        return PowerPolicy(
            run=True, duration_scale=1.0, interval_scale=1.5,
            skip_modes=sorted(STRICT_POWER_Hungry),
            reason="on battery but level unknown — polled less often, "
                   "skipping kernel shaper",
        )

    if pct <= CRITICAL_BATTERY_PCT:
        if not forced:
            return PowerPolicy(
                run=False, duration_scale=0.5, interval_scale=4.0,
                skip_modes=sorted(STRICT_POWER_Hungry),
                reason=f"battery {pct:.0f}% — deferring scheduled runs",
            )
        return PowerPolicy(
            run=True, duration_scale=0.5, interval_scale=1.0,
            skip_modes=sorted(STRICT_POWER_Hungry),
            reason=f"battery {pct:.0f}% — running as asked, at half duration",
        )

    if pct <= LOW_BATTERY_PCT:
        return PowerPolicy(
            run=True, duration_scale=0.5, interval_scale=2.0,
            skip_modes=sorted(STRICT_POWER_Hungry),
            reason=f"battery {pct:.0f}% — halved duration, polling less often",
        )

    if state.low_power_mode:
        return PowerPolicy(
            run=True, duration_scale=0.75, interval_scale=1.5,
            skip_modes=[],
            reason="low power mode is on — trimmed duration",
        )

    return PowerPolicy(
        run=True, duration_scale=1.0, interval_scale=1.0, skip_modes=[],
        reason=f"battery {pct:.0f}% — no adjustment needed",
    )


def apply_policy(policy: PowerPolicy, *, seconds: int = 10,
                 interval_s: int = 30, mode: str = "") -> dict[str, Any]:
    """Resolve a policy into concrete numbers for a scheduled run.

    Returns the scaled seconds/interval plus whether this mode is skipped,
    so a caller never has to re-derive the arithmetic (and get it wrong).
    """
    skip = bool(mode) and mode in policy.skip_modes
    scaled_seconds = max(1, round(seconds * policy.duration_scale))
    scaled_interval = max(5, round(interval_s * policy.interval_scale))
    return {
        "run": policy.run and not skip,
        "skipped_mode": skip,
        "seconds": scaled_seconds,
        "interval_s": scaled_interval,
        "reason": policy.reason,
    }


# ── 35. predictive scheduling ────────────────────────────────────────────────


@dataclass
class Window:
    """A recommended time to run something."""
    hour: int
    label: str
    expected_mbps: float
    rationale: str

    def to_dict(self) -> dict[str, Any]:
        return {"hour": self.hour, "label": self.label,
                "expected_mbps": round(self.expected_mbps, 2),
                "rationale": self.rationale}


# Fewest measurements per hour before we are willing to talk about a pattern.
MIN_SAMPLES_PER_HOUR = 3
# Below this the quiet hour is not meaningfully quieter than the busy one.
MEANINGFUL_GAP_PCT = 20.0


def load_history(path: str) -> list[dict[str, Any]]:
    """Read a history JSONL file, skipping corrupt lines.

    Duplicates the engine's own tolerance rather than importing it: this
    module is imported by the `plan` surface, which must not drag in the
    whole measurement engine.
    """
    file = Path(path).expanduser()
    if not file.exists():
        raise FileNotFoundError(f"history file not found: {file}")
    rows: list[dict[str, Any]] = []
    for line in file.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(row, dict):
            rows.append(row)
    return rows


def predict_windows(rows: list[dict[str, Any]]) -> dict[str, Any]:
    """Recommend when to measure, from throughput-per-hour history."""
    by_hour: dict[int, list[float]] = {}
    for row in rows:
        mbps = row.get("mbps")
        if not isinstance(mbps, (int, float)) or isinstance(mbps, bool):
            continue
        hour = row.get("hour")
        if not isinstance(hour, int) or not 0 <= hour <= 23:
            ts = row.get("ts")
            # History rows may carry a unix timestamp instead of an hour.
            if isinstance(ts, (int, float)) and ts > 0:
                import time as _time
                hour = _time.localtime(ts).tm_hour
            else:
                continue
        by_hour.setdefault(int(hour), []).append(float(mbps))

    solid = {h: v for h, v in by_hour.items() if len(v) >= MIN_SAMPLES_PER_HOUR}
    if len(solid) < 3:
        return {
            "windows": [], "verdict": "insufficient_data",
            "hours_measured": len(by_hour),
            "notes": [
                f"{len(solid)} hour(s) with {MIN_SAMPLES_PER_HOUR}+ samples; "
                "need 3 for a recommendation"
            ],
            "source": "local",
        }

    means = {h: statistics.fmean(v) for h, v in solid.items()}
    best_hour = max(means, key=lambda h: means[h])
    worst_hour = min(means, key=lambda h: means[h])
    best, worst = means[best_hour], means[worst_hour]

    gap_pct = ((best - worst) / worst * 100.0) if worst > 0 else 0.0
    windows: list[Window] = [
        Window(hour=best_hour, label="quiet — best time to measure capacity",
               expected_mbps=best,
               rationale=f"{best:.1f} Mbps average over "
                         f"{len(solid[best_hour])} runs"),
    ]

    notes = [
        f"best hour {best_hour:02d}:00 ({best:.1f} Mbps), "
        f"worst {worst_hour:02d}:00 ({worst:.1f} Mbps)",
    ]

    if gap_pct >= MEANINGFUL_GAP_PCT:
        # Contention hours are the ones worth watching, and the worst hour
        # is where a bufferbloat check actually tells you something.
        windows.append(
            Window(hour=worst_hour, label="busy — best time to test contention",
                   expected_mbps=worst,
                   rationale=f"{gap_pct:.0f}% below the best hour; "
                             "a full/bloat run here reflects real contention"),
        )
        notes.append(
            f"{gap_pct:.0f}% spread by time of day — schedule a contention "
            "check at the busy hour and a capacity check at the quiet one"
        )
    else:
        notes.append(
            f"only a {gap_pct:.0f}% spread across hours — timing does not "
            "matter much on this link"
        )

    # A second quiet hour if one is close behind the best.
    ranked = sorted(means.items(), key=lambda kv: -kv[1])
    for hour, mbps in ranked[1:3]:
        if hour != best_hour and mbps >= best * 0.85:
            windows.append(
                Window(hour=hour, label="also quiet",
                       expected_mbps=mbps,
                       rationale=f"{mbps:.1f} Mbps average, close to the best hour"),
            )

    windows.sort(key=lambda w: w.hour)
    return {
        "windows": [w.to_dict() for w in windows],
        "verdict": "recommendation",
        "hours_measured": len(by_hour),
        "gap_pct": round(gap_pct, 1),
        "notes": notes,
        "source": "local",
    }