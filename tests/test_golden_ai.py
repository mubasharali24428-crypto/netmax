"""Golden set, v1: 30 labeled cases over the local (no-key) paths.

Every case pins behavior that must survive refactors: verdicts, abstention,
and tripwire-clean outputs. Model-backed paths are out of scope — goldens
must run offline, deterministically, in milliseconds.
"""

from __future__ import annotations

import netmax_stats as stats
from netmax_ai_p1 import RootCauseClassifier
from netmax_ai_p2 import ResultExplainer, TrendForecaster


def _forecaster(values: list[float]) -> TrendForecaster:
    f = TrendForecaster(api_key="")
    for v in values:
        f.record_sample(v)
    return f


# ── forecast goldens (10) ──────────────────────────────────────────────

def test_g01_insufficient_data_abstains():
    out = _forecaster([40.0, 41.0, 39.0]).forecast()
    assert out["trend"] == "insufficient_data"
    assert out["forecast_mbps"] is None
    assert out["confidence"] == "none"


def test_g02_flat_verdict_on_noise():
    out = _forecaster([50, 52, 48, 51, 49, 50, 52, 48]).forecast()
    assert out["trend"] == "flat"


def test_g03_declining_verdict():
    out = _forecaster([float(100 - 2 * i) for i in range(12)]).forecast()
    assert out["trend"] == "declining"


def test_g04_improving_verdict():
    out = _forecaster([float(20 + 3 * i) for i in range(12)]).forecast()
    assert out["trend"] == "improving"


def test_g05_forecast_positive_and_bounded():
    out = _forecaster([float(40 + i) for i in range(16)]).forecast()
    assert out["forecast_mbps"] is not None and out["forecast_mbps"] >= 0


def test_g06_horizon_clamped():
    out = _forecaster([float(40 + i) for i in range(16)]).forecast(
        horizon_days=500)
    assert out["horizon_days"] == 90


def test_g07_high_confidence_with_history():
    out = _forecaster([50.0] * 30).forecast()
    assert out["confidence"] == "high"


def test_g08_medium_confidence_when_young():
    out = _forecaster([50.0] * 10).forecast()
    assert out["confidence"] == "medium"


def test_g09_step_visible_in_changepoints():
    out = _forecaster([60.0] * 10 + [30.0] * 10).forecast()
    assert len(out["changepoints"]) == 1


def test_g10_report_passes_tripwires():
    out = _forecaster([float(45 + (i % 5)) for i in range(20)]).forecast()
    rep = {"n": out["samples"], "changepoints": out["changepoints"],
           "anomalies": [], "forecast": out["holt"]}
    assert stats.check_report(rep) == []


# ── classify goldens (10) ─────────────────────────────────────────────

def test_g11_dead_link_critical_first():
    out = RootCauseClassifier(api_key="").classify({"mbps": 0.0})
    assert out["causes"][0]["cause"] == "dead_link"
    assert out["causes"][0]["severity"] == "critical"


def test_g12_clean_bill_has_no_causes():
    out = RootCauseClassifier(api_key="").classify(
        {"mbps": 200.0, "loss_pct": 0.0, "jitter_ms": 5.0})
    assert out["causes"] == []
    assert out["source"] == "local"


def test_g13_severe_loss_detected():
    out = RootCauseClassifier(api_key="").classify(
        {"mbps": 50.0, "loss_pct": 8.0})
    assert any(c["cause"] == "severe_loss" for c in out["causes"])


def test_g14_bufferbloat_graded():
    out = RootCauseClassifier(api_key="").classify(
        {"mbps": 50.0, "bloat_grade": "D", "bloat_delta_ms": 290})
    assert any(c["cause"] == "bufferbloat" for c in out["causes"])


def test_g15_poor_wifi_on_weak_rssi():
    out = RootCauseClassifier(api_key="").classify(
        {"mbps": 50.0, "rssi": -82})
    assert any(c["cause"] == "poor_wifi" for c in out["causes"])


def test_g16_high_jitter_flagged():
    out = RootCauseClassifier(api_key="").classify(
        {"mbps": 50.0, "jitter_ms": 60.0})
    assert any(c["cause"] == "high_jitter" for c in out["causes"])


def test_g17_under_target_needs_plan():
    out = RootCauseClassifier(api_key="").classify(
        {"mbps": 50.0, "target_mbps": 500.0})
    assert any(c["cause"] == "under_target" for c in out["causes"])


def test_g18_no_plan_no_under_target_claim():
    out = RootCauseClassifier(api_key="").classify({"mbps": 50.0})
    assert not any(c["cause"] == "under_target" for c in out["causes"])


def test_g19_trend_context_rides_along():
    out = RootCauseClassifier(api_key="").classify(
        {"mbps": 25.0}, trend_mbps=[50.0] * 10 + [25.0] * 10)
    assert out["trend_context"]["n"] == 20
    assert len(out["trend_context"]["changepoints"]) == 1


def test_g20_severity_ordering():
    out = RootCauseClassifier(api_key="").classify(
        {"mbps": 0.0, "jitter_ms": 60.0})
    severities = [c["severity"] for c in out["causes"]]
    assert severities[0] == "critical"


# ── explain goldens (10) ─────────────────────────────────────────────

def test_g21_headline_names_wall_clock():
    out = ResultExplainer(api_key="").explain({"mbps": 42.0})
    assert "42 Mbps" in out["headline"]


def test_g22_no_throughput_no_timing_claim():
    out = ResultExplainer(api_key="").explain({"mbps": 0.0})
    assert out["headline"] == "no usable measurement"
    assert any("no throughput" in c for c in out["caveats"])


def test_g23_plan_ratio_only_with_plan():
    with_plan = ResultExplainer(api_key="").explain(
        {"mbps": 100.0}, plan_mbps=500.0)
    without_plan = ResultExplainer(api_key="").explain({"mbps": 100.0})
    assert any("20%" in s for s in with_plan["statements"])
    assert not any("%" in s for s in without_plan["statements"])


def test_g24_bad_bloat_grade_warns():
    out = ResultExplainer(api_key="").explain(
        {"mbps": 50.0, "bloat_grade": "F"})
    assert any("bufferbloat" in c for c in out["caveats"])


def test_g25_good_bloat_grade_reassures():
    out = ResultExplainer(api_key="").explain(
        {"mbps": 50.0, "bloat_grade": "A"})
    assert any("responsive" in s for s in out["statements"])


def test_g26_high_jitter_warns_calls():
    out = ResultExplainer(api_key="").explain(
        {"mbps": 50.0, "jitter_ms": 45.0})
    assert any("jitter" in c for c in out["caveats"])


def test_g27_trend_statement_with_range():
    out = ResultExplainer(api_key="").explain(
        {"mbps": 42.0}, trend_mbps=[float(38 + i) for i in range(10)])
    assert any("trend points to" in s and "range" in s
               for s in out["statements"])


def test_g28_unknown_tone_falls_back_to_plain():
    out = ResultExplainer(api_key="").explain({"mbps": 42.0}, tone="pirate")
    assert out["tone"] == "plain"


def test_g29_sufficient_gate():
    ok, _ = stats.sufficient([50.0] * 10)
    assert ok is True
    ok, reason = stats.sufficient([50.0] * 3)
    assert ok is False and "3 sample(s)" in reason


def test_g30_insufficient_gate_on_garbage():
    ok, _ = stats.sufficient([])
    assert ok is False
    ok, _ = stats.sufficient([float("nan"), 1.0])
    assert ok is False
