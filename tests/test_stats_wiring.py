"""Wiring tests: Tier-0 stats inside explainer / classifier / forecaster.

Additive keys and optional kwargs only — every assertion here must hold
without an API key, without network, and without touching analyser logic.
"""

from __future__ import annotations

from netmax_ai_p1 import RootCauseClassifier
from netmax_ai_p2 import ResultExplainer, TrendForecaster


def _trend(n: int = 20, start: float = 40.0, step: float = 1.0) -> list[float]:
    return [start + i * step for i in range(n)]


def test_forecast_carries_holt_and_changepoints():
    f = TrendForecaster(api_key="")
    for v in _trend(20):
        f.record_sample(v)
    out = f.forecast(horizon_days=7)
    assert out["source"] == "local"  # no key: model path untouched
    assert len(out["holt"]["point"]) == 6
    assert out["holt"]["lo"][0] <= out["holt"]["point"][0] <= out["holt"]["hi"][0]
    assert out["changepoints"] == []  # pure ramp: no false split


def test_forecast_flags_a_step():
    f = TrendForecaster(api_key="")
    for v in [50.0] * 12 + [30.0] * 12:
        f.record_sample(v)
    out = f.forecast(horizon_days=7)
    assert len(out["changepoints"]) == 1


def test_explain_adds_trend_statement():
    e = ResultExplainer(api_key="")
    base = e.explain({"mbps": 42.0})
    with_trend = e.explain({"mbps": 42.0}, trend_mbps=_trend())
    assert len(with_trend["statements"]) == len(base["statements"]) + 1
    assert "trend points to" in with_trend["statements"][-1]


def test_explain_without_trend_unchanged():
    e = ResultExplainer(api_key="")
    out = e.explain({"mbps": 42.0})
    assert out["source"] == "local"
    assert not any("trend points to" in s for s in out["statements"])


def test_explain_swallows_bad_series():
    e = ResultExplainer(api_key="")
    out = e.explain({"mbps": 42.0}, trend_mbps=[])
    assert out["source"] == "local"


def test_classify_attaches_trend_context():
    c = RootCauseClassifier(api_key="")
    series = [50.0] * 15 + [25.0] * 15
    out = c.classify({"mbps": 25.0}, trend_mbps=series)
    assert out["source"] == "local"
    assert out["trend_context"]["n"] == 30
    assert len(out["trend_context"]["changepoints"]) == 1


def test_classify_without_trend_has_no_context_key():
    c = RootCauseClassifier(api_key="")
    assert "trend_context" not in c.classify({"mbps": 25.0})


def test_classify_swallows_bad_series():
    c = RootCauseClassifier(api_key="")
    out = c.classify({"mbps": 25.0}, trend_mbps=[float("nan")])
    assert "trend_context" not in out
