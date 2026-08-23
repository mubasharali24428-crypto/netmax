"""Offline tests for netmax_eco (Mission 3 / E2).

No test touches the real network: tests/conftest.py arms tripwires on every
OS-level seam; each test installs fakes over the seams it needs.
"""

import subprocess

import pytest

import netmax
import netmax_eco


# ── fakes ────────────────────────────────────────────────────────────────────

class FakeProc:
    def __init__(self, returncode=0, stdout="", stderr=""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


def fake_ping(monkeypatch, idle=10.0, loaded=None):
    """Fake netmax._ping_median_ms; returns list of recorded calls."""
    calls = []

    def fake(host="1.1.1.1", count=10):
        calls.append((host, count))
        return idle if len(calls) == 1 else (loaded if loaded is not None else idle)

    monkeypatch.setattr(netmax, "_ping_median_ms", fake)
    return calls


def fake_curl(monkeypatch, proc):
    seen = {}

    def fake_run(cmd, **kwargs):
        seen["cmd"] = cmd
        seen["kwargs"] = kwargs
        return proc

    monkeypatch.setattr(subprocess, "run", fake_run)
    return seen


# ── grade estimation boundaries ──────────────────────────────────────────────

@pytest.mark.parametrize("delta,expected", [
    (0.0, "A+"),
    (4.999, "A+"),
    (5.0, "A"),        # boundary: < limit is strict
    (29.9, "A"),
    (30.0, "B"),
    (60.0, "C"),
    (200.0, "D"),
    (400.0, "F"),
    (10000.0, "F"),
])
def test_grade_boundaries(monkeypatch, delta, expected):
    fake_ping(monkeypatch, idle=10.0, loaded=10.0 + delta)
    fake_curl(monkeypatch, FakeProc())
    result = netmax_eco.eco_bloat()
    assert result["grade_est"] == expected


def test_grade_est_direct():
    assert netmax_eco._grade_est(3) == "A+"
    assert netmax_eco._grade_est(5) == "A"
    assert netmax_eco._grade_est(-2) == "A+"   # negative delta still A+


def test_delta_never_negative(monkeypatch):
    # loaded sample jittered below idle → delta clamps to 0
    fake_ping(monkeypatch, idle=20.0, loaded=15.0)
    fake_curl(monkeypatch, FakeProc())
    assert netmax_eco.eco_bloat()["delta_ms"] == 0.0


# ── small-probe URL construction ─────────────────────────────────────────────

@pytest.mark.parametrize("kb", [1, 100, 512])
def test_url_bytes_param_matches_probe_kb(monkeypatch, kb):
    fake_ping(monkeypatch)
    seen = fake_curl(monkeypatch, FakeProc())
    netmax_eco.eco_bloat(probe_kb=kb)
    url = seen["cmd"][[i for i, a in enumerate(seen["cmd"]) if a.startswith("https")][0]]
    assert f"bytes={kb * 1024}" in url
    assert url.startswith(netmax.CF_DOWN)


def test_default_host_and_probe(monkeypatch):
    calls = fake_ping(monkeypatch)
    fake_curl(monkeypatch, FakeProc())
    netmax_eco.eco_bloat()
    assert calls[0] == ("1.1.1.1", 10)      # idle: default host, full count
    assert calls[1][1] == 3                 # loaded: short sampling


def test_custom_host_used(monkeypatch):
    calls = fake_ping(monkeypatch)
    fake_curl(monkeypatch, FakeProc())
    netmax_eco.eco_bloat(host="8.8.8.8")
    assert all(c[0] == "8.8.8.8" for c in calls)


# ── error paths ──────────────────────────────────────────────────────────────

def test_curl_missing_raises(monkeypatch):
    fake_ping(monkeypatch)

    def no_curl(cmd, **kwargs):
        raise FileNotFoundError("No such file: 'curl'")

    monkeypatch.setattr(subprocess, "run", no_curl)
    with pytest.raises(netmax.NetMaxError, match="curl"):
        netmax_eco.eco_bloat()


@pytest.mark.parametrize("rc,err", [(6, "Could not resolve host"), (22, "HTTP 403")])
def test_download_failure_raises(monkeypatch, rc, err):
    fake_ping(monkeypatch)
    fake_curl(monkeypatch, FakeProc(returncode=rc, stderr=err))
    with pytest.raises(netmax.NetMaxError, match="download failed"):
        netmax_eco.eco_bloat()


def test_error_mentions_exit_code(monkeypatch):
    fake_ping(monkeypatch)
    fake_curl(monkeypatch, FakeProc(returncode=7, stderr="couldn't connect"))
    with pytest.raises(netmax.NetMaxError, match="exit 7"):
        netmax_eco.eco_bloat()


def test_result_shape_and_delta_value(monkeypatch):
    fake_ping(monkeypatch, idle=12.0, loaded=42.0)
    fake_curl(monkeypatch, FakeProc())
    out = netmax_eco.eco_bloat()
    assert set(out) == {"delta_ms", "grade_est"}
    assert out["delta_ms"] == pytest.approx(30.0)
    assert out["grade_est"] == "B"


# ── eco_dns ──────────────────────────────────────────────────────────────────

def test_dns_one_attempt_per_resolver(monkeypatch):
    seen = []

    def fake_rtt(server, attempts=3):
        seen.append((server, attempts))
        return {None: 11.0, "System default": 11.0, "1.1.1.1": 5.0,
                "8.8.8.8": 7.0, "9.9.9.9": 9.0}[server]

    monkeypatch.setattr(netmax, "_median_rtt_ms", fake_rtt)
    rows = netmax_eco.eco_dns()
    assert attempts_all_1(seen)
    assert rows == [("Cloudflare 1.1.1.1", 5.0), ("Google 8.8.8.8", 7.0),
                    ("Quad9 9.9.9.9", 9.0), ("System default", 11.0)]


def attempts_all_1(seen):
    return all(a == 1 for _, a in seen)


def test_dns_skips_unfit_resolvers(monkeypatch):
    def fake_rtt(server, attempts=1):
        if server == "8.8.8.8":
            raise netmax.NetMaxError(f"resolver {server} unfit")
        return {None: 11.0, "System default": 11.0, "1.1.1.1": 5.0,
                "9.9.9.9": 9.0}[server]

    monkeypatch.setattr(netmax, "_median_rtt_ms", fake_rtt)
    rows = netmax_eco.eco_dns()
    assert [r[0] for r in rows] == ["Cloudflare 1.1.1.1", "Quad9 9.9.9.9",
                                    "System default"]


def test_dns_all_down_raises(monkeypatch):
    def fake_rtt(server, attempts=1):
        raise netmax.NetMaxError(f"resolver {server} unfit")

    monkeypatch.setattr(netmax, "_median_rtt_ms", fake_rtt)
    with pytest.raises(netmax.NetMaxError, match="no DNS resolver reachable"):
        netmax_eco.eco_dns()
