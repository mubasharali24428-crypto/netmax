"""Tests for P4 — counterfactual estimation, attribution, and adaptation.

The property that matters most in this layer is REFUSAL. A counterfactual
cannot be observed, so the tool's job is to say "not identified" far more
often than a naive implementation would, and to attach its assumptions to
every number it does produce. Most tests below are about that.
"""

from __future__ import annotations

import random

import pytest

from netmax_ai_p4 import (
    CausalAttributor,
    DigitalTwin,
    FixRecommender,
    PreferenceLearner,
    _not_identified,
    linear_fit,
)


def _history(n=40, seed=11, slope=-0.8, base=90.0):
    """Throughput that genuinely depends on latency, plus noise."""
    rng = random.Random(seed)
    return [{"idle_latency_ms": 10 + i * 0.5,
             "mbps": base + slope * (10 + i * 0.5) + rng.uniform(-2, 2)}
            for i in range(n)]


# ── linear_fit ───────────────────────────────────────────────────────────────


class TestLinearFit:
    def test_recovers_a_known_line(self):
        xs = [float(i) for i in range(20)]
        ys = [3.0 + 2.0 * x for x in xs]
        fit = linear_fit(xs, ys)
        assert fit is not None
        assert fit.slope == pytest.approx(2.0)
        assert fit.r2 == pytest.approx(1.0)

    def test_refuses_on_too_few_points(self):
        assert linear_fit([1.0], [1.0]) is None
        assert linear_fit([1.0, 2.0], [1.0, 2.0]) is None

    def test_refuses_when_x_has_no_variation(self):
        """No variation in x means there is no slope to find."""
        assert linear_fit([2.0] * 10, [float(i) for i in range(10)]) is None

    def test_refuses_when_y_has_no_variation(self):
        assert linear_fit([float(i) for i in range(10)], [5.0] * 10) is None

    def test_low_r2_is_reported_not_hidden(self):
        rng = random.Random(5)
        xs = [float(i) for i in range(30)]
        ys = [rng.uniform(0, 100) for _ in range(30)]
        fit = linear_fit(xs, ys)
        assert fit is not None and fit.r2 < 0.2

    def test_mismatched_lengths_refuse(self):
        assert linear_fit([1.0, 2.0], [1.0]) is None


# ── 51. DigitalTwin ──────────────────────────────────────────────────────────


class TestTwinRefuses:
    def test_no_history_is_not_identified(self):
        out = DigitalTwin().simulate({"name": "SQM", "effect_mbps": -30})
        assert out["verdict"] == "not_identified"
        assert out["estimated_mbps"] is None
        assert out["confidence"] == "none"

    def test_thin_history_is_not_identified(self):
        twin = DigitalTwin()
        for row in _history(4):
            twin.record(row)
        assert twin.simulate({"name": "x", "effect_mbps": -5})["verdict"] == \
            "not_identified"

    def test_refusal_carries_a_reason_and_assumptions(self):
        out = DigitalTwin().simulate({"name": "x", "effect_mbps": -5})
        assert out["reason"]
        assert out["assumptions"]
        assert out["sensitivity"].startswith("n/a")


class TestTwinEstimates:
    def _twin(self):
        twin = DigitalTwin()
        for row in _history():
            twin.record(row)
        return twin

    def test_produces_an_estimate_with_history(self):
        out = self._twin().simulate({"name": "x", "effect_mbps": -5})
        assert out["verdict"] == "estimated"
        assert out["estimated_mbps"] > 0
        assert out["samples"] == 40

    def test_every_estimate_names_its_assumptions(self):
        out = self._twin().simulate({"name": "SQM", "effect_mbps": -30})
        joined = " ".join(out["assumptions"])
        assert "INPUT, not a finding" in joined
        assert "nothing else changed" in joined

    def test_high_assumed_effect_is_flagged_as_sensitive(self):
        """A large guess on a small baseline must not look authoritative."""
        out = self._twin().simulate({"name": "big", "effect_mbps": -200})
        assert out["sensitivity"].startswith("high")
        assert out["confidence"] == "low"

    def test_small_effect_on_a_big_baseline_is_low_sensitivity(self):
        out = self._twin().simulate({"name": "small", "effect_mbps": -1})
        assert out["sensitivity"].startswith("low")

    def test_interval_brackets_the_estimate(self):
        out = self._twin().simulate({"name": "x", "effect_mbps": -5})
        low, high = out["interval_mbps"]
        assert low <= out["estimated_mbps"] <= high

    def test_estimate_is_never_negative(self):
        out = self._twin().simulate({"name": "x", "effect_mbps": -100000})
        assert out["estimated_mbps"] >= 0

    def test_finds_the_real_relationship(self):
        out = self._twin().simulate(
            {"name": "x", "predictor": "idle_latency_ms", "effect_mbps": -1})
        assert out["fitted"] is True
        assert out["fit_r2"] > 0.5

    def test_unmodelled_predictor_is_weakly_identified(self):
        """A predictor with no relationship must not masquerade as fitted."""
        out = self._twin().simulate(
            {"name": "x", "predictor": "nonexistent_field", "effect_mbps": -5})
        assert out["fitted"] is False
        assert out["verdict"] == "weakly_identified"
        assert any("weaker evidence" in a for a in out["assumptions"])

    def test_never_renders_as_certainty(self):
        out = self._twin().simulate({"name": "x", "effect_mbps": -5})
        assert "not a measurement" in out["note"]
        assert out["confidence"] in {"low", "medium", "high"}

    def test_boolean_mbps_is_not_treated_as_data(self):
        twin = DigitalTwin()
        for row in _history(40):
            twin.record(row)
        for _ in range(10):
            twin.record({"mbps": True, "idle_latency_ms": 5})
        assert twin.simulate({"name": "x", "effect_mbps": -1})["samples"] == 40


# ── 57. CausalAttributor ─────────────────────────────────────────────────────


def _causal_history(effect_ms=0.0, days=14, seed=3):
    rng = random.Random(seed)
    rows = []
    for day in range(days):
        for hour in range(24):
            value = 20 + rng.uniform(-1, 1)
            if hour in (10, 11, 12):
                value -= effect_ms
            rows.append({"hour": hour, "day": day,
                         "idle_latency_ms": value})
    return rows


class TestAttribution:
    def test_finds_a_real_effect(self):
        attr = CausalAttributor()
        for row in _causal_history(effect_ms=6.0):
            attr.record(row)
        out = attr.attribute("idle_latency_ms", 11, window=1)
        assert out["verdict"] == "attributable"
        assert out["effect"] == pytest.approx(-6.0, abs=1.0)
        assert out["interval"][0] < out["effect"] < out["interval"][1]

    def test_reports_no_clear_effect_on_noise(self):
        attr = CausalAttributor()
        for row in _causal_history(effect_ms=0.0):
            attr.record(row)
        out = attr.attribute("idle_latency_ms", 11, window=1)
        assert out["verdict"] == "no_clear_effect"
        assert out["interval"][0] <= 0 <= out["interval"][1]

    def test_wide_window_dilutes_rather_than_invents(self):
        attr = CausalAttributor()
        for row in _causal_history(effect_ms=6.0):
            attr.record(row)
        narrow = attr.attribute("idle_latency_ms", 11, window=1)["effect"]
        wide = attr.attribute("idle_latency_ms", 11, window=3)["effect"]
        assert abs(wide) < abs(narrow)

    def test_thin_history_refuses(self):
        attr = CausalAttributor()
        attr.record({"hour": 11, "idle_latency_ms": 10})
        assert attr.attribute("idle_latency_ms", 11)["verdict"] == \
            "not_identified"

    def test_unsupported_outcome_names_what_is_supported(self):
        attr = CausalAttributor()
        for row in _causal_history():
            attr.record(row)
        out = attr.attribute("telemetry_packets", 11)
        assert out["verdict"] == "unsupported_outcome"
        assert "mbps" in out["supported"]

    def test_always_states_the_causal_limitation(self):
        attr = CausalAttributor()
        for row in _causal_history(effect_ms=6.0):
            attr.record(row)
        out = attr.attribute("idle_latency_ms", 11, window=1)
        assert "correlation" in out["caveat"]
        assert out["method"]

    def test_control_group_exists_and_is_larger(self):
        attr = CausalAttributor()
        for row in _causal_history(effect_ms=6.0):
            attr.record(row)
        out = attr.attribute("idle_latency_ms", 11, window=1)
        assert out["control_n"] >= out["treated_n"]

    def test_non_numeric_values_are_skipped(self):
        attr = CausalAttributor()
        for row in _causal_history(effect_ms=6.0):
            attr.record(row)
        for _ in range(20):
            attr.record({"hour": 11, "idle_latency_ms": "fast"})
        out = attr.attribute("idle_latency_ms", 11, window=1)
        assert out["verdict"] == "attributable"


# ── 58. FixRecommender ───────────────────────────────────────────────────────


class TestRecommender:
    def test_no_evidence_says_so(self):
        out = FixRecommender().recommend("bufferbloat")
        assert out["verdict"] == "no_local_evidence"
        assert out["recommendations"] == []
        assert "nothing is uploaded" in out["privacy"] or \
            "no data leaves" in out["privacy"].lower()

    def test_ranks_by_success_then_evidence(self):
        rec = FixRecommender()
        for _ in range(4):
            rec.record("bloat", "enable SQM", True, 42.0)
        rec.record("bloat", "raise MTU", True, 30.0)
        out = rec.recommend("bloat")
        assert out["recommendations"][0]["action"] == "enable SQM"
        assert out["recommendations"][0]["confidence"] == "high"
        assert out["recommendations"][1]["confidence"] == "low"

    def test_keeps_failures_visible(self):
        rec = FixRecommender()
        rec.record("bloat", "enable SQM", True, 42.0)
        rec.record("bloat", "raise MTU", False, 0.0)
        out = rec.recommend("bloat")
        assert out["did_not_help"] == ["raise MTU"]

    def test_symptom_match_is_case_insensitive(self):
        rec = FixRecommender()
        rec.record("Bufferbloat", "enable SQM", True, 42.0)
        assert rec.recommend("bufferbloat")["verdict"] == "has_local_evidence"

    def test_different_symptoms_do_not_mix(self):
        rec = FixRecommender()
        rec.record("bloat", "enable SQM", True, 42.0)
        assert rec.recommend("loss")["verdict"] == "no_local_evidence"

    def test_privacy_claim_is_stated_on_every_result(self):
        rec = FixRecommender()
        rec.record("bloat", "enable SQM", True, 42.0)
        assert rec.recommend("bloat")["privacy"]

    def test_carries_the_single_machine_caveat(self):
        rec = FixRecommender()
        rec.record("bloat", "enable SQM", True, 42.0)
        assert "one machine" in rec.recommend("bloat")["caveat"]


# ── 59. PreferenceLearner ────────────────────────────────────────────────────


class TestPreferenceLearner:
    def test_refuses_before_minimum_ratings(self):
        pl = PreferenceLearner()
        pl.rate("too_aggressive")
        out = pl.parameters()
        assert out["learned"] is False
        assert out["parameters"] == PreferenceLearner.START

    def test_rejects_unknown_verdicts(self):
        pl = PreferenceLearner()
        assert pl.rate("perfect") is True
        assert pl.rate("excellent") is False

    def test_moves_after_enough_ratings(self):
        pl = PreferenceLearner()
        for _ in range(3):
            pl.rate("too_aggressive")
        out = pl.parameters()
        assert out["learned"] is True
        assert out["parameters"]["aggressiveness"] < \
            PreferenceLearner.START["aggressiveness"]

    def test_runaway_ratings_stay_in_bounds(self):
        pl = PreferenceLearner()
        for _ in range(300):
            pl.rate("too_conservative")
        params = pl.parameters()["parameters"]
        for name, (low, high) in PreferenceLearner.BOUNDS.items():
            assert low <= params[name] <= high, name
        assert pl.parameters()["clamped_parameters"]

    def test_runaway_the_other_way_stays_in_bounds(self):
        pl = PreferenceLearner()
        for _ in range(300):
            pl.rate("too_aggressive")
        params = pl.parameters()["parameters"]
        for name, (low, high) in PreferenceLearner.BOUNDS.items():
            assert low <= params[name] <= high, name

    def test_step_is_bounded_per_rating(self):
        """A single rating must not swing a parameter across its range."""
        pl = PreferenceLearner()
        for _ in range(PreferenceLearner.MIN_RATINGS):
            pl.rate("too_conservative")
        shift = abs(pl.parameters()["parameters"]["aggressiveness"]
                    - PreferenceLearner.START["aggressiveness"])
        assert shift <= PreferenceLearner.STEP * PreferenceLearner.MIN_RATINGS + 1e-9

    def test_states_it_only_biases_pacing(self):
        pl = PreferenceLearner()
        for _ in range(3):
            pl.rate("perfect")
        assert "does not change what the governor is allowed to do" in \
            pl.parameters()["caveat"]


# ── the refusal helper ──────────────────────────────────────────────────────


def test_not_identified_helper_is_a_normal_result():
    out = _not_identified("because", ["an assumption"])
    assert out["verdict"] == "not_identified"
    assert out["estimated_mbps"] is None
    assert out["confidence"] == "none"
