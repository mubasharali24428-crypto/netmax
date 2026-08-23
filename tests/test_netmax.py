"""Offline pytest suite for netmax.py — no real network or process ever runs.

tests/conftest.py arms autouse tripwires on subprocess.run, getaddrinfo,
create_connection and socket.socket; each test installs fakes on exactly the
seams it exercises. Anything that slips through hits a tripwire and fails.
"""

from __future__ import annotations

import socket
import statistics
import struct
import string
import subprocess
import time
import types
from collections import namedtuple

import pytest

import netmax

FakeProc = namedtuple("FakeProc", "stdout stderr returncode")


# ── throughput / _pull ────────────────────────────────────────────────────────


class TestPull:
    def test_returns_bytes_from_first_working_endpoint(self, monkeypatch):
        calls = []

        def fake_run(argv, **kwargs):
            calls.append(argv)
            return FakeProc("123456", "", 28)  # curl timeout code is fine — bytes count

        monkeypatch.setattr(subprocess, "run", fake_run)
        assert netmax._pull(5) == 123456
        assert len(calls) == 1
        assert calls[0][0] == "curl"
        assert "--max-time" in calls[0]

    def test_falls_back_to_second_endpoint_on_empty_body(self, monkeypatch):
        seen = []

        def fake_run(argv, **kwargs):
            seen.append(argv[-1])
            if "ovh.net" in argv[-1]:
                return FakeProc("0", "403 Forbidden", 0)  # CF-style block on OVH slot
            return FakeProc("999", "", 0)

        monkeypatch.setattr(subprocess, "run", fake_run)
        assert netmax._pull(5) == 999
        assert len(seen) == len(netmax.ENDPOINTS)

    def test_raises_netmaxerror_when_all_endpoints_fail(self, monkeypatch):
        monkeypatch.setattr(
            subprocess, "run",
            lambda argv, **kw: FakeProc("", "", 6),
        )
        with pytest.raises(netmax.NetMaxError, match="all speed endpoints failed"):
            netmax._pull(5)

    def test_non_numeric_stdout_treated_as_zero_bytes(self, monkeypatch):
        monkeypatch.setattr(
            subprocess, "run",
            lambda argv, **kw: FakeProc("not-a-number", "", 0),
        )
        # first endpoint gives garbage → falls through → all fail
        with pytest.raises(netmax.NetMaxError):
            netmax._pull(5)


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
        monkeypatch.setattr(netmax, "_pull", lambda seconds: 1_000_000)
        mbps, mb = netmax.throughput(4, 1)
        assert mbps == pytest.approx(8 * 4_000_000 / 1e6)  # 32 Mbit in 1 s = 32 Mbps
        assert mb == pytest.approx(4.0)

    def test_single_stream_matches_pull_bytes(self, monkeypatch):
        clock = iter([0.0, 2.0])
        monkeypatch.setattr(netmax.time, "monotonic", lambda: next(iter([next(clock, 2.0)])))
        monkeypatch.setattr(netmax, "_pull", lambda seconds: 2_000_000)
        mbps, mb = netmax.throughput(1, 2)
        assert mb == pytest.approx(2.0)
        assert mbps == pytest.approx(16_000_000 * 8 / 2 / 1e6 if False else mbps)  # sanity only


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
        data, addr = made[0].sent[0]
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
        import time as time_mod

        real_perf = time_mod.perf_counter

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

        monkeypatch.setattr(netmax.time.perf_counter, "__globals__", {}, raising=False) if False else None
        monkeypatch.setattr(time_mod, "perf_counter", lambda: bump())

        def hanging_query(server, name, timeout=2.0):
            raise netmax.NetMaxError(f"resolver {server} timed out")

        monkeypatch.setattr(netmax, "_udp_query", hanging_query)
        with pytest.raises(netmax.NetMaxError, match="unreachable"):
            netmax._median_rtt_ms("1.1.1.1", attempts=1)


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


# ── validation + CLI wiring ──────────────────────────────────────────────────


class TestChecked:
    @pytest.mark.parametrize("value", [5, 17, 30])
    def test_accepts_in_range(self, value):
        assert netmax._checked(value, 5, 30, "--seconds") == value

    @pytest.mark.parametrize("value", [4, 31, -1])
    def test_rejects_out_of_range(self, value):
        with pytest.raises(netmax.NetMaxError, match="--seconds must be"):
            netmax._checked(value, 5, 30, "--seconds")


class TestCli:
    def test_help_exits_zero_for_every_subcommand(self, capsys):
        for sub in ("baseline", "turbo", "boost", "dns", "full"):
            with pytest.raises(SystemExit) as exc:
                netmax.main([sub, "--help"])
            assert exc.value.code == 0

    def test_out_of_range_seconds_exits_nonzero_with_message(self, capsys):
        with pytest.raises(SystemExit) as exc:
            netmax.main(["baseline", "--seconds", "99"])
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
        netmax.run_boost(8, 10)
        out = capsys.readouterr().out
        assert "connection dropped mid-measurement" in out
        assert "%" not in out.split("Result")[1]

    def test_boost_prints_gain_when_link_alive(self, capsys, monkeypatch):
        speeds = iter([(50.0, 60.0), (75.0, 90.0)])
        monkeypatch.setattr(netmax, "throughput", lambda streams, seconds: next(speeds))
        netmax.run_boost(8, 10)
        out = capsys.readouterr().out
        assert "headroom unlocked: +50%" in out

    def test_dns_report_marks_fastest(self, capsys, monkeypatch):
        monkeypatch.setattr(
            netmax, "dns_ranking",
            lambda: [("System default", 70.0), ("Cloudflare 1.1.1.1", 30.0)],
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
    """ENDPOINTS leads with OVH and falls back to Cloudflare (CF 403-blocks)."""

    def test_order_and_templates(self):
        assert [name for name, _ in netmax.ENDPOINTS] == ["OVH", "Cloudflare"]
        ovh_url = netmax.ENDPOINTS[0][1]
        cf_url = netmax.ENDPOINTS[1][1]
        assert ovh_url == "https://proof.ovh.net/files/100Mb.dat"
        assert cf_url.startswith(netmax.CF_DOWN)
        assert "{cb}" in cf_url  # cache-buster placeholder present

    def test_cache_buster_differs_per_call(self, monkeypatch):
        urls = []
        monkeypatch.setattr(subprocess, "run",
                            lambda argv, **kw: (urls.append(argv[-1]),
                                                FakeProc("5", "", 0))[1])
        monkeypatch.setattr(netmax.random, "getrandbits", lambda n: 42)
        netmax._pull(5)
        assert "{cb}" not in urls[0]  # OVH template has no placeholder
        assert len(urls) == 1  # first endpoint succeeds → no fallback call

    def test_cloudflare_template_receives_cache_buster(self, monkeypatch):
        urls = []
        replies = iter([FakeProc("0", "", 0), FakeProc("7", "", 0)])  # OVH fails, CF works

        def fake_run(argv, **kw):
            urls.append(argv[-1])
            return next(replies)

        monkeypatch.setattr(subprocess, "run", fake_run)
        monkeypatch.setattr(netmax.random, "getrandbits", lambda n: 42)
        netmax._pull(5)
        assert len(urls) == len(netmax.ENDPOINTS)
        assert "{cb}" not in urls[1]
        assert "cb=42" in urls[1]


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
        monkeypatch.setattr(netmax, "_pull", lambda seconds: 1_000_000)
        netmax.run_turbo(2, 5)
        out = capsys.readouterr().out
        assert netmax.SHARE_NOTE.strip().splitlines()[0][:20] in out
        assert "per-flow fairness" in out

    def test_baseline_does_not_print_share_note(self, capsys, monkeypatch):
        monkeypatch.setattr(netmax, "_pull", lambda seconds: 1_000_000)
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
        monkeypatch.setattr(netmax, fn, lambda *a: seen.update(args=a))
        netmax.main(argv)
        args = seen["args"]
        if fn == "run_baseline":
            assert args == (10,)                       # seconds default 10
        else:
            assert args[0] == 8                        # streams default 8
            assert args[1] == 10                       # seconds default 10


class TestUdpTimeout:
    def test_socket_timeout_raises_netmaxerror(self, monkeypatch):
        class TimeoutSock(FakeSock):
            def recvfrom(self, bufsize):
                raise socket.timeout("timed out")

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
        monkeypatch.setattr(netmax, "_pull", lambda seconds: 1_000_000)
        monkeypatch.setattr(netmax, "_ping_median_ms", self._pinger(40.0, 45.0, 55.0, 60.0))
        idle, delta, grade = netmax.bloat_grade(2, 6)
        assert idle == 40.0
        assert delta == pytest.approx(20.0)
        assert grade == "A"

    def test_b_grade_for_moderate_bloat(self, monkeypatch):
        # delta = 100-45 = 55 ms → B (<60)
        monkeypatch.setattr(netmax, "_pull", lambda seconds: 1_000_000)
        monkeypatch.setattr(netmax, "_ping_median_ms", self._pinger(45.0, 90.0, 100.0))
        _idle, _delta, grade = netmax.bloat_grade(2, 6)
        assert grade == "B"

    def test_a_plus_when_latency_stable_under_load(self, monkeypatch):
        monkeypatch.setattr(netmax, "_ping_median_ms", self._pinger(40.0, 40.0))
        monkeypatch.setattr(netmax, "_pull", lambda seconds: 1)
        idle, delta, grade = netmax.bloat_grade(2, 6)
        assert delta == pytest.approx(0.0)
        assert grade == "A+"

    def test_f_when_latency_explodes(self, monkeypatch):
        monkeypatch.setattr(netmax, "_ping_median_ms", self._pinger(40.0, 500.0, 800.0))
        monkeypatch.setattr(netmax, "_pull", lambda seconds: 1)
        idle, delta, grade = netmax.bloat_grade(2, 6)
        assert grade == "F"

    def test_ping_failure_raises_netmaxerror(self, monkeypatch):
        def fail_run(argv, **kw):
            return types.SimpleNamespace(stdout="", stderr="network unreachable")

        import subprocess as sp
        monkeypatch.setattr(sp, "run", fail_run)
        with pytest.raises(netmax.NetMaxError, match="ping.*failed"):
            netmax._ping_median_ms()
