"""Offline tests for netmetrics — subprocess.run is always faked.

Follows tests/conftest.py: the autouse `offline_guarantee` fixture arms a
tripwire on subprocess.run; each test installs its own fake via
monkeypatch.setattr, which implicitly disarms the tripwire for that test only.
"""

from __future__ import annotations

import subprocess

import pytest

import netmax
import netmetrics


def fake_run(stdout="", stderr="", returncode=0):
    def _run(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, returncode, stdout, stderr)
    return _run


# ── packet_loss ──────────────────────────────────────────────────────────────

LOSS_OK = (
    "64 bytes from 1.1.1.1: icmp_seq=0 ttl=57 time=10.1 ms\n"
    "--- 1.1.1.1 ping statistics ---\n"
    "5 packets transmitted, 5 packets received, 0.0% packet loss\n"
)


def test_packet_loss_parses_stdout(monkeypatch):
    monkeypatch.setattr(subprocess, "run", fake_run(stdout=LOSS_OK))
    assert netmetrics.packet_loss() == 0.0


def test_packet_loss_fractional(monkeypatch):
    out = LOSS_OK.replace("0.0% packet loss", "12.5% packet loss")
    monkeypatch.setattr(subprocess, "run", fake_run(stdout=out))
    assert netmetrics.packet_loss(host="8.8.8.8") == 12.5


def test_packet_loss_ignores_exit_code_100pct(monkeypatch):
    # Host blocks ICMP: non-zero exit but stdout still has the stats block.
    monkeypatch.setattr(
        subprocess, "run",
        fake_run(returncode=2,
                 stdout="10 packets transmitted, 0 received, 100.0% packet loss"),
    )
    assert netmetrics.packet_loss() == 100.0


def test_packet_loss_no_stats_raises(monkeypatch):
    monkeypatch.setattr(
        subprocess, "run",
        fake_run(stderr="ping: cannot resolve example.invalid: Unknown host",
                 returncode=68),
    )
    with pytest.raises(netmax.NetMaxError):
        netmetrics.packet_loss()


# ── jitter_ms ────────────────────────────────────────────────────────────────

REPLIES = "".join(f"64 bytes from 1.1.1.1: icmp_seq={i} ttl=57 time={t} ms\n"
                  for i, t in enumerate([140.0, 150.0, 145.0]))


def test_jitter_mean_abs_delta(monkeypatch):
    monkeypatch.setattr(subprocess, "run", fake_run(stdout=REPLIES))
    # deltas: 10, 5 → mean 7.5
    assert netmetrics.jitter_ms() == pytest.approx(7.5)


def test_jitter_skips_lt_0_1ms_lines(monkeypatch):
    out = REPLIES + "64 bytes from localhost: icmp_seq=3 ttl=64 time<0.1 ms\n"
    monkeypatch.setattr(subprocess, "run", fake_run(stdout=out))
    assert netmetrics.jitter_ms() == pytest.approx(7.5)  # unchanged by bad line


def test_jitter_fewer_than_two_samples_raises(monkeypatch):
    one = "64 bytes from 1.1.1.1: icmp_seq=0 ttl=57 time=10.0 ms\n"
    monkeypatch.setattr(subprocess, "run", fake_run(stdout=one))
    with pytest.raises(netmax.NetMaxError):
        netmetrics.jitter_ms()


# ── wifi_info ────────────────────────────────────────────────────────────────

WIFI_JSON = """{
  "SPAirPortDataType": [{
    "spairport_current_network_information": {
      "HomeNet": {
        "_name": "HomeNet",
        "spairport_network_phymode": "802.11n",
        "spairport_signal_or_noise": "-31 dBm / -97 dBm",
        "spairport_current_channel": "13 (2GHz, 20MHz)"
      }
    }
  }]
}"""


def test_wifi_info_json_path(monkeypatch):
    monkeypatch.setattr(subprocess, "run", fake_run(stdout=WIFI_JSON))
    info = netmetrics.wifi_info()
    assert info["rssi_dbm"] == -31
    assert info["noise_dbm"] == -97
    assert info["channel"] == "13"


def test_wifi_info_plaintext_fallback(monkeypatch):
    calls = []

    def _run(cmd, **kwargs):
        calls.append(cmd)
        if "-json" in cmd:
            return subprocess.CompletedProcess(cmd, 0, "{}", "")
        return subprocess.CompletedProcess(cmd, 0, (
            "Current Network Information:\n"
            "    HomeNet:\n"
            "      PHY Mode: 802.11n\n"
            "      Channel: 149 (5GHz, 80MHz)\n"
            "      Signal / Noise: -52 dBm / -88 dBm\n"
        ), "")

    monkeypatch.setattr(subprocess, "run", _run)
    info = netmetrics.wifi_info()
    assert info == {"rssi_dbm": -52, "noise_dbm": -88, "channel": "149"}
    assert any("-json" in c for c in calls)  # tried JSON first


def test_wifi_info_offline_raises(monkeypatch):
    monkeypatch.setattr(subprocess, "run", fake_run(stdout="{}"))
    with pytest.raises(netmax.NetMaxError):
        netmetrics.wifi_info()


def test_wifi_info_profiler_failure_raises(monkeypatch):
    monkeypatch.setattr(subprocess, "run",
                        fake_run(stderr="error", returncode=1))
    with pytest.raises(netmax.NetMaxError):
        netmetrics.wifi_info()
