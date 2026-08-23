"""Offline tests for netmax_throttle (M3/F2).

Follows tests/conftest.py: the autouse offline_guarantee fixture tripwires
subprocess.run etc.; the measure_feedback tests replace that seam with a fake.
"""

import subprocess

import pytest

import netmax_throttle
from netmax_throttle import AdaptiveController, measure_feedback


PING_STDOUT = (
    "PING 1.1.1.1 (1.1.1.1): 56 data bytes\n"
    "64 bytes from 1.1.1.1: icmp_seq=0 ttl=58 time=12.3 ms\n"
    "64 bytes from 1.1.1.1: icmp_seq=1 ttl=58 time=14.7 ms\n"
    "64 bytes from 1.1.1.1: icmp_seq=2 ttl=58 time=13.5 ms\n"
    "\n"
    "--- 1.1.1.1 ping statistics ---\n"
    "3 packets transmitted, 3 packets received, 0.0% packet loss\n"
)

QUIET = (100.0, 0.0)


def test_starts_at_min():
    c = AdaptiveController()
    assert c.current() == 2


def test_backoff_on_high_latency():
    c = AdaptiveController(min_streams=2, max_streams=16)
    for _ in range(3):
        c.feed(*QUIET)
    before = c.current()
    c.feed(350.0, 0.0)
    assert c.current() == before - 1
    assert "latency" in c.reason


def test_backoff_on_loss():
    c = AdaptiveController(min_streams=2, max_streams=16)
    for _ in range(3):
        c.feed(*QUIET)
    before = c.current()
    c.feed(100.0, 5.0)
    assert c.current() == before - 1
    assert "loss" in c.reason


def test_ramp_up_requires_3_consecutive_quiet():
    c = AdaptiveController(min_streams=2, max_streams=16)
    assert c.current() == 2
    c.feed(*QUIET)
    assert c.current() == 2
    c.feed(*QUIET)
    assert c.current() == 2
    c.feed(*QUIET)
    assert c.current() == 3
    assert "ramp" in c.reason.lower()


def test_noisy_check_resets_quiet_streak():
    c = AdaptiveController(min_streams=2, max_streams=16)
    c.feed(*QUIET)
    c.feed(*QUIET)
    c.feed(200.0, 1.0)  # noisy but not backoff-worthy — resets streak
    c.feed(*QUIET)
    c.feed(*QUIET)
    assert c.current() == 2
    c.feed(*QUIET)
    assert c.current() == 3


def test_backoff_resets_quiet_streak():
    c = AdaptiveController(min_streams=2, max_streams=16)
    c.feed(*QUIET)
    c.feed(*QUIET)
    c.feed(400.0, 0.0)  # backoff; streak must reset
    streams_after_backoff = c.current()
    c.feed(*QUIET)
    c.feed(*QUIET)
    assert c.current() == streams_after_backoff


def test_clamped_at_min_streams():
    c = AdaptiveController(min_streams=2, max_streams=16)
    for _ in range(10):
        c.feed(500.0, 10.0)
    assert c.current() == 2
    assert "min" in c.reason


def test_clamped_at_max_streams():
    c = AdaptiveController(min_streams=2, max_streams=4)
    for _ in range(30):
        c.feed(*QUIET)
    assert c.current() == 4
    assert "max" in c.reason


def test_reset():
    c = AdaptiveController(min_streams=2, max_streams=4)
    for _ in range(9):
        c.feed(*QUIET)
    assert c.current() == 4
    c.reset()
    assert c.current() == 2
    # streak reset too: needs 3 fresh quiet checks to ramp again
    c.feed(*QUIET)
    c.feed(*QUIET)
    assert c.current() == 2


@pytest.mark.parametrize(
    "latency,loss",
    [(300.0, 0.0), (150.0, 0.0), (151.0, 0.5), (300.0, 2.0)],
)
def test_boundary_values_do_not_backoff(latency, loss):
    """Contract uses strict > for backoff and <= for quiet thresholds."""
    c = AdaptiveController(min_streams=1, max_streams=16)
    c.feed(latency, loss)
    assert c.current() == 1  # never went below min / no spurious backoff


def _fake_ping(stdout, returncode=0):
    def fake_run(cmd, **kwargs):
        class P:
            pass

        p = P()
        p.stdout = stdout
        p.stderr = ""
        p.returncode = returncode
        p.args = cmd
        return p

    return fake_run


def test_measure_feedback_parses_ping(monkeypatch):
    monkeypatch.setattr(subprocess, "run", _fake_ping(PING_STDOUT))
    latency_ms, loss_pct = measure_feedback("1.1.1.1", count=3)
    assert latency_ms == pytest.approx((12.3 + 14.7 + 13.5) / 3)
    assert loss_pct == pytest.approx(0.0)


def test_measure_feedback_odd_sample_median(monkeypatch):
    stdout = PING_STDOUT.replace("14.7", "99.0")
    monkeypatch.setattr(subprocess, "run", _fake_ping(stdout))
    latency_ms, loss_pct = measure_feedback()
    assert latency_ms == pytest.approx(13.5)  # median of {12.3, 99.0, 13.5}
    assert loss_pct == pytest.approx(0.0)


def test_measure_feedback_uses_ping_command(monkeypatch):
    seen = {}

    def fake_run(cmd, **kwargs):
        seen["cmd"] = cmd
        return _fake_ping(PING_STDOUT)(cmd, **kwargs)

    monkeypatch.setattr(subprocess, "run", fake_run)
    measure_feedback("example.test", count=5)
    assert seen["cmd"][0] == "ping"
    assert "-c" in seen["cmd"] and "5" in seen["cmd"]
    assert "example.test" in seen["cmd"]


def test_measure_feedback_raises_without_stats(monkeypatch):
    import netmetrics

    monkeypatch.setattr(subprocess, "run", _fake_ping("", returncode=1))
    with pytest.raises(netmetrics.NetMaxError):
        measure_feedback()


def test_throttle_module_uses_netmetrics_reuse():
    # Contract: reuse netmetrics (imported), not copied parsing helpers.
    assert hasattr(netmax_throttle, "netmetrics")
