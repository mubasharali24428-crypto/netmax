"""Regression tests for deferred debt: --adaptive, _truncate budget, IncompleteRead."""

from __future__ import annotations

import http.client

import pytest

import netmax
import netmax_bundle
import netmax_fetch
import netmax_throttle
from netmax import NetMaxError


# ── _truncate honors budget at every depth ───────────────────────────────────

def test_truncate_budget_top_level_string():
    out = netmax_bundle._truncate("x" * 50, budget=10)
    assert out.startswith("x" * 10)
    assert "truncated" in out
    assert len(out) < 50


def test_truncate_budget_applies_to_nested_values():
    nested = {"a": "y" * 100, "b": ["z" * 80, {"c": "w" * 60}]}
    out = netmax_bundle._truncate(nested, budget=20)
    assert out["a"].startswith("y" * 20)
    assert out["a"].endswith("chars truncated]")
    assert out["b"][0].startswith("z" * 20)
    assert out["b"][1]["c"].startswith("w" * 20)
    # Budget must be honored — not silently fall back to MAX_STR for nested.
    for leaf in (out["a"], out["b"][0], out["b"][1]["c"]):
        body = leaf.split(" ...[")[0]
        assert len(body) <= 20


def test_truncate_default_budget_is_max_str():
    long = "q" * (netmax_bundle.MAX_STR + 10)
    out = netmax_bundle._truncate(long)
    assert out.startswith("q" * netmax_bundle.MAX_STR)
    assert "[+10 chars truncated]" in out


def test_truncate_tuple_and_list_budget():
    out = netmax_bundle._truncate(("t" * 40, ["l" * 40]), budget=5)
    assert out[0].startswith("t" * 5)
    assert out[1][0].startswith("l" * 5)


# ── IncompleteRead → NetMaxError ─────────────────────────────────────────────

class IncompleteReadResponse:
    """Fake urlopen body that raises IncompleteRead on first read."""

    def __init__(self, headers=None, status=200):
        self.headers = headers or {}
        self.status = status

    def read(self, n=-1):
        raise http.client.IncompleteRead(b"partial", 100)

    def close(self):
        pass

    def getcode(self):
        return self.status


def test_incomplete_read_wrapped_as_netmaxerror_single_stream(monkeypatch, tmp_path):
    def fake_urlopen(req, timeout=None):
        return IncompleteReadResponse({"Content-Length": "1000"})

    monkeypatch.setattr(netmax_fetch, "urlopen", fake_urlopen)
    with pytest.raises(NetMaxError, match="mid-read|read failed"):
        netmax_fetch.download("http://x/f", tmp_path / "f.bin")


class RangeIncomplete:
    """HEAD ok + ranges, range GET raises IncompleteRead mid-body."""

    def __init__(self, headers=None, body=b"", status=200, incomplete=False):
        self.headers = headers or {}
        self._body = body
        self.status = status
        self._incomplete = incomplete

    def read(self, n=-1):
        if self._incomplete:
            raise http.client.IncompleteRead(b"xx", 10)
        if n is None or n < 0:
            block, self._body = self._body, b""
        else:
            block, self._body = self._body[:n], self._body[n:]
        return block

    def close(self):
        pass

    def getcode(self):
        return self.status


def test_incomplete_read_wrapped_in_multi_stream_chunk(monkeypatch, tmp_path):
    body = b"A" * 100

    def fake_urlopen(req, timeout=None):
        headers = dict(req.header_items()) if hasattr(req, "header_items") else {}
        lower = {k.lower(): v for k, v in headers.items()}
        if "range" not in lower:
            return RangeIncomplete(
                {"Content-Length": "100", "Accept-Ranges": "bytes"}, body)
        return RangeIncomplete({}, b"", incomplete=True)

    monkeypatch.setattr(netmax_fetch, "urlopen", fake_urlopen)
    with pytest.raises(NetMaxError, match="mid-read"):
        netmax_fetch.download("http://x/f", tmp_path / "f.bin", streams=2)


def test_read_block_maps_oserror(monkeypatch):
    class OSErrResp:
        def read(self, n=-1):
            raise OSError("broken pipe")

        def close(self):
            pass

    with pytest.raises(NetMaxError, match="read failed"):
        netmax_fetch._read_block(OSErrResp())


# ── --adaptive: AdaptiveController initial_streams + CLI wiring ─────────────

def test_adaptive_controller_initial_streams():
    c = netmax_throttle.AdaptiveController(
        min_streams=1, max_streams=8, initial_streams=8)
    assert c.current() == 8


def test_adaptive_controller_initial_out_of_range():
    with pytest.raises(ValueError, match="initial_streams"):
        netmax_throttle.AdaptiveController(
            min_streams=2, max_streams=4, initial_streams=9)


def test_adaptive_backoff_from_initial_on_bad_latency():
    c = netmax_throttle.AdaptiveController(
        min_streams=1, max_streams=8, initial_streams=8)
    c.feed(400.0, 0.0)
    assert c.current() == 7
    assert "backoff" in c.reason


def test_fetch_adaptive_flag_parsed():
    """--adaptive must be accepted by the fetch subparser (was dead)."""
    import contextlib
    import io

    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), \
            pytest.raises(SystemExit) as exc:
        netmax.main(["fetch", "--help"])
    assert exc.value.code == 0
    text = out.getvalue() + err.getvalue()
    assert "--adaptive" in text
    assert "auto-adjust stream count" in text


def test_adaptive_cli_uses_controller(monkeypatch, tmp_path):
    """End-to-end-ish: fetch --adaptive probes then downloads with adjusted streams."""
    seen = {}

    class FakeResp:
        def __init__(self, headers=None, body=b""):
            self.headers = headers or {}
            self._body = body
            self.status = 200

        def read(self, n=-1):
            if n is None or n < 0:
                block, self._body = self._body, b""
            else:
                block, self._body = self._body[:n], self._body[n:]
            return block

        def close(self):
            pass

        def getcode(self):
            return 200

    body = b"B" * 200

    def fake_urlopen(req, timeout=None):
        headers = dict(req.header_items()) if hasattr(req, "header_items") else {}
        lower = {k.lower(): v for k, v in headers.items()}
        if "range" not in lower:
            return FakeResp(
                {"Content-Length": "200", "Accept-Ranges": "bytes"}, body)
        start, end = (int(x) for x in lower["range"].split("=")[1].split("-"))
        return FakeResp({}, body[start:end + 1])

    monkeypatch.setattr(netmax_fetch, "urlopen", fake_urlopen)

    def fake_feedback(host="1.1.1.1", count=3):
        # High latency → controller must back off from requested 8.
        seen["probed"] = True
        return 450.0, 0.0

    monkeypatch.setattr(netmax_throttle, "measure_feedback", fake_feedback)

    real_download = netmax_fetch.download

    def spy_download(url, out_path, streams=8, on_progress=None):
        seen["streams"] = streams
        return real_download(url, out_path, streams=streams,
                             on_progress=on_progress)

    monkeypatch.setattr(netmax_fetch, "download", spy_download)

    # Invoke the same branch netmax.main uses for fetch --adaptive by
    # calling main with argv (network fully mocked above).
    out = tmp_path / "adaptive.bin"
    argv = ["fetch", "http://x/file.bin", str(out),
            "--streams", "8", "--adaptive"]
    monkeypatch.setattr("sys.argv", ["netmax", *argv])
    netmax.main(argv)

    assert seen.get("probed") is True
    # 8 requested, high latency → one-step backoff → 7.
    assert seen["streams"] == 7
    assert out.exists()


def test_adaptive_probe_failure_falls_back(monkeypatch, tmp_path):
    """Probe raising NetMaxError must not abort the download."""
    seen = {}

    class FakeResp:
        def __init__(self, headers=None, body=b""):
            self.headers = headers or {}
            self._body = body
            self.status = 200

        def read(self, n=-1):
            if n is None or n < 0:
                block, self._body = self._body, b""
            else:
                block, self._body = self._body[:n], self._body[n:]
            return block

        def close(self):
            pass

        def getcode(self):
            return 200

    body = b"C" * 50

    def fake_urlopen(req, timeout=None):
        headers = dict(req.header_items()) if hasattr(req, "header_items") else {}
        lower = {k.lower(): v for k, v in headers.items()}
        if "range" not in lower:
            return FakeResp({"Content-Length": "50"}, body)
        return FakeResp({}, body)

    monkeypatch.setattr(netmax_fetch, "urlopen", fake_urlopen)

    def boom(host="1.1.1.1", count=3):
        raise NetMaxError("ping unavailable")

    monkeypatch.setattr(netmax_throttle, "measure_feedback", boom)

    real_download = netmax_fetch.download

    def spy_download(url, out_path, streams=8, on_progress=None):
        seen["streams"] = streams
        return real_download(url, out_path, streams=streams,
                             on_progress=on_progress)

    monkeypatch.setattr(netmax_fetch, "download", spy_download)

    out = tmp_path / "fallback.bin"
    netmax.main(["fetch", "http://x/f", str(out), "--streams", "4", "--adaptive"])
    assert seen["streams"] == 4  # unchanged when probe fails
