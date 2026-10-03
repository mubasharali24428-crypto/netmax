"""Offline tests for netmax_ai_p2 (explanation, insight, advice).

The P2 layer must be useful with no API key — the wizard, the metric DSL and
the comparators are pure functions of their inputs. Model paths are tested
through a fake urlopen, and the security-relevant property of the rule
engine (no eval, no escape from the metric namespace) is pinned hard.
"""

from __future__ import annotations

import json

import pytest

from netmax_ai_p2 import (
    AccessibilityNarrator,
    BenchmarkComparator,
    CostAdvisor,
    GamifiedCoach,
    HardwareHealthMonitor,
    MetricRuleEngine,
    MetricRuleError,
    ResultExplainer,
    TroubleshootingWizard,
    TrendForecaster,
    ZeroDayThrottleDetector,
)


def _reply(content):
    class Resp:
        status = 200

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def read(self):
            return json.dumps({
                "choices": [{"message": {"content": json.dumps(content)}}]
            }).encode("utf-8")

    return lambda req, timeout=None: Resp()


def _boom(req, timeout=None):
    raise OSError("down")


# ── 18. ResultExplainer ───────────────────────────────────────────────────────

def test_explainer_translates_speed_into_wall_clock():
    out = ResultExplainer().explain({"mbps": 40.0})
    assert out["statements"]
    assert any("GB" in s or "MB" in s for s in out["statements"])


def test_explainer_makes_no_plan_claim_without_a_plan():
    out = ResultExplainer().explain({"mbps": 40.0})
    assert not any("you pay for" in s for s in out["statements"])


def test_explainer_claims_plan_shortfall_only_when_told_the_plan():
    out = ResultExplainer().explain({"mbps": 40.0}, plan_mbps=100.0)
    assert any("you say you pay for" in s for s in out["statements"])


def test_explainer_flags_multi_stream_headroom_caveat():
    out = ResultExplainer().explain({"mbps": 100.0}, plan_mbps=100.0)
    assert any("headroom" in c for c in out["caveats"])


def test_explainer_never_hides_bloatbloat():
    out = ResultExplainer().explain({"mbps": 90.0, "bloat_grade": "D"})
    assert any("bufferbloat" in c.lower() for c in out["caveats"])


def test_explainer_says_so_when_nothing_measured():
    out = ResultExplainer().explain({})
    assert out["headline"] != ""
    assert any("no throughput" in c for c in out["caveats"])


def test_explainer_rejects_unknown_tone():
    assert ResultExplainer().explain({"mbps": 10.0}, tone="shouty")["tone"] == "plain"


def test_explainer_model_failure_keeps_local(monkeypatch):
    ex = ResultExplainer(api_key="k")
    monkeypatch.setattr("netmax_ai.urlopen", _boom)
    out = ex.explain({"mbps": 40.0})
    assert out["source"] == "local"
    assert out["statements"]


# ── 19. TroubleshootingWizard ─────────────────────────────────────────────────

@pytest.mark.parametrize("symptom,expect_id", [
    ("my zoom calls are terrible", "quality"),
    ("downloads are so slow", "speed"),
    ("wifi keeps dropping", "wifi"),
    ("something is wrong", "generic"),
])
def test_wizard_routes_by_symptom(symptom, expect_id):
    assert TroubleshootingWizard().start(symptom).id == expect_id


def test_wizard_asks_about_peak_hours_for_evening_slowness():
    w = TroubleshootingWizard()
    step = w.next_step("speed", "evenings only")
    assert step.id == "peak"


def test_wizard_resolves_to_conclusion():
    w = TroubleshootingWizard()
    assert w.next_step("speed", "always").id == "speed_always"
    assert w.next_step("speed_always", "yes") is None


def test_wizard_conclude_blames_bufferbloat_when_latency_rose():
    w = TroubleshootingWizard()
    out = w.conclude({"quality": "yes", "speed": "always"})
    causes = {c["cause"] for c in out["causes"]}
    assert "bufferbloat" in causes
    assert all(c["fixes"] for c in out["causes"])


def test_wizard_conclude_names_peak_contention():
    out = TroubleshootingWizard().conclude({"speed": "evening"})
    assert "peak_contention" in {c["cause"] for c in out["causes"]}


def test_wizard_conclude_always_produces_something():
    out = TroubleshootingWizard().conclude({})
    assert out["causes"][0]["cause"] == "unresolved"


def test_wizard_probes_are_known_engine_modes():
    w = TroubleshootingWizard()
    for sid, answer in [("speed", "always"), ("quality", "yes"),
                        ("wifi", "yes")]:
        step = w.start("x")
        seen = []
        while step is not None:
            if step.probe:
                seen.append(step.probe)
            step = w.next_step(step.id, answer)
        assert all(p in w.PROBES for p in seen)


# ── 20. AccessibilityNarrator ────────────────────────────────────────────────

def test_narrator_emits_sentences_not_symbols():
    out = AccessibilityNarrator().narrate(
        {"mbps": 42.0, "bloat_grade": "A+", "jitter_ms": 4.0,
         "loss_pct": 0.1, "best_dns": "Cloudflare 1.1.1.1"})
    assert out["sentences"]
    assert not any(ch in out["summary"] for ch in "±≥≤→")


def test_narrator_spells_units_for_a_screen_reader():
    out = AccessibilityNarrator().narrate({"mbps": 42.0})
    assert "megabits per second" in out["summary"]


def test_narrator_high_jitter_becomes_a_caveat():
    out = AccessibilityNarrator().narrate({"mbps": 42.0, "jitter_ms": 80.0})
    assert any("Jitter" in c for c in out["caveats"])


def test_narrator_bad_grade_becomes_a_caveat():
    out = AccessibilityNarrator().narrate({"bloat_grade": "F"})
    assert any("slow during downloads" in c for c in out["caveats"])


def test_narrator_handles_an_empty_bundle():
    out = AccessibilityNarrator().narrate({})
    assert "No measurements" in out["summary"]


# ── 41. TrendForecaster ───────────────────────────────────────────────────────

def test_forecaster_refuses_a_trend_on_thin_data():
    tf = TrendForecaster()
    tf.record_sample(40.0)
    out = tf.forecast()
    assert out["trend"] == "insufficient_data"
    assert out["forecast_mbps"] is None
    assert out["confidence"] == "none"


def test_forecaster_detects_a_clean_decline():
    tf = TrendForecaster()
    for i in range(20):
        tf.record_sample(100.0 - i * 2)
    out = tf.forecast(horizon_days=7)
    assert out["trend"] == "declining"
    assert out["forecast_mbps"] < out["current_mean_mbps"]


def test_forecaster_calls_noise_flat():
    tf = TrendForecaster()
    for i in range(20):
        tf.record_sample(40.0 + (i % 2))     # no real slope
    assert tf.forecast()["trend"] == "flat"


def test_forecaster_never_forecasts_below_zero():
    tf = TrendForecaster()
    for i in range(30):
        tf.record_sample(5.0 - i * 1.0)
    assert tf.forecast(horizon_days=90)["forecast_mbps"] >= 0


def test_forecaster_clamps_the_horizon():
    tf = TrendForecaster()
    for i in range(20):
        tf.record_sample(50.0 - i)
    assert tf.forecast(horizon_days=10_000)["horizon_days"] <= 90


# ── 24. HardwareHealthMonitor ─────────────────────────────────────────────────

def test_hardware_refuses_judgement_on_thin_data():
    out = HardwareHealthMonitor().assess()
    assert out["verdict"] == "insufficient_data"


def test_hardware_flags_bloat_drift_with_no_config_change():
    mon = HardwareHealthMonitor()
    for _ in range(6):
        mon.record_sample(bloat_grade="A+", idle_latency_ms=10.0)
    for _ in range(6):
        mon.record_sample(bloat_grade="D", idle_latency_ms=12.0)
    out = mon.assess(config_changed_at="2026-01-01")
    assert out["verdict"] == "degrading"
    assert any("bufferbloat" in f["signal"] for f in out["findings"])
    assert any("config last changed" in n for n in out["notes"])


def test_hardware_calls_a_stable_link_stable():
    mon = HardwareHealthMonitor()
    for _ in range(10):
        mon.record_sample(bloat_grade="A+", idle_latency_ms=10.0, loss_pct=0.0)
    assert mon.assess()["verdict"] == "stable"


def test_hardware_flags_latency_creep():
    mon = HardwareHealthMonitor()
    for _ in range(6):
        mon.record_sample(bloat_grade="A", idle_latency_ms=10.0)
    for _ in range(6):
        mon.record_sample(bloat_grade="A", idle_latency_ms=40.0)
    out = mon.assess()
    assert any(f["component"] == "uplink_or_modem" for f in out["findings"])


# ── 25. ZeroDayThrottleDetector ──────────────────────────────────────────────

def test_detector_needs_three_stream_counts():
    d = ZeroDayThrottleDetector()
    d.record_sample(50.0, streams=1)
    d.record_sample(90.0, streams=8)
    assert d.detect()["confidence"] == "none"


def test_detector_finds_a_connection_count_cap():
    d = ZeroDayThrottleDetector()
    for streams, mbps in [(1, 20), (2, 39), (4, 42), (8, 30), (16, 12)]:
        d.record_sample(mbps, streams=streams)
    out = d.detect()
    assert out["throttle_detected"] is True
    assert out["threshold_streams"] is not None


def test_detector_finds_nothing_when_throughput_scales():
    d = ZeroDayThrottleDetector()
    for streams, mbps in [(1, 20), (2, 40), (4, 78), (8, 150)]:
        d.record_sample(mbps, streams=streams)
    out = d.detect()
    assert out["throttle_detected"] is False
    assert any("no cap" in n for n in out["notes"])


# ── 39. CostAdvisor ───────────────────────────────────────────────────────────

def test_cost_advisor_refuses_without_data():
    assert CostAdvisor().advise(0, 0)["verdict"] == "insufficient_data"


def test_cost_advisor_suggests_downgrade_when_heavily_overpaying():
    samples = [30.0] * 50 + [45.0] * 5
    out = CostAdvisor().advise(500.0, 80.0, samples=samples)
    assert out["verdict"] == "downgrade_recommended"
    assert out["suggested_mbps"] < 500.0
    # Nothing in this history exceeded the suggested tier, so the honest
    # statement is that there is no throttling evidence — not a warning.
    assert any("no measurement exceeded" in n for n in out["notes"])


def test_cost_advisor_leaves_a_fully_used_tier_alone():
    out = CostAdvisor().advise(100.0, 50.0, samples=[95.0] * 20)
    assert out["verdict"] != "downgrade_recommended"
    assert any("contention" in n for n in out["notes"])


def test_cost_advisor_reports_percentiles():
    out = CostAdvisor().advise(500.0, 80.0, samples=[10.0] * 10 + [90.0] * 10)
    assert out["p50"] <= out["p95"] <= out["p99"] <= out["peak"]


# ── 40. BenchmarkComparator ───────────────────────────────────────────────────

def test_benchmark_refuses_without_a_cohort():
    assert BenchmarkComparator().compare(50.0, {})["verdict"] == "insufficient_data"


def test_benchmark_places_a_fast_result():
    out = BenchmarkComparator().compare(
        90.0, {"p50": 40.0, "p90": 80.0}, cohort_label="cable + WiFi 5")
    assert out["beats_percentile"] == "p90"
    assert any("cable + WiFi 5" in n for n in out["notes"])


def test_benchmark_handles_a_slow_result():
    out = BenchmarkComparator().compare(5.0, {"p10": 10.0, "p50": 40.0})
    assert out["beats_percentile"] is None


# ── 37. GamifiedCoach ─────────────────────────────────────────────────────────

def test_coach_rejects_an_unknown_goal():
    assert "error" in GamifiedCoach().week_plan("nonsense")


def test_coach_needs_samples():
    assert GamifiedCoach().week_plan("bloat")["verdict"] == "insufficient_data"


def test_coach_reports_on_track_when_under_target():
    c = GamifiedCoach()
    for _ in range(5):
        c.record_sample(bloat_delta_ms=20.0)
    out = c.week_plan("bloat")
    assert out["verdict"] == "on_track"
    assert out["action"]


def test_coach_flags_work_to_do():
    c = GamifiedCoach()
    for _ in range(5):
        c.record_sample(bloat_delta_ms=180.0)
    assert c.week_plan("bloat")["verdict"] == "work_to_do"


# ── 42. MetricRuleEngine ─────────────────────────────────────────────────────

def test_rule_true_when_the_network_is_ready():
    eng = MetricRuleEngine()
    out = eng.evaluate(
        "upload_mbps > 10 and jitter_ms < 30 and loss_pct < 0.5",
        {"upload_mbps": 20.0, "jitter_ms": 10.0, "loss_pct": 0.1})
    assert out["passed"] is True


def test_rule_false_when_one_clause_fails():
    eng = MetricRuleEngine()
    out = eng.evaluate(
        "upload_mbps > 10 and jitter_ms < 30",
        {"upload_mbps": 20.0, "jitter_ms": 90.0})
    assert out["passed"] is False


def test_rule_honours_or():
    eng = MetricRuleEngine()
    assert eng.evaluate("mbps > 100 or loss_pct < 1",
                        {"mbps": 10.0, "loss_pct": 0.0})["passed"] is True


def test_rule_honours_parentheses():
    eng = MetricRuleEngine()
    # Without parens this would parse as (mbps>10 and mbps<100) or mbps>500
    out = eng.evaluate("(mbps > 10 and mbps < 100) or mbps > 500",
                       {"mbps": 50.0})
    assert out["passed"] is True


def test_rule_missing_metrics_use_safe_defaults():
    eng = MetricRuleEngine()
    out = eng.evaluate("mbps > 1000", {})
    assert out["passed"] is False


@pytest.mark.parametrize("rule", [
    "__import__('os')",
    "eval('1')",
    "mbps > 1 and os.system('ls')",
    "lambda: 1",
])
def test_rule_refuses_code_execution_attempts(rule):
    with pytest.raises(MetricRuleError):
        MetricRuleEngine().compile_rule(rule)


def test_rule_refuses_an_unknown_metric():
    with pytest.raises(MetricRuleError):
        MetricRuleEngine().compile_rule("secret_backdoor > 1")


def test_rule_refuses_assignment():
    with pytest.raises(MetricRuleError):
        MetricRuleEngine().compile_rule("mbps = 5")


def test_rule_refuses_unbalanced_parens():
    with pytest.raises(MetricRuleError):
        MetricRuleEngine().compile_rule("(mbps > 5")


def test_rule_refuses_an_empty_rule():
    with pytest.raises(MetricRuleError):
        MetricRuleEngine().compile_rule("   ")


def test_rule_refuses_an_absurdly_long_rule():
    with pytest.raises(MetricRuleError):
        MetricRuleEngine().compile_rule("mbps > 1 and " * 200 + "mbps > 2")


def test_rule_ignores_nan_in_supplied_metrics():
    out = MetricRuleEngine().evaluate("mbps > 5", {"mbps": float("nan")})
    assert out["passed"] is False


# ── 39. CostAdvisor currency + throttling-risk honesty ────────────────────────


def test_cost_advisor_renders_the_currency():
    out = CostAdvisor().advise(500.0, 80.0, currency="$",
                               samples=[30.0] * 50 + [45.0] * 5)
    assert out["currency"] == "$"
    assert out["currency_known"] is True
    assert any("$80" in n for n in out["notes"])
    assert any("$" in n for n in out["notes"])


def test_cost_advisor_flags_a_missing_currency():
    out = CostAdvisor().advise(500.0, 80.0, samples=[30.0] * 50)
    assert out["currency_known"] is False
    assert out["currency"] is None
    # A bare number must not be presented as if it were money.
    assert any("bare numbers" in n for n in out["notes"])


def test_cost_advisor_handles_non_dollar_currency():
    out = CostAdvisor().advise(500.0, 60.0, currency="£",
                               samples=[30.0] * 50)
    assert any("£60" in n for n in out["notes"])


def test_no_throttling_warning_when_nothing_exceeded():
    """The old text warned about throttling even at 0 exceedances."""
    out = CostAdvisor().advise(500.0, 80.0, currency="$",
                               samples=[30.0] * 50 + [45.0] * 5)
    assert not any("may be throttled" in n for n in out["notes"])
    assert any("nothing in your history suggests throttling" in n
               for n in out["notes"])


def test_throttling_warning_when_peaks_exceeded():
    out = CostAdvisor().advise(500.0, 80.0, currency="$",
                               samples=[10.0] * 40 + [400.0] * 10)
    if out["verdict"] == "downgrade_recommended":
        assert any("may be throttled" in n for n in out["notes"])
        assert not any("nothing in your history" in n for n in out["notes"])


def test_cost_advice_through_the_engine_surface():
    """The dispatch table must pass currency, not a dead history_limit."""
    import netmax
    out = netmax.run_ai_analysis("cost_advice", {
        "plan_mbps": 500.0, "monthly_cost": 80.0, "currency": "$",
        "samples": [30.0] * 50,
    })
    assert out["currency_known"] is True
