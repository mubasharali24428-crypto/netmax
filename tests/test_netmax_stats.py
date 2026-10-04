"""Offline tests for netmax_stats (Tier-0 statistical intelligence).

Deterministic synthetic series with injected shift/spike/drift/seasonality.
No network, no subprocess, no randomness — pure arithmetic.
"""

from __future__ import annotations

import math
import statistics

import pytest

import netmax_stats as st


def flat(n: int = 60, value: float = 50.0) -> list[float]:
    return [value] * n


def sloped(n: int = 60, start: float = 10.0, step: float = 2.0) -> list[float]:
    return [start + i * step for i in range(n)]


def seasonal(n: int = 72, period: int = 12) -> list[float]:
    return [50.0 + 10.0 * math.sin(2 * math.pi * i / period)
            for i in range(n)]


def test_empty_and_nan_rejected():
    with pytest.raises(ValueError):
        st.ewma([])
    with pytest.raises(ValueError):
        st.mad_scores([1.0, float("nan")])


def test_welford_matches_statistics():
    data = sloped(50)
    w = st.Welford()
    for x in data:
        w.update(x)
    assert w.mean == pytest.approx(statistics.mean(data))
    assert w.std == pytest.approx(statistics.pstdev(data) * math.sqrt(
        len(data) / (len(data) - 1)))


def test_ewma_converges_to_constant():
    out = st.ewma(flat(20, 7.0))
    assert out[-1] == pytest.approx(7.0)


def test_ewma_rejects_bad_alpha():
    with pytest.raises(ValueError):
        st.ewma(flat(), alpha=0.0)


def test_ewma_bands_contain_flat_series():
    for mid, lo, hi in st.ewma_bands(flat(20, 5.0)):
        assert lo <= 5.0 <= hi
        assert mid == pytest.approx(5.0)


def test_cusum_finds_upward_shift():
    data = flat(40, 50.0) + flat(40, 70.0)
    hits = st.cusum(data)
    assert hits, "CUSUM missed a 20-point level shift"
    assert all(h["direction"] == 1.0 for h in hits)
    first = int(min(h["index"] for h in hits))
    assert 40 <= first <= 50, f"shift at 40, detected at {first}"


def test_cusum_silent_on_flat():
    assert st.cusum(flat(80)) == []


def test_mad_flags_single_spike():
    data = flat(50, 50.0)
    data[25] = 200.0
    flags = st.flag_points(data)
    assert [int(f["index"]) for f in flags] == [25]


def test_mad_silent_on_flat():
    assert st.flag_points(flat(50)) == []


def test_stl_lite_separates_seasonality():
    parts = st.stl_lite(seasonal(), period=12)
    assert len(parts["trend"]) == 72
    assert len(parts["seasonal"]) == 72
    # seasonal profile repeats: same phase, same value
    assert parts["seasonal"][0] == pytest.approx(parts["seasonal"][12])
    residual_scale = statistics.pstdev(parts["residual"])
    assert residual_scale < 2.0


def test_stl_lite_rejects_short_series():
    with pytest.raises(ValueError):
        st.stl_lite(flat(10), period=12)


def test_seasonal_anomalies_ignore_pattern_but_catch_spike():
    data = seasonal()
    assert st.seasonal_anomalies(data, period=12) == []
    data[30] += 60.0
    flags = st.seasonal_anomalies(data, period=12)
    assert [int(f["index"]) for f in flags] == [30]
    assert all(f["kind"] == 1.0 for f in flags)


def test_holt_forecast_continues_trend():
    fc = st.holt_forecast(sloped(60, 10.0, 2.0), horizon=3)
    assert fc["point"][0] == pytest.approx(132.0, abs=3.0)
    for p, lo, hi in zip(fc["point"], fc["lo"], fc["hi"]):
        assert lo <= p <= hi
    # bands widen with horizon
    assert (fc["hi"][2] - fc["lo"][2]) > (fc["hi"][0] - fc["lo"][0])


def test_changepoints_finds_single_step():
    data = flat(50, 20.0) + flat(50, 80.0)
    cps = st.changepoints(data)
    assert len(cps) == 1
    assert 45 <= cps[0] <= 55


def test_changepoints_silent_on_flat_and_trend():
    assert st.changepoints(flat(100)) == []
    assert st.changepoints(sloped(100, 0.0, 0.5)) == []


def test_summarize_keys_and_shift_detection():
    data = flat(40, 50.0) + flat(40, 70.0)
    data[10] = 200.0  # one point spike early on
    out = st.summarize(data, period=0)
    assert out["n"] == 80
    assert out["mean"] == pytest.approx(sum(data) / len(data))
    kinds = {f["kind"] for f in out["anomalies"]}
    assert 0.0 in kinds, "spike missed"
    assert 2.0 in kinds, "level shift missed"
    assert out["changepoints"], "changepoint missed"
    assert len(out["forecast"]["point"]) == 6
