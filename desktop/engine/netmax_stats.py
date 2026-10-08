#!/usr/bin/env python3
"""Tier-0 statistical intelligence for NetMax: anomaly + forecast primitives.

Pure stdlib, zero dependencies, O(n) or O(n log n) throughout. Every
function is deterministic and side-effect free, so analysers can call them
on history rows without fixtures, keys, or network.

Covers AI-025/029 (reconstruction-free anomaly scores), AI-013/018
(forecasts with bands), AI-043 (per-network baselines feed these as input),
and the Tier-0 rows of ml-algorithms-research.md.
"""
from __future__ import annotations

import math
from typing import Any, Sequence


def _check(series: Sequence[float]) -> list[float]:
    values = [float(x) for x in series]
    if not values:
        raise ValueError("empty series")
    if any(math.isnan(v) or math.isinf(v) for v in values):
        raise ValueError("series contains NaN or inf")
    return values


class Welford:
    """O(1)-memory running mean/variance (numerically stable)."""

    __slots__ = ("_m2", "mean", "n")

    def __init__(self) -> None:
        self.n = 0
        self.mean = 0.0
        self._m2 = 0.0

    def update(self, x: float) -> None:
        self.n += 1
        delta = x - self.mean
        self.mean += delta / self.n
        self._m2 += delta * (x - self.mean)

    @property
    def variance(self) -> float:
        return self._m2 / (self.n - 1) if self.n > 1 else 0.0

    @property
    def std(self) -> float:
        return math.sqrt(self.variance)


def ewma(series: Sequence[float], alpha: float = 0.3) -> list[float]:
    """Exponentially-weighted moving average. alpha in (0, 1]."""
    values = _check(series)
    if not 0.0 < alpha <= 1.0:
        raise ValueError("alpha must be in (0, 1]")
    out = [values[0]]
    for x in values[1:]:
        out.append(alpha * x + (1.0 - alpha) * out[-1])
    return out


def ewma_bands(series: Sequence[float], alpha: float = 0.3,
               k: float = 3.0) -> list[tuple[float, float, float]]:
    """(mid, lo, hi) per point; residual scale from one-step errors."""
    values = _check(series)
    mid = ewma(values, alpha)
    errors = [abs(v - m) for v, m in zip(values, mid)]
    scale = sum(errors) / len(errors) or 1e-9
    return [(m, m - k * scale, m + k * scale) for m in mid]


def cusum(values: Sequence[float], drift: float = 0.0,
          threshold: float = 0.0) -> list[dict[str, float]]:
    """Two-sided tabular CUSUM level-shift detector.

    drift/threshold default to 0.5/5.0 × std of the first half (reference
    window), so callers pass just the series for the common case.
    Returns [{index, direction (+1/-1), magnitude}] — empty means no shift.
    """
    series = _check(values)
    ref = series[:max(2, len(series) // 2)]
    mu = sum(ref) / len(ref)
    sd = math.sqrt(sum((x - mu) ** 2 for x in ref) / len(ref)) or 1e-9
    drift = drift or 0.5 * sd
    threshold = threshold or 5.0 * sd
    hits: list[dict[str, float]] = []
    pos = neg = 0.0
    for i, x in enumerate(series):
        pos = max(0.0, pos + (x - mu) - drift)
        neg = min(0.0, neg + (x - mu) + drift)
        if pos > threshold:
            hits.append({"index": float(i), "direction": 1.0,
                         "magnitude": (x - mu) / sd})
            pos = 0.0
        elif -neg > threshold:
            hits.append({"index": float(i), "direction": -1.0,
                         "magnitude": (mu - x) / sd})
            neg = 0.0
    return hits


def mad_scores(series: Sequence[float]) -> list[float]:
    """Robust modified z-scores (median/MAD). A spike can't hide behind
    the mean it distorts — the property that makes this the point-anomaly
    default over plain z-scores."""
    values = _check(series)
    ordered = sorted(values)
    mid = len(ordered) // 2
    median = (ordered[mid] if len(ordered) % 2 else
              (ordered[mid - 1] + ordered[mid]) / 2.0)
    mad = sorted(abs(v - median) for v in values)[mid] or 1e-9
    return [0.6745 * (v - median) / mad for v in values]


def flag_points(series: Sequence[float],
                threshold: float = 3.5) -> list[dict[str, float]]:
    """Point anomalies via MAD scores. Empty list = nothing anomalous."""
    return [{"index": float(i), "kind": 0.0, "score": abs(s)}
            for i, s in enumerate(mad_scores(series)) if abs(s) > threshold]


def stl_lite(series: Sequence[float],
             period: int) -> dict[str, list[float]]:
    """Seasonal-trend decomposition without LOESS: trend = centered moving
    average, seasonal = period-bin means of detrended, residual = rest.
    Good enough to separate evening-congestion pattern from genuine fault."""
    values = _check(series)
    if period < 2:
        raise ValueError("period must be >= 2")
    if len(values) < 2 * period + 1:
        raise ValueError(f"need >= {2 * period + 1} points for period "
                         f"{period}")
    half = period // 2
    trend = [sum(values[max(0, i - half):i + half + 1]) /
             len(values[max(0, i - half):i + half + 1])
             for i in range(len(values))]
    detrended = [v - t for v, t in zip(values, trend)]
    bins: list[list[float]] = [[] for _ in range(period)]
    for i, d in enumerate(detrended):
        bins[i % period].append(d)
    seasonal_profile = [sum(b) / len(b) for b in bins]
    seasonal = [seasonal_profile[i % period] for i in range(len(values))]
    residual = [v - t - s for v, t, s in zip(values, trend, seasonal)]
    return {"trend": trend, "seasonal": seasonal, "residual": residual}


def seasonal_anomalies(series: Sequence[float], period: int,
                       threshold: float = 3.0) -> list[dict[str, float]]:
    """Anomalies in the STL-lite residual: pattern-aware, so a slow Tuesday
    is not flagged just for being slower than Sunday."""
    residual = stl_lite(series, period)["residual"]
    mu = sum(residual) / len(residual)
    sd = math.sqrt(sum((r - mu) ** 2 for r in residual) / len(residual))
    sd = sd or 1e-9
    # The centered moving-average trend is asymmetric at the edges, so the
    # first/last `period` residuals carry edge distortion, not signal.
    # Only the interior can raise flags.
    lo, hi = period, len(residual) - period
    return [{"index": float(i), "kind": 1.0, "score": abs((r - mu) / sd)}
            for i, r in enumerate(residual)
            if lo <= i < hi and abs((r - mu) / sd) > threshold]


def holt_forecast(series: Sequence[float], horizon: int = 6,
                  alpha: float = 0.5, beta: float = 0.3
                  ) -> dict[str, list[float]]:
    """Additive Holt (level + trend) forecast with widening bands.
    Bands grow sqrt(h) — uncertainty compounds, and the output admits it."""
    values = _check(series)
    if horizon < 1:
        raise ValueError("horizon must be >= 1")
    level, trend = values[0], (values[1] - values[0]) if len(values) > 1 else 0.0
    errors = []
    for x in values[1:]:
        prev_level = level
        level = alpha * x + (1.0 - alpha) * (level + trend)
        trend = beta * (level - prev_level) + (1.0 - beta) * trend
        errors.append(abs(x - (prev_level + trend)))
    scale = (sum(errors) / len(errors)) if errors else 0.0
    # A perfect line has zero one-step error, but the future is never
    # perfect: floor the band at a hair of current level so bands exist
    # and widen with horizon even on noiseless input.
    scale = scale or max(1e-6 * abs(level), 1e-9)
    point = [level + h * trend for h in range(1, horizon + 1)]
    width = [2.0 * scale * math.sqrt(h) for h in range(1, horizon + 1)]
    return {"point": point,
            "lo": [p - w for p, w in zip(point, width)],
            "hi": [p + w for p, w in zip(point, width)]}


def _variance(values: list[float]) -> float:
    mu = sum(values) / len(values)
    return sum((x - mu) ** 2 for x in values) / len(values)


def _line_sse(values: list[float], lo: int, hi: int) -> float:
    """SSE of the least-squares line fit on values[lo:hi]."""
    n = hi - lo
    if n < 2:
        return 0.0
    xbar = (lo + hi - 1) / 2.0
    seg = values[lo:hi]
    ybar = sum(seg) / n
    denom = sum((i - xbar) ** 2 for i in range(lo, hi)) or 1.0
    slope = sum((i - xbar) * (y - ybar)
                for i, y in zip(range(lo, hi), seg)) / denom
    return sum((y - (ybar + slope * (i - xbar))) ** 2
               for i, y in zip(range(lo, hi), seg))


def changepoints(series: Sequence[float],
                 penalty: float = 0.0) -> list[int]:
    """PELT-lite: recursive binary segmentation with a BIC penalty
    (default log(n)). Answers "when did my line change" exactly instead of
    smearing it across a sliding window."""
    values = _check(series)
    # Split criterion is piecewise-LINEAR vs one line: a pure ramp is fit
    # perfectly by one line (no split), while steps and slope-changes are
    # not. Mean-based segmentation cannot tell a ramp from infinite steps.
    penalty = penalty or math.log(len(values)) * (_variance(values) or 1.0)
    found: list[int] = []

    def split(lo: int, hi: int) -> None:
        if hi - lo < 4:
            return
        base = _line_sse(values, lo, hi)
        best_gain, best_k = 0.0, -1
        for k in range(lo + 2, hi - 1):
            gain = (base - _line_sse(values, lo, k)
                    - _line_sse(values, k, hi))
            if gain > best_gain:
                best_gain, best_k = gain, k
        if best_k > 0 and best_gain > penalty:
            found.append(best_k)
            split(lo, best_k)
            split(best_k, hi)

    split(0, len(values))
    return sorted(found)


def summarize(series: Sequence[float], period: int = 0,
              horizon: int = 6) -> dict[str, object]:
    """The single entry analysers will call: distribution snapshot +
    changepoints + point/seasonal anomalies + forecast with bands.
    `kind`: 0.0 = point (MAD), 1.0 = seasonal-residual, 2.0 = level shift."""
    values = _check(series)
    w = Welford()
    for v in values:
        w.update(v)
    anomalies = flag_points(values)
    for hit in cusum(values):
        anomalies.append({"index": hit["index"], "kind": 2.0,
                          "score": hit["magnitude"]})
    if period >= 2 and len(values) >= 2 * period + 1:
        anomalies.extend(seasonal_anomalies(values, period))
    anomalies.sort(key=lambda a: float(a["index"]))
    return {"n": len(values), "mean": w.mean, "std": w.std,
            "min": min(values), "max": max(values),
            "changepoints": changepoints(values),
            "anomalies": anomalies,
            "forecast": holt_forecast(values, horizon)}


def sufficient(values: Sequence[float],
               minimum: int = 8) -> tuple[bool, str]:
    """Abstention gate (AI-076): is this series enough to reason from?

    Returns (ok, reason). Callers with ok=False must say "not enough data"
    instead of producing a verdict — silence beats confabulation.
    """
    try:
        series = _check(values)
    except ValueError as exc:
        return False, f"unusable series: {exc}"
    if len(series) < minimum:
        return False, (f"{len(series)} sample(s); {minimum} needed "
                       "for a verdict")
    return True, "sufficient"


def check_report(report: dict[str, Any]) -> list[str]:
    """Tripwires (AI-077) over a stats-bearing output: every violation is a
    string; [] means the report is internally consistent. Catches corrupted
    or hallucinated numbers before they reach a user, regardless of source.
    """
    violations: list[str] = []
    try:
        n = int(report.get("n", 0))
    except (TypeError, ValueError):
        return ["n is not an integer"]
    for cp in report.get("changepoints", []) or []:
        try:
            if not 0 <= int(cp) < n:
                violations.append(f"changepoint {cp} outside 0..{n - 1}")
        except (TypeError, ValueError):
            violations.append(f"changepoint {cp!r} is not an integer")
    for kind_name in ("anomalies",):
        for item in report.get(kind_name, []) or []:
            try:
                idx, score = float(item["index"]), float(item["score"])
            except (TypeError, ValueError, KeyError):
                violations.append(f"malformed anomaly entry {item!r}")
                continue
            if not 0 <= idx < n:
                violations.append(f"anomaly index {idx} outside 0..{n - 1}")
            if not math.isfinite(score) or score < 0:
                violations.append(f"anomaly score {score} is not sane")
    forecast = report.get("forecast") or {}
    for key in ("point", "lo", "hi"):
        vals = forecast.get(key, [])
        if not isinstance(vals, list) or not vals:
            violations.append(f"forecast.{key} missing or empty")
    points = forecast.get("point", [])
    los = forecast.get("lo", [])
    his = forecast.get("hi", [])
    if (isinstance(points, list) and isinstance(los, list)
            and isinstance(his, list) and points and los and his):
        if not (len(points) == len(los) == len(his)):
            violations.append("forecast bands misaligned with points")
        else:
            for p, lo, hi in zip(points, los, his):
                try:
                    if not (lo <= p <= hi):
                        violations.append(
                            f"forecast point {p} outside band [{lo}, {hi}]")
                    for v in (p, lo, hi):
                        if not math.isfinite(float(v)):
                            violations.append(
                                f"forecast value {v!r} is not finite")
                            break
                except TypeError:
                    violations.append("forecast values not numeric")
                    break
    return violations
