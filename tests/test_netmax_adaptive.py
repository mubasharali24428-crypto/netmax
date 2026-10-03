"""Tests for adaptive measurement duration (P3 item 44).

The measurement runs in slices and stops when the RATE stops moving. The
danger is stopping early on a line that had not actually settled, so the
tests below pin the two things that matter: it stops when converged, and it
does NOT stop when the rate is still climbing.
"""

from __future__ import annotations

import pytest

import netmax


class Clock:
    """monotonic stand-in advancing `step` per read."""

    def __init__(self, step: float = 1.0):
        self.now = 0.0
        self.step = step

    def __call__(self) -> float:
        self.now += self.step
        return self.now


@pytest.fixture
def fast_clock(monkeypatch):
    clock = Clock(step=1.0)
    monkeypatch.setattr(netmax.time, "monotonic", clock)
    monkeypatch.setattr(netmax.time, "sleep", lambda _s: None)
    return clock


def _constant_line(mbps_per_slice, deadline_check=None):
    """_pull_chunk stand-in returning a fixed byte count per call."""
    def fake(seconds, limit_bps=None, problems=None):
        # 8 bits/Mb, 1e6 -> bytes for the requested window at this rate.
        return int(seconds * mbps_per_slice * 1e6 / 8), True
    return fake


def _ramping_line(rates):
    """Returns bytes for slice i from a per-slice Mbps list."""
    calls = {"n": 0}

    def fake(seconds, limit_bps=None, problems=None):
        i = calls["n"]
        calls["n"] += 1
        rate = rates[min(i, len(rates) - 1)]
        return int(seconds * rate * 1e6 / 8), True
    return fake


class TestAdaptiveStopsWhenSettled:
    def test_stops_early_on_a_steady_line(self, monkeypatch, fast_clock):
        # 40 Mbps throughout — converged within a few slices.
        monkeypatch.setattr(netmax, "_pull_chunk", _constant_line(40.0))
        mbps, _mb, _elapsed, detail = netmax.throughput_adaptive(
            1, 120, min_seconds=12, slice_s=4.0)
        assert detail["stopped_early"] is True
        assert detail["elapsed_seconds"] < detail["requested_seconds"]
        assert mbps > 0

    def test_never_stops_below_the_floor(self, monkeypatch, fast_clock):
        """A steady line still owes the floor — slow start must not be cut."""
        monkeypatch.setattr(netmax, "_pull_chunk", _constant_line(40.0))
        _mbps, _mb, _elapsed, detail = netmax.throughput_adaptive(
            1, 120, min_seconds=12, slice_s=4.0)
        assert detail["elapsed_seconds"] >= 12.0

    def test_no_pull_ever_exceeds_the_window(self, monkeypatch, fast_clock):
        """The ceiling binds every slice, including when the floor exceeds it.

        Asserted on the windows the engine REQUESTED rather than on elapsed
        time: the fake clock advances on every read, so a wall-clock total
        is harness noise. What must hold is that no single pull was ever
        handed more time than remained.
        """
        requested = []

        def recording(seconds, limit_bps=None, problems=None):
            requested.append(seconds)
            return int(seconds * 40.0 * 1e6 / 8), True

        monkeypatch.setattr(netmax, "_pull_chunk", recording)
        netmax.throughput_adaptive(1, 10, min_seconds=60, slice_s=4.0)
        assert requested, "no slice ran"
        assert max(requested) <= 10.0 + 1e-9

    def test_floor_above_ceiling_collapses_to_the_ceiling(self, monkeypatch,
                                                          fast_clock):
        monkeypatch.setattr(netmax, "_pull_chunk", _constant_line(40.0))
        _mbps, _mb, _elapsed, detail = netmax.throughput_adaptive(
            1, 10, min_seconds=60, slice_s=4.0)
        assert detail["requested_seconds"] == 10


class TestAdaptiveDoesNotStopEarly:
    def test_does_not_stop_while_the_rate_is_climbing(self, monkeypatch,
                                                       fast_clock):
        """Ramping then settling may stop — but never mid-ramp.

        The series climbs for 8 slices before flattening, so an early stop
        before slice ~7 would have under-reported the line.
        """
        monkeypatch.setattr(netmax, "_pull_chunk",
                            _ramping_line([10, 20, 35, 55, 80, 110, 150, 200]))
        _mbps, _mb, _elapsed, detail = netmax.throughput_adaptive(
            1, 60, min_seconds=8, slice_s=4.0, tolerance_pct=4.0)
        assert detail["slices"] >= 7, "stopped mid-ramp"

    def test_uses_the_full_window_when_noisy(self, monkeypatch, fast_clock):
        # Alternating wildly — no two adjacent slices agree.
        monkeypatch.setattr(netmax, "_pull_chunk",
                            _ramping_line([10, 90, 12, 88, 11, 91, 13, 87]))
        _mbps, _mb, _elapsed, detail = netmax.throughput_adaptive(
            1, 40, min_seconds=8, slice_s=4.0)
        assert detail["stopped_early"] is False


class TestAdaptiveHonesty:
    def test_reports_the_time_actually_spent(self, monkeypatch, fast_clock):
        """The stored duration must be elapsed, never the requested window."""
        monkeypatch.setattr(netmax, "_pull_chunk", _constant_line(40.0))
        _mbps, _mb, elapsed, detail = netmax.throughput_adaptive(
            1, 300, min_seconds=12, slice_s=4.0)
        assert detail["stopped_early"] is True
        assert detail["elapsed_seconds"] < 300
        assert elapsed == pytest.approx(detail["elapsed_seconds"], abs=0.5)

    def test_detail_records_every_slice_rate(self, monkeypatch, fast_clock):
        monkeypatch.setattr(netmax, "_pull_chunk", _constant_line(40.0))
        _mbps, _mb, _elapsed, detail = netmax.throughput_adaptive(
            1, 60, min_seconds=8, slice_s=4.0)
        assert detail["slices"] == len(detail["slice_rates_mbps"])
        assert detail["slices"] >= 3

    def test_zero_bytes_is_an_error_not_a_zero(self, monkeypatch, fast_clock):
        monkeypatch.setattr(netmax, "_pull_chunk",
                            lambda s, limit_bps=None, problems=None: (0, False))
        with pytest.raises(netmax.NetMaxError, match="nothing was downloaded"):
            netmax.throughput_adaptive(1, 20, min_seconds=4, slice_s=4.0)


class TestAdaptiveIsOptIn:
    def test_plain_throughput_is_untouched(self):
        """The existing path must remain the default everywhere."""
        import inspect
        sig = inspect.signature(netmax.throughput)
        assert "adaptive" not in sig.parameters

    def test_baseline_reports_actual_seconds_when_adaptive(self, monkeypatch,
                                                          fast_clock, capsys):
        monkeypatch.setattr(netmax, "_pull_chunk", _constant_line(40.0))
        netmax.run_baseline(300, adaptive=True)
        out = capsys.readouterr().out
        assert "settled after" in out
        assert "MB in 300s" not in out

    def test_baseline_without_adaptive_uses_the_full_window(self, monkeypatch,
                                                            capsys):
        monkeypatch.setattr(netmax, "throughput",
                            lambda s, sec, limit_bps=None: (42.0, 52.0))
        netmax.run_baseline(10)
        out = capsys.readouterr().out
        assert "MB in 10s" in out
        assert "settled after" not in out

    @pytest.mark.parametrize("mode", ["baseline", "turbo"])
    def test_cli_exposes_the_flag(self, mode, capsys):
        """--help exits before any runner, so this stays offline."""
        with pytest.raises(SystemExit):
            netmax.main([mode, "--help"])
        assert "--adaptive" in capsys.readouterr().out
