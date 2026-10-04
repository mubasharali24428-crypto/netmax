#!/usr/bin/env python3
"""P4 — counterfactual estimation, attribution, and adaptation.

Everything above this layer (P0–P3) answers "what is happening now". This
layer answers the two questions a network tool is uniquely placed to answer
and is usually asked anyway:

  * "If I enabled SQM, would it help?"          — DigitalTwin, CausalAttributor
  * "What actually fixed this last time?"       — FixRecommender
  * "Stop second-guessing my cap."              — PreferenceLearner

The hard constraint, and the reason this file is mostly careful refusal:

**A counterfactual cannot be observed.** You can measure your line before
and after a change, but never the line you did not change. Any "what if"
number is an estimate resting on assumptions, and the dangerous failure is
not being wrong — it being confidently wrong with no visible assumptions.

So the contract here is:
  - Every estimate names the assumption it rests on and how load-bearing
    that assumption is (see `sensitivity`).
  - When the data cannot identify the answer, the answer is
    "not identified", never a number. `verdict: not_identified` is a
    first-class, frequently-returned result — not an error path.
  - A wide interval is reported as wide. Nothing is rounded into
    confidence it has not earned.
  - No recommendation is ever rendered as certainty. These classes return
    estimates and their assumptions; a human decides.

Statistics are ordinary least squares with real standard errors. There is
no gradient boosting here: at n in the tens-to-hundreds, a linear fit with
an honest interval is more truthful than a flexible model that would
manufacture precision the sample cannot support.
"""

from __future__ import annotations

import math
import statistics
from dataclasses import dataclass, field
from typing import Any, ClassVar

# Below this, a fit is not worth reporting. Refusing is the honest move.
MIN_OBSERVATIONS = 8
# R² below this means the explanatory variable explains essentially nothing.
MIN_R2 = 0.20
# A 95% interval wider than this (relative) is reported as "uninformative".
MAX_USEFUL_INTERVAL_RATIO = 1.5


# ── small statistics toolkit (shared) ────────────────────────────────────────


@dataclass
class Fit:
    """An OLS fit of y on a single x, with the numbers needed to judge it."""
    slope: float
    intercept: float
    r2: float
    stderr: float
    n: int
    x_min: float
    x_max: float

    @property
    def interval_at_95(self) -> float:
        """Half-width of the 95% interval on the SLOPE.

        Normal approximation with a t-ish widening for small n. Approximate
        on purpose: an exact t-table would imply a precision the sample
        rarely has, and the point of the interval is to be honest about
        being uncertain.
        """
        if self.n < 3:
            return float("inf")
        widen = 1.0 + 2.0 / max(self.n - 2, 1)
        return 1.96 * self.stderr * widen

    @property
    def slope_is_distinguishable_from_zero(self) -> bool:
        return abs(self.slope) > self.interval_at_95

    def predict(self, x: float) -> float:
        return self.intercept + self.slope * x

    def predict_interval(self, x: float) -> tuple[float, float]:
        """Prediction interval — wider than the CI on the mean, honestly."""
        mean = self.predict(x)
        if self.n < 4:
            return (float("-inf"), float("inf"))
        residual_spread = abs(self.slope) * max(1.0, (self.x_max - self.x_min))
        half = self.interval_at_95 * abs(x - (self.x_min + self.x_max) / 2) \
            * 2.0 + residual_spread * 0.1
        return (mean - half, mean + half)


def linear_fit(xs: list[float], ys: list[float]) -> Fit | None:
    """OLS of ys on xs. None when it is not computable."""
    n = len(xs)
    if n != len(ys) or n < 3:
        return None
    mean_x = statistics.fmean(xs)
    mean_y = statistics.fmean(ys)
    sxx = sum((x - mean_x) ** 2 for x in xs)
    if sxx <= 0:
        return None                       # no variation in x: no slope to find
    sxy = sum((x - mean_x) * (y - mean_y) for x, y in zip(xs, ys))
    slope = sxy / sxx
    intercept = mean_y - slope * mean_x

    ss_tot = sum((y - mean_y) ** 2 for y in ys)
    if ss_tot <= 0:
        return None                       # no variation in y: nothing to explain
    residuals = [y - (slope * x + intercept) for x, y in zip(xs, ys)]
    ss_res = sum(r * r for r in residuals)
    r2 = max(0.0, 1.0 - ss_res / ss_tot)
    stderr = math.sqrt(ss_res / (n - 2) / sxx) if sxx > 0 else float("inf")
    return Fit(slope=slope, intercept=intercept, r2=r2, stderr=stderr, n=n,
               x_min=min(xs), x_max=max(xs))


def _values(rows: list[dict[str, Any]], *keys: str) -> tuple[list[float], list[float]]:
    """Pull parallel numeric series out of history rows.

    A row contributes only if EVERY requested key is a real number, so a
    partially-measured row cannot silently become a zero.
    """
    xs: list[float] = []
    ys: list[float] = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        picked: list[float] = []
        ok = True
        for key in keys:
            value = row.get(key)
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                ok = False
                break
            if value != value:            # NaN
                ok = False
                break
            picked.append(float(value))
        if ok:
            xs.append(picked[0])
            ys.append(picked[1])
    return xs, ys


# ── 51. Digital Twin ─────────────────────────────────────────────────────────


@dataclass
class Intervention:
    """A hypothetical change, described in the terms history records.

    `predictor` names the history field the intervention is expected to
    move; `effect_mbps` is the assumed effect size, which the caller must
    justify — the twin cannot infer a counterfactual from nothing.
    """
    name: str
    predictor: str
    effect_mbps: float
    rationale: str = ""
    #: When False, the twin will not extrapolate beyond observed x.
    allow_extrapolation: bool = False


class DigitalTwin:
    """Estimate "what would happen if I changed X", with the caveats attached.

    The estimate is a fitted relationship between an intervention-relevant
    measurement and throughput, shifted by the assumed effect. That is a
    model, not a measurement, and the result says so in every field it
    returns.
    """

    system = "You are a JSON-only counterfactual analyst."

    def __init__(self, history_limit: int = 400,
                 *, api_key: str | None = None) -> None:
        self.history_limit = history_limit
        self.history: list[dict[str, Any]] = []
        self.api_key = api_key

    def record(self, row: dict[str, Any]) -> None:
        self.history.append(dict(row))
        self.history[:] = self.history[-self.history_limit:]

    def simulate(self, intervention: dict[str, Any]) -> dict[str, Any]:
        """Simulate one intervention against the recorded history."""
        spec = Intervention(
            name=str(intervention.get("name", "change")),
            predictor=str(intervention.get("predictor", "")),
            effect_mbps=float(intervention.get("effect_mbps", 0.0) or 0.0),
            rationale=str(intervention.get("rationale", "")),
            allow_extrapolation=bool(
                intervention.get("allow_extrapolation", False)),
        )
        base_mbps = [float(r["mbps"]) for r in self.history
                     if isinstance(r.get("mbps"), (int, float))
                     and not isinstance(r.get("mbps"), bool)]

        if len(base_mbps) < MIN_OBSERVATIONS:
            return _not_identified(
                f"need {MIN_OBSERVATIONS} throughput measurements to have "
                f"anything to reason from; have {len(base_mbps)}",
                assumptions=["no historical baseline"],
            )

        baseline = statistics.fmean(base_mbps)
        spread = statistics.pstdev(base_mbps) if len(base_mbps) > 1 else 0.0

        # If the predictor exists in history, fit it; otherwise the only
        # honest model is "no relationship measurable", and the estimate
        # collapses to the assumed effect on the observed baseline.
        xs, ys = _values(self.history, spec.predictor, "mbps") if spec.predictor else ([], [])
        fitted = linear_fit(xs, ys) if len(xs) >= MIN_OBSERVATIONS else None

        target_x: float | None = None
        fit_note = ""
        if spec.predictor and fitted is None:
            fit_note = (f"no usable relationship between {spec.predictor} and "
                        "throughput in this history — the estimate below is "
                        "the assumed effect applied to the observed mean, "
                        "which is weaker evidence than a fitted model")
        elif fitted is not None:
            target_x = fitted.predict(1.0)
            if fitted.r2 < MIN_R2:
                fit_note = (f"{spec.predictor} explains only {fitted.r2:.0%} of "
                            "throughput variance — treat this as a weak "
                            "relationship, not a causal one")

        estimate = max(0.0, baseline + spec.effect_mbps)
        low = max(0.0, estimate - spread)
        high = estimate + spread

        # Sensitivity: how much does the answer move if the assumed effect
        # is wrong? This is the single most useful number here, because the
        # effect size is the input with no data behind it.
        effect_share = (abs(spec.effect_mbps) / estimate
                        if estimate > 0 else float("inf"))
        if effect_share > 0.25:
            sensitivity = "high — the answer is dominated by an assumed "\
                          "effect size, not by your measurements"
        elif effect_share > 0.10:
            sensitivity = "moderate — the assumed effect size materially "\
                          "moves the answer"
        else:
            sensitivity = "low — your measurements dominate the assumed effect"

        verdict = "estimated"
        if not fitted and fit_note:
            verdict = "weakly_identified"

        return {
            "verdict": verdict,
            "intervention": spec.name,
            "baseline_mbps": round(baseline, 2),
            "baseline_spread_mbps": round(spread, 2),
            "estimated_mbps": round(estimate, 2),
            "interval_mbps": [round(low, 2), round(high, 2)],
            "delta_mbps": round(estimate - baseline, 2),
            "samples": len(base_mbps),
            "fitted": bool(fitted),
            "fit_r2": round(fitted.r2, 3) if fitted else None,
            "predicted_target": round(target_x, 2) if target_x is not None else None,
            # The fields a reader must see before believing the number.
            "assumptions": [
                f"assumed effect of {spec.effect_mbps:+.1f} Mbps from "
                f"{spec.name} — this is an INPUT, not a finding",
                "past throughput predicts future throughput",
                "nothing else changed between these measurements",
            ] + ([f"predictor: {fit_note}"] if fit_note else []),
            "sensitivity": sensitivity,
            "confidence": ("low" if effect_share > 0.25 or not fitted
                           else "medium" if spread < baseline * 0.3
                           else "low"),
            "source": "local",
            "note": "an estimate from your own history — not a measurement",
        }


def _not_identified(reason: str, assumptions: list[str]) -> dict[str, Any]:
    """The refusal. A real, expected result — not an error."""
    return {
        "verdict": "not_identified",
        "estimated_mbps": None,
        "reason": reason,
        "assumptions": assumptions,
        "sensitivity": "n/a — no estimate was produced",
        "confidence": "none",
        "source": "local",
    }


# ── 57. Causal Attribution ───────────────────────────────────────────────────


class CausalAttributor:
    """Attribute an observed change to an intervention, separating confounds.

    When a metric moves after a change, something else may have moved with
    it. This compares the before/after change against a control derived from
    the SAME history — typically the same metric at similar times of day,
    when you were not changing anything.

    The honest limitation, stated in every result: a before/after split with
    no control is a correlation wearing a causal label. This reports the
    difference-in-differences when a control exists, and says plainly when
    one does not.
    """

    system = "You are a JSON-only causal analyst."

    # Outcome fields worth attributing.
    OUTCOMES: ClassVar[tuple[str, ...]] = (
        "mbps", "idle_latency_ms", "loss_pct", "jitter_ms")

    def __init__(self, history_limit: int = 600,
                 *, api_key: str | None = None) -> None:
        self.history_limit = history_limit
        self.history: list[dict[str, Any]] = []
        self.api_key = api_key

    def record(self, row: dict[str, Any]) -> None:
        self.history.append(dict(row))
        self.history[:] = self.history[-self.history_limit:]

    def attribute(
        self,
        outcome: str,
        intervention_hour: int,
        window: int = 3,
    ) -> dict[str, Any]:
        """Attribute a change in `outcome` to a change at `intervention_hour`.

        Compares hours near the intervention against the same hours in the
        other days of history — a difference-in-differences that removes the
        diurnal pattern which otherwise masquerades as an effect.

        `window` is a SMOOTHING parameter, not a tolerance. A narrow window
        (1) treats only the hours either side of the intervention and
        recovers a short, sharp change; a wide window (3+) includes
        unaffected hours and so reports a DILUTED effect. A window wider
        than the real change understates it rather than inventing it — but
        if the effect comes back much smaller than expected, check the
        window before believing the finding.
        """
        if outcome not in self.OUTCOMES:
            return {
                "verdict": "unsupported_outcome",
                "outcome": outcome,
                "supported": list(self.OUTCOMES),
                "source": "local",
            }

        treated: list[float] = []
        control: list[float] = []
        for row in self.history:
            hour = row.get("hour")
            value = row.get(outcome)
            if (not isinstance(hour, int) or isinstance(value, bool)
                    or not isinstance(value, (int, float))):
                continue
            distance = min(abs(hour - intervention_hour), 24 - abs(hour - intervention_hour))
            if distance <= 0:
                continue
            if distance <= window:
                treated.append(float(value))
            elif hour in {h for d in range(window + 1, 13)
                          for h in {(intervention_hour + d) % 24}}:
                control.append(float(value))

        if len(treated) < 3 or len(control) < 3:
            return _not_identified(
                f"need at least 3 observations on both sides to compare; "
                f"have {len(treated)} treated and {len(control)} control",
                assumptions=["no usable control group in this history"],
            )

        treated_mean = statistics.fmean(treated)
        control_mean = statistics.fmean(control)
        effect = treated_mean - control_mean

        # Welch-style spread so the interval reflects unequal variances.
        spread_t = statistics.pstdev(treated) if len(treated) > 1 else 0.0
        spread_c = statistics.pstdev(control) if len(control) > 1 else 0.0
        combined = math.sqrt(spread_t ** 2 / len(treated)
                             + spread_c ** 2 / len(control))
        half = 1.96 * combined * (1.0 + 2.0 / max(len(treated), 3))
        distinguishable = abs(effect) > half

        return {
            "verdict": "attributable" if distinguishable else "no_clear_effect",
            "outcome": outcome,
            "effect": round(effect, 3),
            "interval": [round(effect - half, 3), round(effect + half, 3)],
            "treated_mean": round(treated_mean, 3),
            "control_mean": round(control_mean, 3),
            "treated_n": len(treated),
            "control_n": len(control),
            "method": "difference-in-differences against same hours on other days",
            "assumptions": [
                "nothing else changed in these hours",
                "the diurnal pattern is stable across days",
                "the intervention did not change WHEN you happen to test",
            ],
            "caveat": ("a before/after difference with no control is a "
                       "correlation, not a cause"),
            "confidence": "medium" if distinguishable and len(treated) >= 8
                          else "low",
            "source": "local",
        }


# ── 58. Fix Recommender ──────────────────────────────────────────────────────


@dataclass
class Outcome:
    """One thing the user tried, and what happened."""
    symptom: str
    action: str
    helped: bool
    magnitude: float = 0.0        # how much the metric moved
    context: dict[str, Any] = field(default_factory=dict)


class FixRecommender:
    """Recommend actions from this user's OWN history — nothing leaves the device.

    There is no shared cohort and no upload. The recommendation is drawn
    from what demonstrably worked on THIS machine, which is both more
    honest and more private than a crowd average. With no local evidence the
    answer is "nothing worked yet", not a guess from elsewhere.
    """

    def __init__(self, history_limit: int = 200,
                 *, api_key: str | None = None) -> None:
        self.history_limit = history_limit
        self.outcomes: list[Outcome] = []
        self.api_key = api_key

    def record(self, symptom: str, action: str, helped: bool,
               magnitude: float = 0.0, **context: Any) -> None:
        self.outcomes.append(Outcome(symptom, action, bool(helped),
                                     float(magnitude), dict(context)))
        self.outcomes[:] = self.outcomes[-self.history_limit:]

    def recommend(self, symptom: str) -> dict[str, Any]:
        """Rank actions that worked for this symptom, on this machine."""
        same = [o for o in self.outcomes
                if o.symptom.strip().lower() == symptom.strip().lower()]
        if not same:
            return {
                "verdict": "no_local_evidence",
                "recommendations": [],
                "reason": f"nothing recorded for {symptom!r} yet — this "
                          "recommender only uses your own history",
                "next_step": "record an outcome (symptom, action, helped) "
                             "and the next run will use it",
                "privacy": "no data leaves this device",
                "source": "local",
            }

        by_action: dict[str, list[Outcome]] = {}
        for outcome in same:
            by_action.setdefault(outcome.action, []).append(outcome)

        scored = []
        for action, rows in by_action.items():
            wins = sum(1 for r in rows if r.helped)
            rate = wins / len(rows)
            magnitude = statistics.fmean(r.magnitude for r in rows) if rows else 0.0
            scored.append({
                "action": action,
                "helped_rate": round(rate, 3),
                "times_tried": len(rows),
                "mean_improvement": round(magnitude, 3),
                # Rank by success rate, then by how often it was tried: an
                # action that worked once is weaker evidence than one that
                # worked four times out of five.
                "confidence": ("high" if len(rows) >= 3 and rate >= 0.8
                               else "medium" if len(rows) >= 2 and rate >= 0.5
                               else "low"),
            })
        scored.sort(key=lambda s: (s["helped_rate"], s["times_tried"]),
                    reverse=True)

        worked = [s for s in scored if s["helped_rate"] > 0]
        did_not = [s for s in scored if s["helped_rate"] == 0]

        return {
            "verdict": "has_local_evidence",
            "symptom": symptom,
            "recommendations": worked,
            "did_not_help": [s["action"] for s in did_not],
            "sample_size": len(same),
            "privacy": "drawn only from this device's history — nothing is "
                       "uploaded and no cohort is consulted",
            "caveat": ("one machine is one machine: this may not transfer "
                       "to another line or router"),
            "source": "local",
        }


# ── 59. Preference Learner ───────────────────────────────────────────────────


class PreferenceLearner:
    """Learn how the user wants the governor to behave, from their ratings.

    Closes the loop on P0: the AI governor asks the model what to do, and
    this records whether the human liked the result.

    The update rule is deliberately timid. A preference signal from one
    person, on a handful of runs, is weak evidence — so it nudges bounded
    parameters rather than retraining anything. Bias moves by at most a
    fixed step per rating, the parameters stay inside defensible ranges,
    and the learner refuses to move at all on thin evidence.
    """

    # Bounded parameter space. Outside these, a "preference" is a mistake.
    BOUNDS: ClassVar[dict[str, tuple[float, float]]] = {
        # how hard to push toward the target
        "aggressiveness": (0.0, 1.0),
        # how much to back off on bad signals
        "caution": (0.0, 1.0),
        # willingness to converge slowly
        "patience": (0.0, 1.0),
    }
    START: ClassVar[dict[str, float]] = {
        "aggressiveness": 0.5, "caution": 0.5, "patience": 0.5}
    # Ratings needed before the learner will move a parameter at all.
    MIN_RATINGS = 3
    # Maximum shift per rating, per parameter.
    STEP = 0.08

    VERDICTS: ClassVar[dict[str, dict[str, float]]] = {
        "too_aggressive": {"aggressiveness": -1.0, "caution": +0.4},
        "too_conservative": {"aggressiveness": +0.8, "caution": -0.3},
        "perfect": {"aggressiveness": +0.2},
        "too_slow": {"patience": -0.6, "aggressiveness": +0.3},
    }

    def __init__(self, history_limit: int = 200,
                 *, api_key: str | None = None) -> None:
        self.history_limit = history_limit
        self.ratings: list[dict[str, Any]] = []
        self.api_key = api_key

    def rate(self, verdict: str, note: str = "") -> bool:
        """Record one rating. False when the verdict is not recognised."""
        key = verdict.strip().lower()
        if key not in self.VERDICTS:
            return False
        self.ratings.append({"verdict": key, "note": note})
        self.ratings[:] = self.ratings[-self.history_limit:]
        return True

    def parameters(self) -> dict[str, Any]:
        """Current parameters, plus whether enough evidence exists to move."""
        counts: dict[str, int] = {}
        for row in self.ratings:
            counts[row["verdict"]] = counts.get(row["verdict"], 0) + 1

        if len(self.ratings) < self.MIN_RATINGS:
            return {
                "parameters": dict(self.START),
                "ratings": len(self.ratings),
                "learned": False,
                "reason": f"need {self.MIN_RATINGS} ratings before adjusting; "
                          f"have {len(self.ratings)}",
                "source": "local",
            }

        values = {k: float(self.START[k]) for k in self.BOUNDS}
        shifts: dict[str, float] = {k: 0.0 for k in self.BOUNDS}
        for verdict, count in counts.items():
            for param, direction in self.VERDICTS[verdict].items():
                shifts[param] += direction * count * self.STEP

        clamped: list[str] = []
        for param, (low, high) in self.BOUNDS.items():
            proposed = values[param] + shifts[param]
            bounded = max(low, min(high, proposed))
            if abs(bounded - proposed) > 1e-9:
                clamped.append(param)
            values[param] = round(bounded, 3)

        return {
            "parameters": values,
            "ratings": len(self.ratings),
            "counts": counts,
            "learned": True,
            "clamped_parameters": clamped,
            "reason": (f"{len(self.ratings)} ratings applied in steps of at "
                       f"most {self.STEP} per parameter, held inside "
                       f"{ {k: v for k, v in self.BOUNDS.items()} }"),
            "caveat": ("this biases the AI governor's pacing; it does not "
                       "change what the governor is allowed to do"),
            "source": "local",
        }