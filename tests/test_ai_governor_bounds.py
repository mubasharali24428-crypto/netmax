"""Security boundaries for untrusted AI governor responses."""

from __future__ import annotations

import sys

import pytest

import netmax
import netmax_ai_provider
from netmax_ai import AISpeedGovernor


@pytest.mark.parametrize(
    "response",
    [
        {"pace_bps": float("nan")},
        {"pace_bps": float("inf")},
        {"pace_bps": float("-inf")},
        {"pace_bps": -1},
        {"pace_bps": 937_501},  # 1.5x of 5 Mbps in bytes/s
        {"pace_bps": "1e3"},
        {"pace_bps": "fast"},
        {"streams": 0},
        {"streams": 51},
        {"streams": 2.5},
        {"streams": "3"},
        {"streams": True},
        {"unexpected": "touch /tmp/netmax-ai-test"},
    ],
)
def test_parser_rejects_unsafe_governor_fields(response):
    with pytest.raises((TypeError, ValueError, OverflowError)):
        AISpeedGovernor._parse(response, target_mbps=5.0)


def test_parser_accepts_exact_ceiling_and_keeps_reasoning_inert():
    text = "<script>never execute</script> " * 30
    decision = AISpeedGovernor._parse(
        {"pace_bps": 937_500, "streams": 50, "reasoning": text},
        target_mbps=5.0,
    )
    assert decision.pace_bps == 937_500
    assert len(decision.reasoning) == 300
    assert decision.reasoning.startswith("<script>")


def test_decide_returns_none_for_invalid_provider_output(monkeypatch):
    monkeypatch.setattr(
        netmax_ai_provider, "chat_json", lambda *_args, **_kwargs: {"streams": 51})
    assert AISpeedGovernor(api_key="test").decide(5.0, {}) is None


def test_invalid_ai_output_does_not_interrupt_measurement(monkeypatch):
    monkeypatch.setattr(
        netmax_ai_provider, "chat_json", lambda *_args, **_kwargs: {"pace_bps": "fast"})
    monkeypatch.setattr(netmax, "_pull", lambda *_args, **_kwargs: 1024)
    monkeypatch.setattr(netmax, "_ping_median_ms", lambda **_kwargs: 1.0)

    class Metrics:
        @staticmethod
        def jitter_ms(**_kwargs):
            return 0.0

        @staticmethod
        def packet_loss(**_kwargs):
            return 0.0

    monkeypatch.setitem(sys.modules, "netmetrics", Metrics)
    total, rates, elapsed = netmax._limit_governor(
        1, 0.01, 250_000, ai_governor=AISpeedGovernor(api_key="test"))
    assert total > 0
    assert rates
    assert elapsed > 0


def test_model_decision_cannot_raise_aggregate_ceiling_or_run_reasoning(monkeypatch):
    monkeypatch.setattr(netmax, "_pull", lambda *_args, **_kwargs: 1024)
    monkeypatch.setattr(netmax, "_ping_median_ms", lambda **_kwargs: 1.0)
    events = []
    spawned = []
    monkeypatch.setattr(netmax, "_progress_emit", events.append)
    monkeypatch.setattr(netmax.subprocess, "run", lambda *a, **k: spawned.append((a, k)))

    class Metrics:
        @staticmethod
        def jitter_ms(**_kwargs):
            return 0.0

        @staticmethod
        def packet_loss(**_kwargs):
            return 0.0

    monkeypatch.setitem(sys.modules, "netmetrics", Metrics)
    monkeypatch.setattr(
        netmax_ai_provider,
        "chat_json",
        lambda *_args, **_kwargs: {
            "streams": 50,
            "pace_bps": 375_000,
            "reasoning": "$(touch /tmp/netmax-ai-test)",
            "confidence": "high",
        },
    )
    governor = AISpeedGovernor(api_key="test")
    total, _rates, _elapsed = netmax._limit_governor(
        1, 0.01, 250_000, ai_governor=governor)
    assert total > 0
    assert any(
        event == {"event": "ai", "reasoning": "$(touch /tmp/netmax-ai-test)"}
        for event in events)
    assert spawned == []


def test_stream_change_cannot_bypass_aggregate_pace_ceiling(monkeypatch):
    from concurrent.futures import Future

    waves = []

    class SyncPool:
        def __init__(self, max_workers):
            self.caps = []

        def __enter__(self):
            return self

        def __exit__(self, *_args):
            waves.append(self.caps)

        def submit(self, fn, seconds, cap):
            self.caps.append(cap)
            future = Future()
            future.set_result(fn(seconds, cap))
            return future

    class Metrics:
        @staticmethod
        def jitter_ms(**_kwargs):
            return 0.0

        @staticmethod
        def packet_loss(**_kwargs):
            return 0.0

    class Decision:
        streams = 50
        pace_bps = 999_999  # hostile over-ceiling value from an untrusted caller
        reasoning = ""

    class Governor:
        def decide(self, *_args):
            return Decision()

        def record_interval(self, *_args):
            pass

    times = iter((0.0, 0.0, 0.0, 0.1, 0.1, 0.1, 0.3, 0.3))
    monkeypatch.setattr(netmax.time, "monotonic", lambda: next(times))
    monkeypatch.setattr(netmax, "ThreadPoolExecutor", SyncPool)
    monkeypatch.setattr(netmax, "_pull", lambda *_args: 1024)
    monkeypatch.setattr(netmax, "_ping_median_ms", lambda **_kwargs: 1.0)
    monkeypatch.setitem(sys.modules, "netmetrics", Metrics)

    netmax._limit_governor(1, 0.2, 250_000, ai_governor=Governor())

    assert waves[0] == [250_000]
    assert len(waves[1]) == 50
    assert sum(waves[1]) <= 250_000 * netmax.LIMIT_PACE_CEILING
    assert set(waves[1]) == {7_500.0}
