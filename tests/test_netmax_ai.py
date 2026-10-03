"""Offline tests for netmax_ai (AI speed governor).

No network calls in default suite: AISpeedGovernor.decide is faked via
monkeypatch when needed. The default path (no API key) must return None.
"""

from __future__ import annotations

import json

import pytest

from netmax_ai import (
    AISpeedGovernor,
    EndpointStrategySelector,
    GovernorDecision,
    PredictiveAdjustment,
    PredictiveShaper,
)


def test_governor_decision_defaults():
    d = GovernorDecision()
    assert d.streams is None
    assert d.pace_bps is None
    assert d.reasoning == ""
    assert d.confidence == "low"


def test_no_api_key_returns_none():
    gov = AISpeedGovernor(api_key="")
    assert gov.decide(5.0, {"mbps": 4.8, "streams": 1}) is None


def test_record_interval_appends_history():
    gov = AISpeedGovernor(api_key="")
    gov.record_interval(4.8, streams=2, target_mbps=5.0)
    assert len(gov.history) == 1
    assert gov.history[0]["mbps"] == pytest.approx(4.8)
    assert gov.history[0]["streams"] == 2
    assert gov.history[0]["error_pct"] == pytest.approx(-4.0)


def test_record_interval_respects_history_limit():
    gov = AISpeedGovernor(api_key="", history_limit=3)
    for i in range(5):
        gov.record_interval(float(i), streams=1, target_mbps=5.0)
    assert len(gov.history) == 3
    assert gov.history[0]["mbps"] == pytest.approx(2.0)
    assert gov.history[-1]["mbps"] == pytest.approx(4.0)


def test_parse_valid_json():
    raw = {
        "streams": 3,
        "pace_bps": 6.25e6,
        "reasoning": "endpoint flaky",
        "confidence": "medium",
    }
    d = AISpeedGovernor._parse(raw)
    assert d.streams == 3
    assert d.pace_bps == pytest.approx(6.25e6)
    assert d.reasoning == "endpoint flaky"
    assert d.confidence == "medium"


def test_parse_streams_out_of_range_raises():
    with pytest.raises(ValueError):
        AISpeedGovernor._parse({"streams": 0, "reasoning": "x"})


def test_decide_success_with_mocked_api(monkeypatch):
    gov = AISpeedGovernor(api_key="k", model="m")
    api_payload = {
        "choices": [
            {
                "message": {
                    "content": json.dumps({
                        "streams": 4,
                        "pace_bps": 5e6,
                        "reasoning": "stable link",
                        "confidence": "high",
                    })
                }
            }
        ]
    }

    class DummyResp:
        def __enter__(self):
            return self
        def __exit__(self, exc_type, exc, tb):
            return False
        def read(self):
            return json.dumps(api_payload).encode("utf-8")
        status = 200

    seen = {}

    def fake_urlopen(req, timeout=None):
        seen["headers"] = dict(req.header_items())
        seen["method"] = req.method
        return DummyResp()

    monkeypatch.setattr("netmax_ai.urlopen", fake_urlopen)
    d = gov.decide(5.0, {"mbps": 5.1, "streams": 2, "endpoint_health": {}})
    assert d is not None
    assert d.streams == 4
    assert d.pace_bps == pytest.approx(5e6)
    assert d.reasoning == "stable link"
    assert d.confidence == "high"
    assert seen.get("method") == "POST"
    assert seen.get("headers", {}).get("Authorization") == "Bearer k"


def test_decide_api_failure_returns_none(monkeypatch):
    gov = AISpeedGovernor(api_key="k")

    def boom(req, timeout=None):
        raise OSError("network down")

    monkeypatch.setattr("netmax_ai.urlopen", boom)
    assert gov.decide(5.0, {}) is None


def test_decide_non_json_content_returns_raw(monkeypatch):
    gov = AISpeedGovernor(api_key="k")
    api_payload = {
        "choices": [{"message": {"content": "not-json"}}]
    }

    class DummyResp:
        def __enter__(self):
            return self
        def __exit__(self, exc_type, exc, tb):
            return False
        def read(self):
            return json.dumps(api_payload).encode("utf-8")
        status = 200

    monkeypatch.setattr("netmax_ai.urlopen", lambda req, timeout=None: DummyResp())
    d = gov.decide(5.0, {})
    assert d is not None
    assert d.reasoning == "not-json"
    assert d.raw == {"raw": "not-json", "reasoning": "not-json"}


def test_predictive_adjustment_defaults():
    """Test PredictiveAdjustment defaults."""
    adj = PredictiveAdjustment()
    assert adj.streams_adjustment == 0.0
    assert adj.pace_adjustment == 0.0
    assert adj.reasoning == ""
    assert adj.confidence == "low"
    
    # Test to_dict method
    adj_dict = adj.to_dict()
    assert adj_dict["streams_adjustment"] == 0.0
    assert adj_dict["pace_adjustment"] == 0.0
    assert adj_dict["reasoning"] == ""
    assert adj_dict["confidence"] == "low"
    
    # Test from_dict class method
    adj_from_dict = PredictiveAdjustment.from_dict(adj_dict)
    assert adj_from_dict.streams_adjustment == 0.0
    assert adj_from_dict.pace_adjustment == 0.0
    assert adj_from_dict.reasoning == ""
    assert adj_from_dict.confidence == "low"


def test_predictive_shaper_high_jitter_loss():
    """Test PredictiveShaper._local_suggestion for high jitter/loss."""
    shaper = PredictiveShaper()
    
    # Record some history to make the test more realistic
    shaper.record_interval(100.0, 5, 100.0, 0, 0, 0)
    
    # Test high jitter
    suggestion = shaper._local_suggestion(100.0, 100.0, 10.0, 80.0, 0.5, 5)
    assert suggestion["type"] == "high_jitter_loss"
    assert suggestion["streams_adjustment"] == -1
    assert suggestion["pace_adjustment"] == -0.1
    assert "High jitter (80.0ms)" in suggestion["reasoning"]
    assert "high" in suggestion["confidence"] or "medium" in suggestion["confidence"]
    
    # Test high loss
    suggestion = shaper._local_suggestion(100.0, 100.0, 10.0, 30.0, 2.0, 5)
    assert suggestion["type"] == "high_jitter_loss"
    assert suggestion["streams_adjustment"] == -1
    assert suggestion["pace_adjustment"] == -0.1
    
    # Test both high jitter and loss
    suggestion = shaper._local_suggestion(100.0, 100.0, 10.0, 150.0, 5.0, 5)
    assert suggestion["type"] == "high_jitter_loss"
    assert suggestion["confidence"] == "high"


def test_predictive_shaper_sustained_negative_trend():
    """Test PredictiveShaper._local_suggestion for sustained negative trend."""
    shaper = PredictiveShaper()
    
    # Record decreasing history
    shaper.record_interval(100.0, 5, 100.0, 10, 20, 0.1)
    shaper.record_interval(95.0, 5, 100.0, 12, 25, 0.2)
    shaper.record_interval(90.0, 5, 100.0, 15, 30, 0.3)
    shaper.record_interval(85.0, 5, 100.0, 18, 35, 0.4)
    shaper.record_interval(80.0, 5, 100.0, 20, 40, 0.5)
    
    suggestion = shaper._local_suggestion(80.0, 100.0, 20.0, 40.0, 0.5, 5)
    assert suggestion["type"] == "sustained_negative_trend"
    assert suggestion["streams_adjustment"] == -1
    assert suggestion["pace_adjustment"] == -0.15
    assert "Sustained negative trend" in suggestion["reasoning"]


def test_predictive_shaper_running_above_target():
    """Test PredictiveShaper._local_suggestion for running above target."""
    shaper = PredictiveShaper()
    
    # Record some history
    shaper.record_interval(100.0, 5, 100.0, 10, 20, 0.1)
    
    # Test running above target
    suggestion = shaper._local_suggestion(120.0, 100.0, 10.0, 25.0, 0.5, 5)
    assert suggestion["type"] == "running_above_target"
    assert suggestion["streams_adjustment"] == 0
    assert suggestion["pace_adjustment"] == 0.0
    assert "Running above target" in suggestion["reasoning"]


def test_predictive_shaper_suggest_when_history_empty():
    """Test PredictiveShaper.suggest() when history is empty."""
    shaper = PredictiveShaper()
    suggestion = shaper.suggest(100.0, 100.0, 10.0, 25.0, 0.5, 5)
    
    # P0 feature: return empty dict when history is empty
    assert suggestion == {}


def test_endpoint_strategy_selector_suggest_when_history_empty():
    """Test EndpointStrategySelector.suggest() when history is empty."""
    selector = EndpointStrategySelector()
    suggestion = selector.suggest("OVH", 0.8, 10.0)
    
    # P0 feature: return empty dict when history is empty
    assert suggestion == {}


def test_endpoint_strategy_selector_preference_logic():
    """Test EndpointStrategySelector.suggest() preference logic."""
    selector = EndpointStrategySelector()
    
    # Record results for different endpoints
    selector.record_result("OVH", 50.0, 20.0, 30.0, 0.5, True)
    selector.record_result("OVH", 60.0, 25.0, 35.0, 0.6, True)
    selector.record_result("Hetzner", 80.0, 15.0, 20.0, 0.2, True)
    selector.record_result("Hetzner", 70.0, 18.0, 25.0, 0.3, True)
    selector.record_result("CacheFly", 90.0, 10.0, 15.0, 0.1, True)
    selector.record_result("Cloudflare", 95.0, 8.0, 10.0, 0.05, True)
    
    # Suggest when current endpoint is not optimal
    suggestion = selector.suggest("OVH", 0.8, 10.0)
    assert suggestion["endpoint"] == "CacheFly" or suggestion["endpoint"] == "Cloudflare"
    assert "Switch from 'OVH'" in suggestion["reasoning"]
    assert "higher Mbps" in suggestion["reasoning"]
    assert "streams_adjustment" in suggestion
    assert "pace_adjustment" in suggestion
    assert "metrics" in suggestion
    
    # Verify that preference favors higher Mbps first
    assert suggestion["metrics"]["avg_mbps"] >= 90.0  # Cloudflare or CacheFly should be selected
    
    # Test with current endpoint being best
    suggestion2 = selector.suggest("Cloudflare", 0.8, 10.0)
    assert suggestion2["endpoint"] == "Cloudflare"
    assert "Current endpoint 'Cloudflare' is optimal" in suggestion2["reasoning"]
    assert suggestion2["streams_adjustment"] == 0




# ── P0 gap fix: the two heuristic classes must actually reach the model ──────
# Items 2 and 4 were specified as model reasoning; they shipped as pure local
# heuristics. These pin the API-backed path AND its guards (fallback on
# failure, clamping, and refusal to trust an endpoint we never measured).


def _chat_reply(content, seen=None):
    """urlopen stand-in returning one JSON-mode chat completion."""
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

    def fake(req, timeout=None):
        if seen is not None:
            seen["auth"] = req.get_header("Authorization")
        return Resp()

    return fake


def test_shaper_uses_model_when_heuristics_abstain(monkeypatch):
    shaper = PredictiveShaper(api_key="k")
    for _ in range(3):
        shaper.record_interval(50.0, 4, 50.0)      # benign — heuristics abstain
    seen = {}
    monkeypatch.setattr("netmax_ai.urlopen", _chat_reply(
        {"type": "sustained_negative_trend", "streams_adjustment": -1,
         "pace_adjustment": -0.15, "reasoning": "drifting down",
         "confidence": "medium"}, seen))
    out = shaper.suggest(50.0, 50.0, 12.0, 5.0, 0.1, 4)
    assert out["source"] == "ai"
    assert out["type"] == "sustained_negative_trend"
    assert out["streams_adjustment"] == -1
    assert out["reasoning"] == "drifting down"
    assert seen["auth"] == "Bearer k"


def test_shaper_prefers_local_answer_over_model(monkeypatch):
    """High loss is unambiguous — the model must not be consulted."""
    shaper = PredictiveShaper(api_key="k")
    shaper.record_interval(50.0, 4, 50.0)
    monkeypatch.setattr("netmax_ai.urlopen", _chat_reply(
        {"type": "maintain_current", "streams_adjustment": 0,
         "pace_adjustment": 0.0, "reasoning": "x", "confidence": "high"}))
    out = shaper.suggest(50.0, 50.0, 12.0, 5.0, 5.0, 4)
    assert out["type"] == "high_jitter_loss"
    assert "source" not in out


def test_shaper_model_failure_falls_back_to_local(monkeypatch):
    shaper = PredictiveShaper(api_key="k")
    shaper.record_interval(50.0, 4, 50.0)

    def boom(req, timeout=None):
        raise OSError("down")

    monkeypatch.setattr("netmax_ai.urlopen", boom)
    out = shaper.suggest(50.0, 50.0, 12.0, 5.0, 0.1, 4)
    assert out["type"] == "maintain_current"       # local answer survives


def test_shaper_clamps_model_moves(monkeypatch):
    """A model must not be able to command an unbounded correction."""
    shaper = PredictiveShaper(api_key="k")
    shaper.record_interval(50.0, 4, 50.0)
    monkeypatch.setattr("netmax_ai.urlopen", _chat_reply(
        {"type": "sustained_negative_trend", "streams_adjustment": -99,
         "pace_adjustment": -12.0, "reasoning": "x", "confidence": "high"}))
    out = shaper.suggest(50.0, 50.0, 12.0, 5.0, 0.1, 4)
    assert out["streams_adjustment"] == -3
    assert out["pace_adjustment"] == pytest.approx(-0.3)


def _seed_selector(sel):
    for mbps, lat, jit, loss in [(50, 20, 30, 0.5), (60, 25, 35, 0.6)]:
        sel.record_result("OVH", mbps, lat, jit, loss, True)
    sel.record_result("Hetzner", 80, 15, 20, 0.2, True)
    sel.record_result("CacheFly", 90, 10, 15, 0.1, True)
    return sel


def test_selector_model_can_rerank(monkeypatch):
    sel = _seed_selector(EndpointStrategySelector(api_key="k"))
    monkeypatch.setattr("netmax_ai.urlopen", _chat_reply(
        {"order": ["Hetzner", "CacheFly", "OVH"],
         "reasoning": "CacheFly 429s under sustained pulls", "confidence": "high"}))
    out = sel.suggest("OVH", 0.8, 10.0)
    assert out["endpoint"] == "Hetzner"
    assert out["reasoning"] == "CacheFly 429s under sustained pulls"


def test_selector_rejects_hallucinated_endpoint(monkeypatch):
    """An endpoint we never measured must be discarded, not trusted."""
    sel = _seed_selector(EndpointStrategySelector(api_key="k"))
    monkeypatch.setattr("netmax_ai.urlopen", _chat_reply(
        {"order": ["Fastly", "Hetzner", "CacheFly", "OVH"],
         "reasoning": "trust me", "confidence": "high"}))
    out = sel.suggest("OVH", 0.8, 10.0)
    assert out["endpoint"] == "CacheFly"            # local ranking intact


def test_selector_rejects_partial_order(monkeypatch):
    sel = _seed_selector(EndpointStrategySelector(api_key="k"))
    monkeypatch.setattr("netmax_ai.urlopen", _chat_reply(
        {"order": ["Hetzner"], "reasoning": "only one", "confidence": "low"}))
    out = sel.suggest("OVH", 0.8, 10.0)
    assert out["endpoint"] == "CacheFly"


def test_selector_model_failure_keeps_local_rank(monkeypatch):
    sel = _seed_selector(EndpointStrategySelector(api_key="k"))

    def boom(req, timeout=None):
        raise OSError("down")

    monkeypatch.setattr("netmax_ai.urlopen", boom)
    out = sel.suggest("OVH", 0.8, 10.0)
    assert out["endpoint"] == "CacheFly"


def test_no_api_key_means_no_api_call(monkeypatch):
    """Unset key must never reach the network."""
    def forbidden(req, timeout=None):
        raise AssertionError("urlopen must not be called without a key")

    monkeypatch.setattr("netmax_ai.urlopen", forbidden)
    shaper = PredictiveShaper(api_key="")
    shaper.record_interval(50.0, 4, 50.0)
    assert shaper.suggest(50.0, 50.0, 12.0, 5.0, 0.1, 4)["type"] == "maintain_current"
    sel = _seed_selector(EndpointStrategySelector(api_key=""))
    assert sel.suggest("OVH", 0.8, 10.0)["endpoint"] == "CacheFly"
