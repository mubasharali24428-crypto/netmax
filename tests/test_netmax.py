"""Offline pytest suite for netmax.py — no real network or process ever runs.

tests/conftest.py arms autouse tripwires on subprocess.run, getaddrinfo,
create_connection and socket.socket; each test installs fakes on exactly the
seams it exercises. Anything that slips through hits a tripwire and fails.
"""

from __future__ import annotations

import json
import socket
import string
import struct
import subprocess
import sys
import types
from collections import namedtuple
from pathlib import Path

import pytest

import netmax
import netmax_upload

FakeProc = namedtuple("FakeProc", "stdout stderr returncode")


class FastClock:
    """time.monotonic stand-in that advances `step` s per read.

    The sustained _pull loop runs back-to-back chunks until a real deadline;
    a clock that advances per read lets offline tests drive that loop to its
    deadline instantly, and `time.sleep` is patched to a no-op alongside it.
    """

    def __init__(self, step: float = 1.0):
        self.now = 0.0
        self.step = step

    def __call__(self) -> float:
        self.now += self.step
        return self.now


@pytest.fixture
def fast_pull_clock(monkeypatch):
    """Make the sustained pull loop terminate immediately (no real waiting)."""
    clock = FastClock()
    monkeypatch.setattr(netmax.time, "monotonic", clock)
    monkeypatch.setattr(netmax.time, "sleep", lambda _s: None)
    return clock


class ManualClock:
    """time.monotonic stand-in that only moves when the test advances it.

    Chunk fakes advance it themselves (simulating the chunk's real
    duration), so sweep counts stay deterministic no matter how many
    internal clock reads the implementation makes.
    """

    def __init__(self):
        self.now = 0.0

    def advance(self, dt: float) -> None:
        self.now += dt

    def __call__(self) -> float:
        return self.now


@pytest.fixture(autouse=True)
def _clean_endpoint_health(tmp_path, monkeypatch):
    """Adaptive endpoint-health memory must not leak between tests.

    HOME points at tmp: breaker persistence (Wave 3) must never touch the
    real ~/.netmax-endpoints.json during the suite.
    """
    monkeypatch.setenv("HOME", str(tmp_path))
    netmax._reset_endpoint_health()
    yield
    netmax._reset_endpoint_health()


@pytest.fixture(autouse=True)
def _clean_dns_cache():
    """DNS ranking cache must not leak between tests."""
    netmax._reset_dns_cache()
    yield
    netmax._reset_dns_cache()


# ── throughput / _pull ────────────────────────────────────────────────────────


class TestPull:
    def test_returns_bytes_from_first_working_endpoint(self, monkeypatch):
        calls = []

        def fake_run(argv, **kwargs):
            calls.append(argv)
            # New write-out: "http_code size_download"; exit 28 = our time cap.
            return FakeProc("200 123456", "", 28)

        monkeypatch.setattr(subprocess, "run", fake_run)
        assert netmax._pull(5) == 123456
        assert len(calls) == 1
        assert calls[0][0] == "curl"
        assert "--max-time" in calls[0]
        # UX-FIX: status validation is wired into the curl invocation itself
        assert any("%{http_code}" in a for a in calls[0])

    def test_falls_back_to_second_endpoint_on_rate_limit(self, monkeypatch):
        """UX-FIX acceptance: a 429 with a non-empty body must NOT count as data.

        Pre-fix this exact shape (exit 0, size_download=162) was returned as
        bytes and fabricated negative headroom in the default boost run.
        """
        seen = []

        def fake_run(argv, **kwargs):
            seen.append(argv[-1])
            if "ovh.net" in argv[-1]:
                # curl exit 0, 2-field write-out, HTTP 429 + 162B error body
                return FakeProc("429 162", "", 0)
            # exit 28 = window cap reached — ends the sustained pull
            return FakeProc("200 999", "", 28)

        monkeypatch.setattr(subprocess, "run", fake_run)
        assert netmax._pull(5) == 999
        assert len(seen) == 2  # OVH fails, Hetzner (2nd) carries, cap ends pull

    def test_429_on_every_endpoint_raises_instead_of_returning_bytes(
        self, monkeypatch, fast_pull_clock
    ):
        """UX-FIX acceptance: all-429 must fail loudly with the HTTP code visible."""
        monkeypatch.setattr(
            subprocess, "run",
            lambda argv, **kw: FakeProc("429 162", "", 0),
        )
        with pytest.raises(netmax.NetMaxError, match=r"HTTP 429"):
            netmax._pull(5)

    def test_falls_back_to_second_endpoint_on_empty_body(self, monkeypatch):
        seen = []

        def fake_run(argv, **kwargs):
            seen.append(argv[-1])
            if "ovh.net" in argv[-1]:
                # 200 but zero bytes delivered
                return FakeProc("200 0", "403 Forbidden", 0)
            return FakeProc("200 999", "", 28)  # exit 28: window cap reached

        monkeypatch.setattr(subprocess, "run", fake_run)
        assert netmax._pull(5) == 999
        assert len(seen) == 2  # OVH empty, Hetzner (2nd) carries, cap ends pull

    def test_raises_netmaxerror_when_all_endpoints_fail(
        self, monkeypatch, fast_pull_clock
    ):
        monkeypatch.setattr(
            subprocess, "run",
            lambda argv, **kw: FakeProc("", "", 6),
        )
        with pytest.raises(netmax.NetMaxError, match="all speed endpoints failed"):
            netmax._pull(5)

    def test_non_numeric_stdout_treated_as_zero_bytes(
        self, monkeypatch, fast_pull_clock
    ):
        monkeypatch.setattr(
            subprocess, "run",
            lambda argv, **kw: FakeProc("not-a-number", "", 0),
        )
        # first endpoint gives garbage → falls through → all fail
        with pytest.raises(netmax.NetMaxError):
            netmax._pull(5)

    def test_old_single_field_writeout_is_rejected(
        self, monkeypatch, fast_pull_clock
    ):
        """Guard against resurrecting the pre-fix curl write-out.

        The write-out MUST request http_code first — a bare %{size_download}
        is exactly how rate-limit bodies counted as throughput.
        """
        monkeypatch.setattr(
            subprocess, "run",
            lambda argv, **kw: FakeProc("5000000", "", 28),  # old format: no code
        )
        with pytest.raises(netmax.NetMaxError):
            netmax._pull(5)


class TestSustainedPull:
    """Long-run contract: chunks repeat until the window cap (auto-stop fix).

    Regression: _pull used to return on the FIRST clean finish (exit 0), so
    any run longer than one test file (100 MiB ≈ 26 s at 32 Mbps) auto-stopped
    before the requested duration — a 15-min run died in half a minute.
    """

    def test_back_to_back_chunks_fill_the_window(self, monkeypatch):
        """Chunks repeat until the window is spent (auto-stop regression)."""
        clock = ManualClock()
        monkeypatch.setattr(netmax.time, "monotonic", clock)
        monkeypatch.setattr(netmax.time, "sleep", lambda _s: None)
        calls = []

        def fake_run(argv, **kwargs):
            calls.append(argv)
            clock.advance(4.0)             # each 100 MB chunk lasts 4 s
            return FakeProc("200 1000", "", 0)

        monkeypatch.setattr(subprocess, "run", fake_run)
        # 10 s window / 4 s per chunk = three chunks, ended by the deadline
        assert netmax._pull(10) == 3000
        assert len(calls) == 3

    def test_each_chunk_capped_at_remaining_window(self, monkeypatch):
        """A chunk's --max-time covers the time still owed, not the full one."""
        clock = ManualClock()
        monkeypatch.setattr(netmax.time, "monotonic", clock)
        monkeypatch.setattr(netmax.time, "sleep", lambda _s: None)
        caps = []

        def fake_run(argv, **kwargs):
            caps.append(int(argv[argv.index("--max-time") + 1]))
            clock.advance(4.0)
            return FakeProc("200 10", "", 0)

        monkeypatch.setattr(subprocess, "run", fake_run)
        assert netmax._pull(10) == 30
        assert caps == [10, 6, 2]

    def test_midrun_blip_does_not_abort_the_run(self, monkeypatch):
        """One failed sweep mid-window pauses and retries — a long run must
        not die on a transient endpoint error, and the failed endpoint is
        deprioritized for the rest of the window."""
        clock = ManualClock()
        monkeypatch.setattr(netmax.time, "monotonic", clock)
        monkeypatch.setattr(netmax.time, "sleep", lambda _s: None)
        ovh_calls = []
        cf_calls = []

        def fake_run(argv, **kwargs):
            clock.advance(1.0)             # every curl attempt costs 1 s
            if "ovh.net" in argv[-1]:
                ovh_calls.append(1)
                if len(ovh_calls) == 2:    # OVH dies on its second use
                    return FakeProc("", "", 7)
                return FakeProc("200 100", "", 0)
            cf_calls.append(1)
            return FakeProc("200 100", "", 0)

        monkeypatch.setattr(subprocess, "run", fake_run)
        total = netmax._pull(10)           # must NOT raise despite the blip
        # 9 successful sweeps of 100 B each in the 10 s window; OVH is only
        # tried twice (its failure marks it for the 60 s cooldown)
        assert total == 900
        assert len(ovh_calls) == 2
        assert len(cf_calls) == 8

    def test_rate_limited_endpoint_deprioritized(self, monkeypatch):
        """Adaptive order (observed live): a 429-ing CDN is skipped on later
        sweeps so a long run stops losing the head of every interval to it —
        that repeated dead probe read as a sawtooth on the speedometer."""
        seen = []

        def fake_run(argv, **kw):
            seen.append(argv[-1])
            if "ovh.net" in argv[-1]:
                return FakeProc("429 162", "", 0)
            return FakeProc("200 100", "", 28)

        monkeypatch.setattr(subprocess, "run", fake_run)
        assert netmax._pull(5) == 100          # sweep 1: OVH fails, CF works
        assert any("ovh.net" in u for u in seen)
        seen.clear()
        assert netmax._pull(5) == 100          # sweep 2: OVH skipped entirely
        assert not any("ovh.net" in u for u in seen)

    def test_first_failure_cools_down_60s(self, monkeypatch):
        """Breaker step 1 (unchanged): a lone blip costs 60 s."""
        clock = ManualClock()
        monkeypatch.setattr(netmax.time, "monotonic", clock)
        netmax._mark_endpoint("OVH", ok=False)
        assert next(n for n, _ in netmax._ordered_endpoints()) == "Hetzner"
        clock.advance(59.0)
        assert next(n for n, _ in netmax._ordered_endpoints()) == "Hetzner"
        clock.advance(2.0)                        # t=61: cooldown spent
        assert next(n for n, _ in netmax._ordered_endpoints()) == "OVH"

    def test_repeated_failures_escalate_to_1h(self, monkeypatch):
        """Breaker steps 2-3: 2nd consecutive fail → 5 min, 3rd+ → 1 h."""
        clock = ManualClock()
        monkeypatch.setattr(netmax.time, "monotonic", clock)
        netmax._mark_endpoint("OVH", ok=False)     # streak 1 → 60 s
        clock.advance(61.0)
        netmax._mark_endpoint("OVH", ok=False)     # streak 2 → 300 s
        clock.advance(299.0)                      # t=360: still cooling
        assert next(n for n, _ in netmax._ordered_endpoints()) == "Hetzner"
        clock.advance(2.0)                        # t=362: 300 s spent
        assert next(n for n, _ in netmax._ordered_endpoints()) == "OVH"
        netmax._mark_endpoint("OVH", ok=False)     # streak 3 → 3600 s
        clock.advance(3599.0)
        assert next(n for n, _ in netmax._ordered_endpoints()) == "Hetzner"
        clock.advance(2.0)
        assert next(n for n, _ in netmax._ordered_endpoints()) == "OVH"

    def test_success_resets_breaker_streak(self, monkeypatch):
        """Any success clears the streak — the next fail is 60 s again."""
        clock = ManualClock()
        monkeypatch.setattr(netmax.time, "monotonic", clock)
        netmax._mark_endpoint("OVH", ok=False)
        netmax._mark_endpoint("OVH", ok=False)     # streak 2
        netmax._mark_endpoint("OVH", ok=True)      # reset
        netmax._mark_endpoint("OVH", ok=False)     # streak 1 → 60 s
        assert netmax._ENDPOINT_FAIL_UNTIL["OVH"] == 60.0


class TestBreakerPersistence:
    """Streaks survive restarts via ~/.netmax-endpoints.json (owner-only)."""

    @staticmethod
    def _fresh_process():
        """Simulate a new process: empty memory, disk not yet loaded."""
        netmax._ENDPOINT_FAIL_UNTIL.clear()
        netmax._ENDPOINT_FAIL_COUNT.clear()
        netmax._ENDPOINT_STATE_LOADED = False
        netmax._LAST_ENDPOINT_SAVE = 0.0

    def test_fail_persists_across_restart(self, monkeypatch):
        import os as _os

        clock = ManualClock()
        monkeypatch.setattr(netmax.time, "monotonic", clock)
        netmax._mark_endpoint("OVH", ok=False)
        netmax._mark_endpoint("OVH", ok=False)     # streak 2 → 300 s
        netmax._LAST_ENDPOINT_SAVE = 0.0           # allow the write through
        clock.advance(61.0)
        with netmax._ENDPOINT_LOCK:
            netmax._endpoint_state_save_locked()
        path = netmax._endpoint_state_path()
        assert _os.stat(path).st_mode & 0o777 == 0o600
        saved = json.loads(open(path, encoding="utf-8").read())
        assert saved["OVH"]["streak"] == 2
        self._fresh_process()                      # new process boots
        assert next(n for n, _ in netmax._ordered_endpoints()) == "Hetzner"

    def test_expired_entries_dropped_on_load(self):
        import time as _time

        stale = {"OVH": {"streak": 3,
                         "until_wall": _time.time() - 10.0}}
        with open(netmax._endpoint_state_path(), "w",
                  encoding="utf-8") as fh:
            json.dump(stale, fh)
        self._fresh_process()
        assert next(n for n, _ in netmax._ordered_endpoints()) == "OVH"

    def test_malformed_file_tolerated(self):
        with open(netmax._endpoint_state_path(), "w",
                  encoding="utf-8") as fh:
            fh.write("<<not json>>")
        self._fresh_process()
        assert next(n for n, _ in netmax._ordered_endpoints()) == "OVH"

    def test_saves_throttled_to_one_per_minute(self, monkeypatch):
        clock = ManualClock()
        monkeypatch.setattr(netmax.time, "monotonic", clock)
        netmax._LAST_ENDPOINT_SAVE = -1000.0      # last write "long ago"
        netmax._mark_endpoint("OVH", ok=False)    # writes (0 - -1000 >= 60)
        assert netmax._LAST_ENDPOINT_SAVE == 0.0
        clock.advance(10.0)
        netmax._mark_endpoint("OVH", ok=False)    # throttled, no write
        assert netmax._LAST_ENDPOINT_SAVE == 0.0

    def test_concurrent_marks_stay_consistent(self):
        import threading as _threading

        errors = []

        def hammer():
            try:
                for _ in range(10):
                    netmax._mark_endpoint("CF", ok=False)
            except Exception as exc:  # any escape fails the test
                errors.append(exc)

        threads = [_threading.Thread(target=hammer) for _ in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        assert not errors
        assert netmax._ENDPOINT_FAIL_COUNT["CF"] == 80

    def test_zero_bytes_over_the_whole_window_raises(
        self, monkeypatch, fast_pull_clock
    ):
        monkeypatch.setattr(
            subprocess, "run", lambda argv, **kw: FakeProc("429 1", "", 0)
        )
        with pytest.raises(netmax.NetMaxError):
            netmax._pull(5)

    def test_three_refuse_fourth_carries(self, monkeypatch):
        """4-way rotation: OVH/Hetzner/CacheFly 429 in one sweep, CF
        carries it — the run survives throttling that killed the old
        2-endpoint rotation outright."""
        seen = []

        def fake_run(argv, **kw):
            seen.append(argv[-1])
            if "cloudflare" in argv[-1]:
                return FakeProc("200 100", "", 28)
            return FakeProc("429 162", "", 0)

        monkeypatch.setattr(subprocess, "run", fake_run)
        assert netmax._pull(5) == 100
        hosts = " ".join(seen)
        assert "ovh.net" in hosts and "hetzner" in hosts
        assert "cachefly" in hosts and "cloudflare" in hosts

    def test_all_four_refuse_raises_with_every_name(
        self, monkeypatch, fast_pull_clock
    ):
        """Total refusal still fails honestly — and names every endpoint
        tried, so the operator sees it was 4-wide, not 1 flaky CDN."""
        monkeypatch.setattr(
            subprocess, "run", lambda argv, **kw: FakeProc("429 1", "", 0)
        )
        with pytest.raises(netmax.NetMaxError, match="Hetzner"):
            netmax._pull(5)

    def test_limit_rate_flag_passed_when_capped(self, monkeypatch):
        argvs = []
        monkeypatch.setattr(
            subprocess, "run",
            lambda argv, **kw: (argvs.append(argv), FakeProc("200 1", "", 28))[1],
        )
        netmax._pull(5, limit_bps=250_000)
        assert argvs[0][argvs[0].index("--limit-rate") + 1] == "250000"

    def test_no_limit_rate_flag_when_uncapped(self, monkeypatch):
        argvs = []
        monkeypatch.setattr(
            subprocess, "run",
            lambda argv, **kw: (argvs.append(argv), FakeProc("200 1", "", 28))[1],
        )
        netmax._pull(5)
        assert "--limit-rate" not in argvs[0]


class TestLimitGovernor:
    """Closed-loop cap controller: re-paces curl every interval so the
    aggregate tracks the target as the line wobbles (long-run strength).

    With FastClock(step=1.0) each governor interval consumes exactly three
    clock reads (deadline check, interval start, interval end), so a slice
    measures 1.0 s and a 10 s window runs three intervals.
    """

    @staticmethod
    def _paced_line(seen_caps, ratio):
        """Fake _pull delivering `ratio` × whatever cap it was given."""
        def fake(seconds, limit_bps=None):
            seen_caps.append(limit_bps)
            return int((limit_bps or 0) * ratio * 1.0)
        return fake

    def test_warmup_then_converges_when_line_runs_below_cap(
        self, monkeypatch, fast_pull_clock
    ):
        seen_caps = []
        monkeypatch.setattr(netmax, "_pull", self._paced_line(seen_caps, 0.8))
        total, rates, elapsed = netmax._limit_governor(1, 10, 250_000)
        # interval 1 is warm-up (cap untouched); interval 2 corrects ×1.25;
        # interval 3 lands inside the deadband and holds.
        assert seen_caps == [250_000, 250_000, 312_500]
        assert rates == pytest.approx([1.6, 1.6, 2.0])
        assert elapsed == pytest.approx(3.0)
        assert total == 650_000

    def test_correction_is_clamped_on_collapse(self, monkeypatch, fast_pull_clock):
        seen_caps = []
        monkeypatch.setattr(netmax, "_pull", self._paced_line(seen_caps, 0.5))
        netmax._limit_governor(1, 10, 250_000)
        # line at 50% of cap: raw correction ×2 is clamped to ×1.5,
        # applied after the warm-up interval (caps[2] = interval 3's cap)
        assert seen_caps[2] == pytest.approx(250_000 * netmax.LIMIT_MAX_CORRECT)

    def test_starvation_interval_does_not_boost(self, monkeypatch, fast_pull_clock):
        seen_caps = []
        # 10% of cap: a starvation blip — boosting into a recovering line
        # would only overshoot, so the cap holds.
        monkeypatch.setattr(netmax, "_pull", self._paced_line(seen_caps, 0.1))
        netmax._limit_governor(1, 10, 250_000)
        assert seen_caps == [250_000, 250_000, 250_000]

    def test_correction_is_clamped_on_overshoot(self, monkeypatch, fast_pull_clock):
        seen_caps = []
        monkeypatch.setattr(netmax, "_pull", self._paced_line(seen_caps, 2.0))
        netmax._limit_governor(1, 10, 250_000)
        # limiter overshoot ×2: correction clamped to ÷1.5, applied after
        # the warm-up interval (caps[2] = interval 3's cap)
        assert seen_caps[2] == pytest.approx(250_000 / netmax.LIMIT_MAX_CORRECT)

    def test_cap_split_across_streams(self, monkeypatch, fast_pull_clock):
        seen_caps = []
        monkeypatch.setattr(netmax, "_pull", self._paced_line(seen_caps, 1.0))
        netmax._limit_governor(4, 10, 250_000)
        assert seen_caps[0] == pytest.approx(250_000 / 4)

    def test_survives_midrun_blips(self, monkeypatch, fast_pull_clock):
        calls = []

        def flaky(seconds, limit_bps=None):
            calls.append(limit_bps)
            if len(calls) == 2:             # one whole dead interval
                raise netmax.NetMaxError("endpoint blip")
            return int((limit_bps or 0) * 1.0)

        monkeypatch.setattr(netmax, "_pull", flaky)
        total, rates, _elapsed = netmax._limit_governor(1, 10, 250_000)
        assert total == 500_000            # only the two live intervals count
        assert rates == pytest.approx([2.0, 0.0, 2.0])

    def test_dead_line_aborts_after_streak(self, monkeypatch, fast_pull_clock):
        def dead(seconds, limit_bps=None):
            raise netmax.NetMaxError("all speed endpoints failed")

        monkeypatch.setattr(netmax, "_pull", dead)
        with pytest.raises(netmax.NetMaxError, match="connection looks dead"):
            netmax._limit_governor(1, 300, 250_000)

    def test_pace_never_exceeds_ceiling_during_degradation(
        self, monkeypatch, fast_pull_clock
    ):
        """Hard band guarantee: a degraded line must never ratchet the
        commanded pace past LIMIT_PACE_CEILING × target (user report: 2 Mbps
        selected must never deliver anything like 10 or 20)."""
        seen_caps = []
        monkeypatch.setattr(netmax, "_pull", self._paced_line(seen_caps, 0.6))
        netmax._limit_governor(1, 20, 250_000)
        ceiling = 250_000 * netmax.LIMIT_PACE_CEILING
        assert max(seen_caps) <= ceiling + 1e-6
        assert max(seen_caps) == pytest.approx(ceiling)  # ratchet hits the wall

    def test_recovery_after_degradation_stays_in_band(
        self, monkeypatch, fast_pull_clock
    ):
        """Degraded stretch (line at 60%) then a healthy line: the first
        healthy interval may touch the 1.5× ceiling, and the very next
        interval is re-aimed exactly back at the target — never multiples."""
        seen_caps = []

        def line(seconds, limit_bps=None):
            seen_caps.append(limit_bps)
            ratio = 0.6 if len(seen_caps) <= 2 else 1.0
            return int((limit_bps or 0) * ratio * 1.0)

        monkeypatch.setattr(netmax, "_pull", line)
        _total, rates, _elapsed = netmax._limit_governor(1, 20, 250_000)
        ceiling = 250_000 * netmax.LIMIT_PACE_CEILING
        assert max(seen_caps) <= ceiling + 1e-6
        # interval 3 ran at the ceiling (line recovered), interval 4 is
        # re-aimed exactly back at the target.
        assert seen_caps[3] == pytest.approx(250_000)
        assert rates[3] == pytest.approx(2.0)

    def test_zero_byte_window_raises(self, monkeypatch, fast_pull_clock):
        def dead(seconds, limit_bps=None):
            raise netmax.NetMaxError("all speed endpoints failed")

        monkeypatch.setattr(netmax, "_pull", dead)
        with pytest.raises(netmax.NetMaxError, match="no data received"):
            netmax._limit_governor(1, 10, 250_000)


class TestAITelemetrySampling:
    """AI-governor telemetry is ICMP and must not run on every slice.

    packet_loss(count=10) at ping's 1s default is ~10s of probes — longer
    than the 5s LIMIT_INTERVAL_S slice it runs inside — so a per-slice probe
    both overruns the governor loop and puts more traffic on the wire than
    the hardcoded governor it replaces. Sampling is the fix; these tests pin
    the sampling rate and the probe count that caused it.
    """

    @staticmethod
    def _paced_line(seen_caps, fraction):
        def fake(seconds, limit_bps=None):
            seen_caps.append(limit_bps)
            return int(250_000 * fraction)
        return fake

    def test_probes_are_sampled_not_per_slice(self, monkeypatch, fast_pull_clock):
        seen_caps = []
        monkeypatch.setattr(netmax, "_pull", self._paced_line(seen_caps, 0.8))
        probes = []
        monkeypatch.setattr(
            netmax, "_ping_median_ms",
            lambda count=10, host="1.1.1.1": (probes.append(count), 12.0)[1],
        )

        class FakeNM:
            @staticmethod
            def jitter_ms(count=10):
                probes.append(count)
                return 3.0

            @staticmethod
            def packet_loss(count=10):
                probes.append(count)
                return 0.0

        monkeypatch.setitem(sys.modules, "netmetrics", FakeNM)

        class FakeGov:
            def decide(self, target_mbps, telemetry):
                return None       # no override — we only count the probes

            def record_interval(self, *_a):
                pass

        netmax._limit_governor(
            1, 30, 250_000, ai_governor=FakeGov()
        )
        # decide() runs every slice; the ICMP probes must not. One probe round
        # = 3 ICMP calls (ping/jitter/loss). Before the fix this was 3 calls
        # per slice — strictly more wire traffic than the hardcoded governor.
        slices = len(seen_caps)
        rounds = len(probes) // 3
        assert rounds < slices
        assert rounds == 4                  # slices 1, 4, 7, 10 of a 30s window
        assert max(probes) <= netmax.AI_PROBE_COUNT
        # Worst case per slice would be 3 rounds; we are well under it.
        assert rounds * 3 <= slices * 3 // 2

    def test_probe_count_is_bounded(self, monkeypatch, fast_pull_clock):
        counts = []
        monkeypatch.setattr(netmax, "_pull", self._paced_line([], 0.8))
        monkeypatch.setattr(
            netmax, "_ping_median_ms",
            lambda count=10, host="1.1.1.1": counts.append(count) or 12.0,
        )

        class FakeNM:
            @staticmethod
            def jitter_ms(count=10):
                counts.append(count)
                return 3.0

            @staticmethod
            def packet_loss(count=10):
                counts.append(count)
                return 0.0

        monkeypatch.setitem(sys.modules, "netmetrics", FakeNM)

        class FakeGov:
            def decide(self, *_a):
                return None

            def record_interval(self, *_a):
                pass

        netmax._limit_governor(1, 30, 250_000, ai_governor=FakeGov())
        assert counts, "no ICMP probes were issued"
        # Never the old count=10, and never more than AI_PROBE_COUNT=3.
        assert max(counts) <= netmax.AI_PROBE_COUNT
        assert 10 not in counts

    def test_no_ai_governor_means_no_probes(self, monkeypatch, fast_pull_clock):
        """The hardcoded path must stay silent on the wire."""
        monkeypatch.setattr(netmax, "_pull", self._paced_line([], 0.8))
        probes = []
        monkeypatch.setattr(
            netmax, "_ping_median_ms",
            lambda count=10, host="1.1.1.1": probes.append(count) or 12.0,
        )
        netmax._limit_governor(1, 30, 250_000)
        assert probes == []


class TestLimitMode:
    @staticmethod
    def _governor_spy(seen, total, rates, elapsed):
        def fake(streams, seconds, target_bps, ai_governor=None):
            seen.update(streams=streams, seconds=seconds, target_bps=target_bps)
            return total, rates, elapsed
        return fake

    def test_cap_passed_as_aggregate_bytes_per_second(self, monkeypatch):
        seen = {}
        monkeypatch.setattr(
            netmax, "_limit_governor",
            self._governor_spy(seen, 500_000, [2.0, 2.0], 2.0))
        netmax.run_limit(4, 10, 2.0, ai_governor=False)
        # 2 Mbps = 250_000 B/s AGGREGATE — the governor splits it per stream
        assert seen["target_bps"] == pytest.approx(2.0 * 1e6 / 8)
        assert (seen["streams"], seen["seconds"]) == (4, 10)

    def test_held_verdict_with_stability(self, capsys, monkeypatch):
        monkeypatch.setattr(
            netmax, "_limit_governor",
            lambda s, sec, t, ai_governor=None: (2_525_000, [2.0, 2.04], 10.0))
        netmax.run_limit(1, 10, 2.0, ai_governor=False)
        out = capsys.readouterr().out
        assert "target held" in out
        assert "stability:" in out

    def test_shortfall_reported_plainly(self, capsys, monkeypatch):
        monkeypatch.setattr(
            netmax, "_limit_governor",
            lambda s, sec, t, ai_governor=None: (1_500_000, [1.2, 1.2], 10.0))
        netmax.run_limit(1, 10, 2.0, ai_governor=False)
        assert "short of the cap" in capsys.readouterr().out

    def test_overrun_reported(self, capsys, monkeypatch):
        monkeypatch.setattr(
            netmax, "_limit_governor",
            lambda s, sec, t, ai_governor=None: (3_750_000, [3.0], 10.0))
        netmax.run_limit(1, 10, 2.0, ai_governor=False)
        out = capsys.readouterr().out
        assert "cap overrun" in out
        # a single interval carries no stability information — line omitted
        assert "stability:" not in out


class TestLimitCli:
    def test_cli_wiring(self, monkeypatch):
        seen = {}
        monkeypatch.setattr(
            netmax, "run_limit",
            lambda s, sec, m, ai_governor=False: seen.update(s=s, sec=sec, m=m))
        netmax.main(["limit", "--mbps", "2.5", "--seconds", "20", "--streams", "3"])
        assert seen == {"s": 3, "sec": 20, "m": 2.5}

    def test_defaults_single_stream_ten_seconds(self, monkeypatch):
        seen = {}
        monkeypatch.setattr(
            netmax, "run_limit",
            lambda s, sec, m, ai_governor=False: seen.update(s=s, sec=sec, m=m))
        netmax.main(["limit", "--mbps", "2"])
        assert seen == {"s": 1, "sec": 10, "m": 2.0}

    def test_mbps_out_of_band_fails(self, monkeypatch):
        monkeypatch.setattr(netmax, "run_limit", lambda *a: None)
        with pytest.raises(SystemExit):
            netmax.main(["limit", "--mbps", "0.2"])
        with pytest.raises(SystemExit):
            netmax.main(["limit", "--mbps", "10001"])


class TestThroughput:
    def test_aggregates_parallel_stream_counts(self, monkeypatch):
        monkeypatch.setattr(netmax.time, "monotonic", lambda: 10.0)  # elapsed ≈ 0 → clamped
        # clamp guard: give a tiny positive delta instead
        clock = iter([10.0, 11.0])

        def fake_clock():
            try:
                return next(clock)
            except StopIteration:
                return 11.0

        monkeypatch.setattr(netmax.time, "monotonic", fake_clock)
        monkeypatch.setattr(netmax, "_pull", lambda seconds, limit_bps=None: 1_000_000)
        mbps, mb = netmax.throughput(4, 1)
        assert mbps == pytest.approx(8 * 4_000_000 / 1e6)  # 32 Mbit in 1 s = 32 Mbps
        assert mb == pytest.approx(4.0)

    def test_single_stream_matches_pull_bytes(self, monkeypatch):
        clock = iter([0.0, 2.0])
        monkeypatch.setattr(netmax.time, "monotonic", lambda: next(iter([next(clock, 2.0)])))
        monkeypatch.setattr(netmax, "_pull", lambda seconds, limit_bps=None: 2_000_000)
        mbps, mb = netmax.throughput(1, 2)
        assert mb == pytest.approx(2.0)
        # 2 MB over 2 s = 8 Mbps
        assert mbps == pytest.approx(2_000_000 * 8 / 2 / 1e6)


# ── DNS ──────────────────────────────────────────────────────────────────────


class FakeSock:
    """Records sendto, replies instantly with a matching txid."""

    def __init__(self, payload_builder):
        self._builder = payload_builder
        self.sent: list[tuple] = []
        self._timeout = None

    def settimeout(self, t):
        self._timeout = t

    def sendto(self, data, addr):
        self.sent.append((data, addr))
        return len(data)

    def recvfrom(self, bufsize):
        query = self.sent[-1][0]
        txid = struct.unpack(">H", query[:2])[0]
        reply = self._builder(txid)
        return reply, ("0.0.0.0", 53)

    def close(self):
        pass


def _dns_reply(txid: int) -> bytes:
    header = struct.pack(">HHHHHH", txid, 0x8180, 1, 0, 0, 0)
    qname = b"\x03foo\x07example\x03com\x00"
    return header + qname + struct.pack(">HH", 1, 1)


class TestUdpQuery:
    def test_round_trip_returns_positive_rtt(self, monkeypatch):
        made = []

        def fake_socket(af, socktype):
            sock = FakeSock(_dns_reply)
            made.append(sock)
            return sock

        monkeypatch.setattr(socket, "socket", fake_socket)
        rtt = netmax._udp_query("1.1.1.1", "foo.example.com")
        assert rtt >= 0
        _data, addr = made[0].sent[0]
        assert addr == ("1.1.1.1", 53)

    def test_skips_mismatched_txid_replies(self, monkeypatch):
        stale = [struct.pack(">H", 0xDEAD) + b"x" * 10]

        class StaleThenGood(FakeSock):
            def recvfrom(self, bufsize):
                if stale:
                    return stale.pop(), ("0.0.0.0", 53)
                return super().recvfrom(bufsize)

        monkeypatch.setattr(socket, "socket", lambda af, st: StaleThenGood(_dns_reply))
        assert netmax._udp_query("9.9.9.9", "foo.example.com") >= 0


class TestMedianRtt:
    def test_fast_gaierror_counts_as_valid_sample(self, monkeypatch):
        import time as time_mod  # noqa: F401 — documents timing context

        def fast_getaddrinfo(name, port):
            raise socket.gaierror(-2, "Name or service not known")

        monkeypatch.setattr(socket, "getaddrinfo", fast_getaddrinfo)
        result = netmax._median_rtt_ms(None, attempts=3)
        assert result >= 0  # NXDOMAIN answered quickly — still a valid sample

    def test_slow_failure_raises_unreachable(self, monkeypatch):
        import time as time_mod

        started = {"t": 1000.0}

        def slow_clock():
            return started["t"]

        def bump():
            started["t"] += 3.0  # 3000 ms per attempt ≥ 2000 ms threshold
            return started["t"]

        monkeypatch.setattr(time_mod, "perf_counter", lambda: bump())

        def hanging_query(server, name, timeout=2.0):
            raise netmax.NetMaxError(f"resolver {server} timed out")

        monkeypatch.setattr(netmax, "_udp_query", hanging_query)
        with pytest.raises(netmax.NetMaxError, match="unfit"):
            netmax._median_rtt_ms("1.1.1.1", attempts=1)

    def test_refused_rcode_raises_unfit_immediately(self, monkeypatch):
        """A REFUSED/SERVFAIL reply is never a valid latency sample (F2 fix)."""
        monkeypatch.setattr(
            netmax, "_udp_query",
            lambda s, n, timeout=2.0: (_ for _ in ()).throw(
                netmax.NetMaxError(f"resolver {s} returned REFUSED")
            ),
        )
        with pytest.raises(netmax.NetMaxError, match="unfit.*REFUSED|REFUSED"):
            netmax._median_rtt_ms("1.1.1.1", attempts=3)


class TestDnsRanking:
    def test_sorted_ascending_and_includes_system_default(self, monkeypatch):
        latencies = {"System default": 60.0}
        for label, ip in netmax.RESOLVERS.items():
            latencies[label] = {"1.1.1.1": 20.0, "8.8.8.8": 80.0, "9.9.9.9": 50.0}[ip]

        def fake_median(server, attempts=3):
            key = "System default" if server is None else next(
                label for label, ip in netmax.RESOLVERS.items() if ip == server
            )
            return latencies[key]

        monkeypatch.setattr(netmax, "_median_rtt_ms", fake_median)
        rows = netmax.dns_ranking()
        names = [name for name, _ in rows]
        assert names[0] == "Cloudflare 1.1.1.1"
        assert names[-1] == "Google 8.8.8.8"
        assert "System default" in names
        ms_values = [ms for _, ms in rows]
        assert ms_values == sorted(ms_values)

    def test_second_call_within_ttl_skips_probes(self, monkeypatch):
        """Repeat ranking inside the hour costs zero UDP probes."""
        calls = []
        monkeypatch.setattr(
            netmax, "_median_rtt_ms",
            lambda server, attempts=3: calls.append(server) or 10.0)
        first = netmax.dns_ranking()
        assert len(calls) == 4  # system + 3 resolvers, measured once
        second = netmax.dns_ranking()
        assert second == first and len(calls) == 4

    def test_expired_cache_remeasures(self, monkeypatch):
        """Past the TTL the ranking probes again (stale resolvers refresh)."""
        clock = ManualClock()
        monkeypatch.setattr(netmax.time, "monotonic", clock)
        calls = []
        monkeypatch.setattr(
            netmax, "_median_rtt_ms",
            lambda server, attempts=3: calls.append(server) or 10.0)
        netmax.dns_ranking()
        assert len(calls) == 4
        clock.advance(netmax.DNS_CACHE_TTL_S + 1.0)
        netmax.dns_ranking()
        assert len(calls) == 8


# ── validation + CLI wiring ──────────────────────────────────────────────────


class TestChecked:
    @pytest.mark.parametrize("value", [5, 17, 30])
    def test_accepts_in_range(self, value):
        assert netmax._checked(value, 5, 30, "--seconds") == value

    @pytest.mark.parametrize("value", [4, 31, -1])
    def test_rejects_out_of_range(self, value):
        with pytest.raises(netmax.NetMaxError, match="--seconds must be"):
            netmax._checked(value, 5, 30, "--seconds")


class TestProgressOut:
    """--progress-out heartbeat: JSONL start/chunk/done around real runs."""

    @staticmethod
    def _events(path):
        return [json.loads(line) for line in Path(path).read_text().splitlines()]

    def test_baseline_emits_start_chunk_done(self, monkeypatch, tmp_path):
        monkeypatch.setattr(
            subprocess, "run",
            lambda argv, **kw: FakeProc("200 100", "", 28))
        out = tmp_path / "prog.jsonl"
        netmax.main(["baseline", "--seconds", "5", "--progress-out", str(out)])
        events = self._events(out)
        assert [e["event"] for e in events] == ["start", "chunk", "done"]
        assert all(e["mode"] == "baseline" for e in events)
        assert events[1]["bytes"] == 100

    def test_unwritable_path_exits_nonzero(self, monkeypatch, tmp_path, capsys):
        monkeypatch.setattr(
            subprocess, "run",
            lambda argv, **kw: FakeProc("200 100", "", 28))
        bad = tmp_path / "nope" / "prog.jsonl"
        with pytest.raises(SystemExit) as exc:
            netmax.main(["baseline", "--seconds", "5",
                         "--progress-out", str(bad)])
        assert exc.value.code == 1
        assert "progress-out" in capsys.readouterr().err
        assert not bad.exists()

    def test_done_emitted_on_failure(self, monkeypatch, tmp_path):
        monkeypatch.setattr(
            subprocess, "run", lambda argv, **kw: FakeProc("429 1", "", 0))
        out = tmp_path / "prog.jsonl"
        with pytest.raises(SystemExit):
            netmax.main(["baseline", "--seconds", "5",
                         "--progress-out", str(out)])
        assert [e["event"] for e in self._events(out)][-1] == "done"

    def test_limit_governor_emits_intervals(self, monkeypatch, tmp_path):
        clock = ManualClock()
        monkeypatch.setattr(netmax.time, "monotonic", clock)

        def fake_pull(seconds, limit_bps=None):
            clock.advance(1.0)
            return int((limit_bps or 0) * 1.0)

        monkeypatch.setattr(netmax, "_pull", fake_pull)
        out = tmp_path / "prog.jsonl"
        netmax.main(["limit", "--streams", "1", "--seconds", "5",
                     "--mbps", "2", "--progress-out", str(out)])
        events = self._events(out)
        intervals = [e for e in events if e["event"] == "interval"]
        assert len(intervals) >= 2
        assert all(e["mode"] == "limit" for e in events)

    def test_upload_attempt_emitted(self, monkeypatch, tmp_path):
        from io import BytesIO

        class FakeHead:
            def __init__(self, argv, **kw):
                self.stdout = BytesIO(b"x")

            def terminate(self):
                pass

            def wait(self, timeout=None):
                return 0

            def kill(self):
                pass

        monkeypatch.setattr(subprocess, "Popen", FakeHead)
        monkeypatch.setattr(
            subprocess, "run", lambda argv, **kw: FakeProc("200 100000 1.0", "", 0))
        out = tmp_path / "u.jsonl"
        netmax._PROGRESS_FH = open(out, "w", encoding="utf-8")
        netmax._PROGRESS_MODE = "upload"
        try:
            netmax_upload.upload_probe(seconds=2.0)
        finally:
            netmax._progress_end()
        attempts = [e for e in self._events(out) if e["event"] == "attempt"]
        assert len(attempts) == 1
        assert attempts[0]["endpoint"] in netmax_upload.ENDPOINTS_VERIFIED


class TestCli:
    def test_help_exits_zero_for_every_subcommand(self, capsys):
        for sub in ("baseline", "turbo", "boost", "dns", "full"):
            with pytest.raises(SystemExit) as exc:
                netmax.main([sub, "--help"])
            assert exc.value.code == 0

    def test_out_of_range_seconds_exits_nonzero_with_message(self, capsys):
        # W15: duration accepts quick band (5–30 s) OR long runs (up to 6 h),
        # so 99 is now LEGAL. Use 3 — below the universal 5 s minimum.
        with pytest.raises(SystemExit) as exc:
            netmax.main(["baseline", "--seconds", "3"])
        assert exc.value.code == 1
        assert "--seconds must be" in capsys.readouterr().err

    @pytest.mark.parametrize(
        "argv, expected_fn",
        [
            (["baseline", "--seconds", "5"], "run_baseline"),
            (["turbo", "--streams", "4", "--seconds", "5"], "run_turbo"),
            (["boost"], "run_boost"),
            (["full"], "run_full"),
        ],
    )
    def test_subcommands_dispatch(self, monkeypatch, argv, expected_fn):
        called = {}

        def spy(*args, **kwargs):
            called["args"] = args
            return 42.0 if expected_fn in ("run_baseline", "run_turbo") else None

        monkeypatch.setattr(netmax, expected_fn, spy)
        netmax.main(argv)
        assert called["args"]  # dispatch reached the right function

    def test_dns_dispatches(self, monkeypatch):
        called = []
        monkeypatch.setattr(netmax, "run_dns", lambda: called.append(True))
        netmax.main(["dns"])
        assert called == [True]


class TestReporting:
    def test_boost_prints_dropout_notice_on_dead_link(self, capsys, monkeypatch):
        monkeypatch.setattr(netmax, "throughput", lambda streams, seconds: (0.0, 0.0))
        # UX-FIX: dropout is now a NetMaxError (exit 1 via main), not a silent
        # success — the bridge envelope must carry success=false for MCP.
        with pytest.raises(netmax.NetMaxError, match="measurement unreliable"):
            netmax.run_boost(8, 10)
        out = capsys.readouterr().out
        assert "connection dropped mid-measurement" in out
        assert "%" not in out.split("Result")[1]

    def test_boost_dead_link_seen_as_failure_by_cli(self, capsys, monkeypatch):
        """UX-FIX acceptance: netmax boost on a dead link exits non-zero.

        Pre-fix: exit 0 + prose meant MCP reported a successful 0.0 Mbps run.
        """
        monkeypatch.setattr(
            netmax, "throughput", lambda streams, seconds: (0.0, 0.0)
        )
        with pytest.raises(SystemExit) as excinfo:
            netmax.main(["boost", "--streams", "8", "--seconds", "10"])
        assert excinfo.value.code == 1

    def test_boost_prints_gain_when_link_alive(self, capsys, monkeypatch):
        speeds = iter([(50.0, 60.0), (75.0, 90.0)])
        monkeypatch.setattr(netmax, "throughput", lambda streams, seconds: next(speeds))
        netmax.run_boost(8, 10)
        out = capsys.readouterr().out
        assert "headroom unlocked: +50%" in out

    def test_dns_report_marks_fastest(self, capsys, monkeypatch):
        monkeypatch.setattr(
            netmax, "dns_ranking",
            lambda: [("Cloudflare 1.1.1.1", 30.0), ("System default", 70.0)],
        )
        netmax.run_dns()
        out = capsys.readouterr().out
        assert "← fastest" in out
        assert "System Settings → Network → DNS" in out

    def test_system_default_wins_no_switch_tip(self, capsys, monkeypatch):
        monkeypatch.setattr(
            netmax, "dns_ranking",
            lambda: [("System default", 10.0), ("Cloudflare 1.1.1.1", 30.0)],
        )
        netmax.run_dns()
        out = capsys.readouterr().out
        assert "already the fastest tested" in out

    def test_boost_low_gain_prints_no_headroom_advice(self, capsys, monkeypatch):
        speeds = iter([(100.0, 100.0), (105.0, 105.0)])  # +5% < 10% threshold
        monkeypatch.setattr(netmax, "throughput", lambda streams, seconds: next(speeds))
        netmax.run_boost(8, 10)
        out = capsys.readouterr().out
        assert "already reach the full provisioned rate" in out
        assert "aria2c" not in out


# ── previously untested behavior ──────────────────────────────────────────────


class TestEndpointsFallbackOrder:
    """ENDPOINTS leads with static files (OVH, Hetzner, CacheFly);
    Cloudflare is LAST (its bot layer 403-blocks repeated hits)."""

    def test_order_and_templates(self):
        assert [name for name, _ in netmax.ENDPOINTS] == [
            "OVH", "Hetzner", "CacheFly", "Cloudflare"]
        ovh_url = netmax.ENDPOINTS[0][1]
        cf_url = netmax.ENDPOINTS[3][1]
        assert ovh_url == "https://proof.ovh.net/files/100Mb.dat"
        assert cf_url.startswith(netmax.CF_DOWN)
        assert "{cb}" in cf_url  # cache-buster placeholder present

    def test_cache_buster_differs_per_call(self, monkeypatch):
        urls = []
        monkeypatch.setattr(subprocess, "run",
                            lambda argv, **kw: (urls.append(argv[-1]),
                                                FakeProc("200 5", "", 28))[1])
        monkeypatch.setattr(netmax.random, "getrandbits", lambda n: 42)
        netmax._pull(5)
        assert "{cb}" not in urls[0]  # OVH template has no placeholder
        assert len(urls) == 1  # first endpoint succeeds → no fallback call

    def test_cloudflare_template_receives_cache_buster(self, monkeypatch):
        urls = []
        # All three statics fail, CF works — new 2-field write-out format;
        # CF's exit 28 (window cap) ends the sustained pull after one sweep.
        replies = iter([
            FakeProc("403 0", "", 0),   # OVH
            FakeProc("403 0", "", 0),   # Hetzner
            FakeProc("403 0", "", 0),   # CacheFly
            FakeProc("200 7", "", 28),   # Cloudflare
        ])

        def fake_run(argv, **kw):
            urls.append(argv[-1])
            return next(replies)

        monkeypatch.setattr(subprocess, "run", fake_run)
        monkeypatch.setattr(netmax.random, "getrandbits", lambda n: 42)
        netmax._pull(5)
        assert len(urls) == len(netmax.ENDPOINTS)
        assert "{cb}" not in urls[3]
        assert "cb=42" in urls[3]


class TestFreshName:
    def test_format_is_12_lowercase_labels_then_cloudflare(self):
        name = netmax._fresh_name()
        label, _, domain = name.partition(".")
        assert domain == "cloudflare.com"
        assert len(label) == 12
        assert all(c in string.ascii_lowercase for c in label)

    def test_two_calls_differ(self):
        assert netmax._fresh_name() != netmax._fresh_name()


class TestShareNote:
    def test_turbo_prints_share_note(self, capsys, monkeypatch):
        monkeypatch.setattr(netmax, "_pull", lambda seconds, limit_bps=None: 1_000_000)
        netmax.run_turbo(2, 5)
        out = capsys.readouterr().out
        assert netmax.SHARE_NOTE.strip().splitlines()[0][:20] in out
        assert "per-flow fairness" in out

    def test_baseline_does_not_print_share_note(self, capsys, monkeypatch):
        monkeypatch.setattr(netmax, "_pull", lambda seconds, limit_bps=None: 1_000_000)
        netmax.run_baseline(5)
        out = capsys.readouterr().out
        assert "per-flow fairness" not in out


class TestArgparseDefaults:
    @pytest.mark.parametrize("argv, fn", [
        (["baseline"], "run_baseline"),
        (["turbo"], "run_turbo"),
        (["boost"], "run_boost"),
        (["full"], "run_full"),
    ])
    def test_defaults_streams8_seconds10(self, monkeypatch, argv, fn):
        seen = {}
        monkeypatch.setattr(netmax, fn,
                            lambda *a, **kw: seen.update(args=a, kwargs=kw))
        netmax.main(argv)
        args = seen["args"]
        if fn == "run_baseline":
            assert args[0] == 10                      # seconds default 10
        else:
            assert args[0] == 8                       # streams default 8
            assert args[1] == 10                      # seconds default 10
        if fn in ("run_baseline", "run_turbo"):
            # P3 item 44: adaptive is opt-in and must default off, so the
            # measurement path is byte-for-byte the one already tested.
            assert seen.get("kwargs", {}).get("adaptive") is False


class TestUdpTimeout:
    def test_socket_timeout_raises_netmaxerror(self, monkeypatch):
        class TimeoutSock(FakeSock):
            def recvfrom(self, bufsize):
                raise TimeoutError("timed out")

        monkeypatch.setattr(socket, "socket", lambda af, st: TimeoutSock(_dns_reply))
        with pytest.raises(netmax.NetMaxError, match="resolver 1.1.1.1 timed out"):
            netmax._udp_query("1.1.1.1", "foo.example.com")


class TestFullCommand:
    def test_full_runs_boost_dns_bloat_and_sysctl_hint(self, capsys, monkeypatch):
        calls = []
        monkeypatch.setattr(netmax, "run_boost", lambda s, sec: calls.append("boost"))
        monkeypatch.setattr(netmax, "run_dns", lambda: calls.append("dns"))
        monkeypatch.setattr(netmax, "run_bloat", lambda s, sec: calls.append("bloat"))
        netmax.run_full(4, 5)
        assert calls == ["boost", "dns", "bloat"]
        assert "sysctl" in capsys.readouterr().out


class TestBloatGrade:
    @staticmethod
    def _pinger(*values):
        """Ping stub returning the given sequence, then repeating the last."""
        seq = list(values)

        def fake(host="1.1.1.1", count=10):
            return seq.pop(0) if len(seq) > 1 else seq[0]

        return fake

    def test_grades_follow_waveform_rubric(self, monkeypatch):
        # idle 40; loaded samples 45/55/60 → delta = max(60)-40 = +20 ms → A (<30)
        monkeypatch.setattr(netmax, "_pull", lambda seconds, limit_bps=None: 1_000_000)
        monkeypatch.setattr(netmax, "_ping_median_ms", self._pinger(40.0, 45.0, 55.0, 60.0))
        idle, delta, grade = netmax.bloat_grade(2, 6)
        assert idle == 40.0
        assert delta == pytest.approx(20.0)
        assert grade == "A"

    def test_b_grade_for_moderate_bloat(self, monkeypatch):
        # delta = 100-45 = 55 ms → B (<60)
        monkeypatch.setattr(netmax, "_pull", lambda seconds, limit_bps=None: 1_000_000)
        monkeypatch.setattr(netmax, "_ping_median_ms", self._pinger(45.0, 90.0, 100.0))
        _idle, _delta, grade = netmax.bloat_grade(2, 6)
        assert grade == "B"

    def test_a_plus_when_latency_stable_under_load(self, monkeypatch):
        monkeypatch.setattr(netmax, "_ping_median_ms", self._pinger(40.0, 40.0))
        monkeypatch.setattr(netmax, "_pull", lambda seconds, limit_bps=None: 1)
        _idle, delta, grade = netmax.bloat_grade(2, 6)
        assert delta == pytest.approx(0.0)
        assert grade == "A+"

    def test_f_when_latency_explodes(self, monkeypatch):
        monkeypatch.setattr(netmax, "_ping_median_ms", self._pinger(40.0, 500.0, 800.0))
        monkeypatch.setattr(netmax, "_pull", lambda seconds, limit_bps=None: 1)
        _idle, _delta, grade = netmax.bloat_grade(2, 6)
        assert grade == "F"

    def test_ping_failure_raises_netmaxerror(self, monkeypatch):
        def fail_run(argv, **kw):
            return types.SimpleNamespace(stdout="", stderr="network unreachable")

        import subprocess as sp
        monkeypatch.setattr(sp, "run", fail_run)
        with pytest.raises(netmax.NetMaxError, match="ping.*failed"):
            netmax._ping_median_ms()


# ── coverage audit additions ──────────────────────────────────────────────────


def _reply_with_rcode(txid: int, rcode: int) -> bytes:
    """Build a minimal DNS reply header carrying the given RCODE."""
    # byte 3 low nibble = rcode
    return struct.pack(">HHHHHH", txid, 0x8180 | rcode, 1, 0, 0, 0) + b"x" * 6


class TestUdpQueryRcode:
    """RCODE-aware _udp_query: only NOERROR / NXDOMAIN count as alive."""

    def _patch(self, monkeypatch, builder):
        import socket as socket_mod

        monkeypatch.setattr(socket_mod, "socket", lambda af, st: FakeSock(builder))

    def test_nxdomain_is_valid_alive_sample(self, monkeypatch):
        self._patch(monkeypatch, lambda txid: _reply_with_rcode(txid, netmax.DNS_RCODE_NXDOMAIN))
        assert netmax._udp_query("1.1.1.1", "nope.example.com") >= 0

    def test_servfail_raises(self, monkeypatch):
        self._patch(monkeypatch, lambda txid: _reply_with_rcode(txid, netmax.DNS_RCODE_SERVFAIL))
        with pytest.raises(netmax.NetMaxError, match="SERVFAIL"):
            netmax._udp_query("8.8.8.8", "x.example.com")

    def test_refused_raises(self, monkeypatch):
        self._patch(monkeypatch, lambda txid: _reply_with_rcode(txid, netmax.DNS_RCODE_REFUSED))
        with pytest.raises(netmax.NetMaxError, match="REFUSED"):
            netmax._udp_query("9.9.9.9", "x.example.com")

    def test_unknown_rcode_reported_as_number(self, monkeypatch):
        self._patch(monkeypatch, lambda txid: _reply_with_rcode(txid, 11))  # unassigned
        with pytest.raises(netmax.NetMaxError, match="returned 11"):
            netmax._udp_query("1.1.1.1", "x.example.com")

    def test_rcode_read_from_low_4_bits_only(self, monkeypatch):
        # high bits of byte 3 carry flags; must not pollute the rcode check
        def builder(txid):
            reply = bytearray(_reply_with_rcode(txid, netmax.DNS_RCODE_NOERROR))
            reply[3] |= 0x80  # RA flag set → byte3 = 0x88, rcode still 0
            return bytes(reply)

        self._patch(monkeypatch, builder)
        assert netmax._udp_query("1.1.1.1", "x.example.com") >= 0

    def test_short_reply_below_header_size_is_skipped(self, monkeypatch):
        class ShortThenGood(FakeSock):
            def __init__(self, builder):
                super().__init__(builder)
                self._shorts = 2

            def recvfrom(self, bufsize):
                if self._shorts:
                    self._shorts -= 1
                    return b"tooshort", ("0.0.0.0", 53)
                return super().recvfrom(bufsize)

        import socket as socket_mod
        monkeypatch.setattr(socket_mod, "socket", lambda af, st: ShortThenGood(_dns_reply))
        assert netmax._udp_query("1.1.1.1", "foo.example.com") >= 0


class TestDnsRankingSkipPaths:
    """Unfit resolvers are skipped with a note; never fatal unless all fail."""

    def test_system_default_failure_does_not_block_ranking(self, monkeypatch):
        def fake_median(server, attempts=3):
            if server is None:
                raise netmax.NetMaxError("resolver None unfit: timed out")
            return 25.0

        monkeypatch.setattr(netmax, "_median_rtt_ms", fake_median)
        rows = netmax.dns_ranking()
        assert [name for name, _ in rows] == list(netmax.RESOLVERS)

    def test_unfit_public_resolver_skipped_with_message(self, monkeypatch, capsys):
        def fake_median(server, attempts=3):
            if server is None:
                return 30.0
            if server == "8.8.8.8":
                raise netmax.NetMaxError(f"resolver {server} unfit: SERVFAIL")
            return 40.0

        monkeypatch.setattr(netmax, "_median_rtt_ms", fake_median)
        rows = netmax.dns_ranking()
        names = [name for name, _ in rows]
        assert "Google 8.8.8.8" not in names
        assert len(names) == 3  # system + 2 healthy resolvers
        assert "skipped" in capsys.readouterr().out

    def test_all_resolvers_unfit_raises(self, monkeypatch):
        def always_unfit(server, attempts=3):
            raise netmax.NetMaxError(f"resolver {server} unfit")

        monkeypatch.setattr(netmax, "_median_rtt_ms", always_unfit)
        with pytest.raises(netmax.NetMaxError, match="no DNS resolver reachable"):
            netmax.dns_ranking()


class TestBloatGradeBoundaries:
    """Exact C/D/F rubric boundaries from BLOAT_GRADES."""

    def test_c_d_f_boundaries(self, monkeypatch):
        cases = [
            (5.0, "A"), (30.0, "B"),      # < limit keeps better grade
            (60.0, "C"),                   # 60 → C (<200)
            (199.999, "C"),
            (200.0, "D"),                  # exactly 200 crosses into D
            (399.9, "D"),
            (400.0, "F"),                  # exactly 400 → worst bucket → F
            (1200.0, "F"),
        ]
        for delta, expected in cases:
            idle = 50.0
            state = {"first": True}

            def fake_ping(host="1.1.1.1", count=10, _idle=idle, _state=state, _delta=delta):
                if _state["first"]:
                    _state["first"] = False   # idle sample
                    return _idle
                return _idle + _delta         # every loaded sample

            monkeypatch.setattr(netmax, "_ping_median_ms", fake_ping)
            monkeypatch.setattr(netmax, "_pull", lambda seconds, limit_bps=None: 1000)
            _got_idle, got_delta, grade = netmax.bloat_grade(2, 6)
            assert grade == expected, f"delta={delta}: got {grade}, want {expected}"
            assert got_delta == pytest.approx(delta)


class TestMedianRttSystemPath:
    def test_system_path_slow_gaierror_raises_unreachable(self, monkeypatch):
        import time as time_mod

        started = {"t": 0.0}

        def bump():
            started["t"] += 3.0  # ≥ 2000 ms threshold
            return started["t"]

        monkeypatch.setattr(time_mod, "perf_counter", bump)

        def slow_gai(name, port):
            raise socket.gaierror(-2, "timed out")

        monkeypatch.setattr(socket, "getaddrinfo", slow_gai)
        with pytest.raises(netmax.NetMaxError, match="unreachable"):
            netmax._median_rtt_ms(None, attempts=1)

    def test_udp_resolver_timeout_wraps_as_unfit(self, monkeypatch):
        def timeout_query(server, name, timeout=2.0):
            raise netmax.NetMaxError(f"resolver {server} timed out")

        monkeypatch.setattr(netmax, "_udp_query", timeout_query)
        with pytest.raises(netmax.NetMaxError, match="resolver 1.1.1.1 unfit.*timed out"):
            netmax._median_rtt_ms("1.1.1.1", attempts=1)


# ── measure.py results history ───────────────────────────────────────────────


class TestAppendHistory:
    """measure.append_history: offline coverage of the history.json trail."""

    def test_creates_file_when_missing(self, tmp_path):
        import measure

        hist = tmp_path / "results" / "history.json"
        entry = measure.append_history("full", {"turbo8_mbps": 42.5},
                                       timestamp="2026-08-22T12:00:00",
                                       history_file=hist)
        assert entry == {"timestamp": "2026-08-22T12:00:00",
                         "mode": "full",
                         "results": {"turbo8_mbps": 42.5}}
        loaded = json.loads(hist.read_text())
        assert loaded == [entry]

    def test_appends_keeps_prior_entries(self, tmp_path):
        import measure

        hist = tmp_path / "history.json"
        hist.write_text(json.dumps([{"timestamp": "old", "mode": "baseline"}]))
        measure.append_history("full", {"baseline_mbps": 10.0},
                               timestamp="2026-08-22T13:00:00",
                               history_file=hist)
        loaded = json.loads(hist.read_text())
        assert len(loaded) == 2
        assert loaded[0] == {"timestamp": "old", "mode": "baseline"}
        assert loaded[1]["mode"] == "full"

    def test_corrupt_history_file_is_quarantined_not_wiped(self, tmp_path):
        import measure

        hist = tmp_path / "history.json"
        hist.write_text("{not json")
        measure.append_history("dns", {"fastest": "Cloudflare"},
                               history_file=hist)
        # Original bytes preserved beside the fresh file — never destroyed.
        backup = tmp_path / "history.json.corrupt"
        assert backup.read_text() == "{not json"
        loaded = json.loads(hist.read_text())
        assert len(loaded) == 1 and loaded[0]["mode"] == "dns"

    def test_non_list_json_is_quarantined_not_wiped(self, tmp_path):
        import measure

        hist = tmp_path / "history.json"
        hist.write_text('{"not": "a list"}')
        measure.append_history("full", {"x": 1}, history_file=hist)
        assert (tmp_path / "history.json.corrupt").exists()
        loaded = json.loads(hist.read_text())
        assert isinstance(loaded, list) and len(loaded) == 1


# ── watch mode helpers ────────────────────────────────────────────────────────
# Reference implementations of the pure helpers specified in
# docs/FEATURE-SPECS.md '## Watch Mode'. Defined here (not imported from
# netmax.py) so this D5 lane touches only the spec + these offline tests;
# helpers now live in netmax.py (merged by ATLAS) — tests re-pointed below.


from netmax import format_watch_status, summarize_watch_history


class TestWatchHelpers:
    """Offline tests for netmax watch-mode pure helpers (no I/O seams)."""

    def test_format_watch_status_one_line(self, monkeypatch):
        line = format_watch_status(
            ts="14:02:11", cycle=3,
            delta_ms=18.44, grade="B", dns_name="1.1.1.1", dns_ms=12.34,
        )
        assert chr(10) not in line
        assert line == ("[14:02:11] cycle 3: bloat +18.4ms (grade B), "
                        "fastest DNS 1.1.1.1 @ 12.3ms")

    def test_summarize_watch_history(self):
        history = [
            {"delta_ms": 10.0, "grade": "A", "dns_ms": 15.0},
            {"delta_ms": 55.0, "grade": "C", "dns_ms": 25.0},
            {"delta_ms": 30.0, "grade": "B", "dns_ms": 20.0},
        ]
        summary = summarize_watch_history(history)
        assert summary["cycles"] == 3
        assert summary["worst_grade"] == "C"
        assert summary["max_delta_ms"] == pytest.approx(55.0)
        assert summary["median_dns_ms"] == pytest.approx(20.0)
        # even-count median + empty-history sentinel
        even = summarize_watch_history(history[:2])
        assert even["median_dns_ms"] == pytest.approx(20.0)
        assert summarize_watch_history([]) == {"cycles": 0}
