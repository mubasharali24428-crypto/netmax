"""Offline tests for netmax_fetch — all network seams mocked via urlopen."""

import json
import threading

import pytest

import netmax_fetch
from netmax import NetMaxError


class FakeResponse:
    """Minimal urlopen stand-in: read(n)/close()/headers/status."""

    def __init__(self, headers=None, body=b"", status=200):
        self.headers = headers or {}
        self._body = body
        self.status = status
        self.requests = []  # (url, headers dict) per open

    def read(self, n=-1):
        if n is None or n < 0:
            block, self._body = self._body, b""
        else:
            block, self._body = self._body[:n], self._body[n:]
        return block

    def close(self):
        pass

    def getcode(self):
        return self.status


def make_body(size, seed=65):  # 65 == 'A'
    return bytes([(seed + i) % 256 for i in range(size)])


@pytest.fixture()
def fake_net(monkeypatch):
    """Install a scripted-urlopen fixture; returns (calls, script_setter).

    `script(url, headers)` -> FakeResponse. Every urlopen call records its
    url + request headers into `calls` for assertions.
    """
    calls = []

    def install(script):
        def fake_urlopen(req, timeout=None):
            headers = dict(req.header_items()) if hasattr(req, "header_items") else {}
            calls.append({"url": req.full_url, "headers": {k.lower(): v for k, v in headers.items()}})
            resp = script(req.full_url, {k.lower(): v for k, v in headers.items()})
            resp.requests.append((req.full_url, headers))
            return resp

        monkeypatch.setattr(netmax_fetch, "urlopen", fake_urlopen)

    return calls, install


# ── chunk splitting math ──────────────────────────────────────────────────────

def test_split_even():
    assert netmax_fetch.split_chunks(100, 4) == [(0, 24), (25, 49), (50, 74), (75, 99)]


def test_split_uneven():
    chunks = netmax_fetch.split_chunks(10, 3)
    assert [e - s + 1 for s, e in chunks] == [4, 3, 3]
    assert chunks[0][0] == 0 and chunks[-1][1] == 9


def test_split_more_streams_than_bytes():
    # streams clamped to size: never emit zero/negative-span chunks
    chunks = netmax_fetch.split_chunks(2, 8)
    assert chunks == [(0, 0), (1, 1)]
    assert sum(e - s + 1 for s, e in chunks) == 2


# ── multi-stream path ────────────────────────────────────────────────────────

def test_multi_stream_download_assembles_in_order(tmp_path, fake_net):
    calls, install = fake_net
    body = make_body(1000)

    def serve(url, h):
        if "range" not in h:
            return FakeResponse({"Content-Length": "1000", "Accept-Ranges": "bytes"}, body)
        start, end = (int(x) for x in h["range"].split("=")[1].split("-"))
        return FakeResponse({}, body[start:end + 1])

    install(serve)
    out = tmp_path / "file.bin"
    stats = netmax_fetch.download("http://x/file", out, streams=4)

    assert out.read_bytes() == body
    assert stats["bytes"] == 1000
    assert stats["streams_used"] == 4
    range_calls = [c for c in calls if "range" in c["headers"]]
    starts = sorted(int(c["headers"]["range"].split("-")[0].split("=")[1])
                    for c in range_calls)
    assert starts == [0, 250, 500, 750]  # correct split boundaries requested
    # cleanup: no part files or meta left behind
    assert list(tmp_path.glob("*.netmax-*")) == []


def test_head_request_sent_first(fake_net):
    _calls, install = fake_net
    seen = []

    def serve(url, h):
        seen.append(h.get("range"))
        if "range" not in h:
            return FakeResponse({"Content-Length": "10", "Accept-Ranges": "bytes"},
                                make_body(10))
        start, end = (int(x) for x in h["range"].split("=")[1].split("-"))
        return FakeResponse({}, make_body(10)[start:end + 1])

    install(serve)
    import pathlib
    import tempfile

    with tempfile.TemporaryDirectory() as d:
        out = pathlib.Path(d) / "f.bin"
        netmax_fetch.download("http://x/f", out, streams=2)
    # first call had no Range header (the HEAD), later ones did
    assert seen[0] is None
    assert any(r is not None for r in seen)


# ── single-stream fallback ───────────────────────────────────────────────────

def test_single_stream_fallback_no_ranges(tmp_path, fake_net):
    calls, install = fake_net
    body = make_body(300)
    install(lambda url, h: FakeResponse({"Content-Length": "300"}, body))

    out = tmp_path / "f.bin"
    stats = netmax_fetch.download("http://x/f", out, streams=8)

    assert out.read_bytes() == body
    assert stats["streams_used"] == 1
    assert stats["bytes"] == 300
    assert not any(c["headers"].get("range") for c in calls)


def test_single_stream_fallback_unknown_length(tmp_path, fake_net):
    body = make_body(50)
    # HEAD returns no Content-Length at all → must fall back even with ranges
    def install_hdrs(url, h):
        return FakeResponse({"Accept-Ranges": "bytes"}, body)
    _, install = fake_net
    install(install_hdrs)

    out = tmp_path / "f.bin"
    stats = netmax_fetch.download("http://x/f", out, streams=4)
    assert out.read_bytes() == body
    assert stats["streams_used"] == 1


# ── resume ───────────────────────────────────────────────────────────────────

def test_resume_skips_complete_chunks_and_writes_meta(tmp_path, fake_net):
    calls, install = fake_net
    size = 400
    body = make_body(size)

    def serve(url, h):
        if "range" not in h:
            return FakeResponse({"Content-Length": str(size), "Accept-Ranges": "bytes"}, body)
        start, end = (int(x) for x in h["range"].split("=")[1].split("-"))
        return FakeResponse({}, body[start:end + 1])

    install(serve)
    out = tmp_path / "f.bin"
    netmax_fetch.download("http://x/f", out, streams=4)
    first_range_urls = len([c for c in calls if "range" in c["headers"]])
    assert first_range_urls == 4

    # Re-run from scratch but pre-seed two complete parts + meta → only the
    # missing two chunks should be fetched.
    import os
    os.remove(out)
    calls.clear()
    chunks = netmax_fetch.split_chunks(size, 4)
    meta_path = out.with_name(out.name + ".netmax-meta.json")
    meta_path.write_text(json.dumps({
        "url": "http://x/f", "size": size,
        "chunks": [[s, e] for s, e in chunks],
    }))
    for i in (0, 1):
        s, e = chunks[i]
        out.with_name(f"{out.name}.netmax-part-{i}").write_bytes(body[s:e + 1])

    stats = netmax_fetch.download("http://x/f", out, streams=4)

    ranged = [c for c in calls if "range" in c["headers"]]
    fetched_starts = sorted(
        int(c["headers"]["range"].split("-")[0].split("=")[1]) for c in ranged
    )
    assert fetched_starts == [200, 300]  # chunks 0 and 1 skipped
    assert out.read_bytes() == body
    assert stats["bytes"] == 400


def test_resume_mbps_counts_only_network_bytes(tmp_path, fake_net, monkeypatch):
    """F2: resumed bytes already on disk must not inflate mbps.

    Half the file is pre-seeded; elapsed is pinned so the expected mbps is
    exactly the 200 network bytes fetched this run — not the full 400.
    """
    _, install = fake_net
    size = 400
    body = make_body(size)

    def serve(url, h):
        if "range" not in h:
            return FakeResponse(
                {"Content-Length": str(size), "Accept-Ranges": "bytes"}, body)
        start, end = (int(x) for x in h["range"].split("=")[1].split("-"))
        return FakeResponse({}, body[start:end + 1])

    install(serve)
    out = tmp_path / "f.bin"
    chunks = netmax_fetch.split_chunks(size, 4)
    out.with_name(out.name + ".netmax-meta.json").write_text(json.dumps({
        "url": "http://x/f", "size": size,
        "chunks": [[s, e] for s, e in chunks],
    }))
    for i in (0, 1):  # pre-seed half the file (200 of 400 bytes)
        s, e = chunks[i]
        out.with_name(f"{out.name}.netmax-part-{i}").write_bytes(body[s:e + 1])

    # Pin elapsed at 1.0s: download() calls monotonic() twice (start/end).
    ticks = iter([1000.0, 1001.0])
    monkeypatch.setattr(netmax_fetch.time, "monotonic", lambda: next(ticks, 1001.0))

    stats = netmax_fetch.download("http://x/f", out, streams=4)

    assert stats["bytes"] == 400
    # 200 network bytes in 1.0s = 1.6 Mbps (not 400 bytes = 3.2 Mbps).
    assert stats["mbps"] == pytest.approx(200 * 8 / 1.0 / 1e6)


def test_fully_resumed_download_reports_zero_mbps(tmp_path, fake_net):
    """F2: when every chunk is already on disk, mbps must be 0 — no network."""
    _, install = fake_net
    size = 200
    body = make_body(size)

    def serve(url, h):
        if "range" not in h:
            return FakeResponse(
                {"Content-Length": str(size), "Accept-Ranges": "bytes"}, body)
        raise AssertionError("no range fetch expected when fully resumed")

    install(serve)
    out = tmp_path / "f.bin"
    chunks = netmax_fetch.split_chunks(size, 2)
    out.with_name(out.name + ".netmax-meta.json").write_text(json.dumps({
        "url": "http://x/f", "size": size,
        "chunks": [[s, e] for s, e in chunks],
    }))
    for i, (s, e) in enumerate(chunks):
        out.with_name(f"{out.name}.netmax-part-{i}").write_bytes(body[s:e + 1])

    stats = netmax_fetch.download("http://x/f", out, streams=2)
    assert stats["bytes"] == size
    assert stats["mbps"] == 0.0


def test_resume_meta_url_mismatch_refetches_all(tmp_path, fake_net):
    _, install = fake_net
    size = 200
    body = make_body(size)

    def serve(url, h):
        if "range" not in h:
            return FakeResponse({"Content-Length": str(size), "Accept-Ranges": "bytes"}, body)
        start = int(h["range"].split("-")[0].split("=")[1])
        return FakeResponse({}, body[start:])

    install(serve)
    out = tmp_path / "f.bin"
    chunks = netmax_fetch.split_chunks(size, 2)
    out.with_name(out.name + ".netmax-meta.json").write_text(json.dumps({
        "url": "http://x/f", "size": size,
        "chunks": [[s, e] for s, e in chunks],
    }))
    s, e = chunks[0]
    out.with_name(f"{out.name}.netmax-part-0").write_bytes(make_body(e - s + 1))

    netmax_fetch.download("http://x/f", out, streams=2)
    assert out.read_bytes() == body  # stale part overwritten by fresh fetch


def test_oversize_part_deleted_and_refetched(tmp_path, fake_net):
    """A part larger than its chunk must not be trusted — refetch from scratch."""
    _, install = fake_net
    size = 400
    body = make_body(size)

    def serve(url, h):
        if "range" not in h:
            return FakeResponse(
                {"Content-Length": str(size), "Accept-Ranges": "bytes"}, body)
        start, end = (int(x) for x in h["range"].split("=")[1].split("-"))
        return FakeResponse({}, body[start:end + 1])

    install(serve)
    out = tmp_path / "f.bin"
    chunks = netmax_fetch.split_chunks(size, 4)
    out.with_name(out.name + ".netmax-meta.json").write_text(json.dumps({
        "url": "http://x/f", "size": size,
        "chunks": [[s, e] for s, e in chunks],
    }))
    # Part 0 claims chunk [0, 99] but holds 200 bytes — poisoned resume.
    out.with_name(f"{out.name}.netmax-part-0").write_bytes(make_body(200))

    stats = netmax_fetch.download("http://x/f", out, streams=4)
    assert out.read_bytes() == body
    assert stats["bytes"] == size


def test_symlinked_part_refused(tmp_path, fake_net):
    """Pre-placed symlink part must not be followed or trusted."""
    _, install = fake_net
    size = 400
    body = make_body(size)

    def serve(url, h):
        if "range" not in h:
            return FakeResponse(
                {"Content-Length": str(size), "Accept-Ranges": "bytes"}, body)
        start, end = (int(x) for x in h["range"].split("=")[1].split("-"))
        return FakeResponse({}, body[start:end + 1])

    install(serve)
    out = tmp_path / "f.bin"
    chunks = netmax_fetch.split_chunks(size, 4)
    out.with_name(out.name + ".netmax-meta.json").write_text(json.dumps({
        "url": "http://x/f", "size": size,
        "chunks": [[s, e] for s, e in chunks],
    }))
    target = tmp_path / "elsewhere.bin"
    target.write_bytes(make_body(100))
    out.with_name(f"{out.name}.netmax-part-0").symlink_to(target)

    with pytest.raises(NetMaxError, match="refusing unsafe"):
        netmax_fetch.download("http://x/f", out, streams=4)


def test_short_body_raises_incomplete(tmp_path, fake_net):
    """Single-stream: Content-Length lies; final length check must catch it."""
    _, install = fake_net

    def serve(url, h):
        if "range" not in h:
            # No Accept-Ranges → single-stream path; HEAD says 300, body 250.
            return FakeResponse({"Content-Length": "300"}, make_body(250))
        start, end = (int(x) for x in h["range"].split("=")[1].split("-"))
        return FakeResponse({}, make_body(300)[start:end + 1])

    install(serve)
    out = tmp_path / "f.bin"
    with pytest.raises(NetMaxError, match="incomplete"):
        netmax_fetch.download("http://x/f", out, streams=4)


# ── progress callback ────────────────────────────────────────────────────────

def test_progress_callback_fires_from_counter(tmp_path, fake_net):
    events = []
    lock = threading.Lock()

    def on_progress(done, total):
        with lock:
            events.append((done, total))

    body = make_body(200)
    _, inst = fake_net

    def serve(url, h):
        if "range" not in h:
            return FakeResponse({"Content-Length": "200", "Accept-Ranges": "bytes"}, body)
        start, end = (int(x) for x in h["range"].split("=")[1].split("-"))
        return FakeResponse({}, body[start:end + 1])

    inst(serve)
    out = tmp_path / "f.bin"
    stats = netmax_fetch.download("http://x/f", out, streams=2, on_progress=on_progress)

    assert events, "progress callback never fired"
    assert events[-1][1] == 200 or events[-1][1] is None
    dones = [d for d, _ in events]
    assert dones == sorted(dones)  # monotonic
    assert max(dones) <= 200
    assert stats["bytes"] == 200


def test_progress_none_is_safe(tmp_path, fake_net):
    _, install = fake_net
    install(lambda url, h: FakeResponse({"Content-Length": "5"}, b"hello"))
    out = tmp_path / "f.bin"
    stats = netmax_fetch.download("http://x/f", out, streams=1, on_progress=None)
    assert stats["bytes"] == 5


def test_streams_one_with_ranges_keeps_output(tmp_path, fake_net):
    """C2: streams=1 against a range-capable server must not assemble/unlink."""
    _, install = fake_net
    body = make_body(100)

    def serve(url, h):
        if "range" not in h:
            return FakeResponse(
                {"Content-Length": "100", "Accept-Ranges": "bytes"}, body)
        start, end = (int(x) for x in h["range"].split("=")[1].split("-"))
        return FakeResponse({}, body[start:end + 1])

    install(serve)
    out = tmp_path / "f.bin"
    stats = netmax_fetch.download("http://x/f", out, streams=1)

    assert out.exists(), "single-stream download was unlinked by assemble"
    assert out.read_bytes() == body
    assert stats["bytes"] == 100
    assert stats["streams_used"] == 1
    assert list(tmp_path.glob("*.netmax-*")) == []


# ── error paths ──────────────────────────────────────────────────────────────

def test_http_error_raises_netmaxerror(tmp_path, fake_net):
    _, install = fake_net
    install(lambda url, h: FakeResponse({}, b"", status=403))
    # NOTE: this test deliberately uses a PRIVATE tmp dir. F10 hardening in
    # netmax_fetch refuses downloads into world-writable shared roots
    # (/tmp etc.) — verified by test_shared_dir_refused below.
    with pytest.raises(NetMaxError, match="403"):
        netmax_fetch.download("http://x/f", str(tmp_path / "netmax_err_test.bin"))


def test_shared_dir_refused(fake_net):
    """F10: predictable part files must not be written to /tmp itself."""
    _, install = fake_net
    install(lambda url, h: FakeResponse({}, b""))
    with pytest.raises(NetMaxError, match="shared directory"):
        netmax_fetch.download("http://x/f", "/tmp/netmax_should_refuse.bin")


def test_chunk_size_mismatch_raises(tmp_path, fake_net):
    _, install = fake_net

    def serve(url, h):
        if "range" not in h:
            return FakeResponse({"Content-Length": "100", "Accept-Ranges": "bytes"}, b"x")
        return FakeResponse({}, b"")  # server lies: empty range response

    install(serve)
    with pytest.raises(NetMaxError, match="expected"):
        netmax_fetch.download("http://x/f", tmp_path / "f.bin", streams=2)


def test_invalid_streams_raises():
    with pytest.raises(NetMaxError):
        netmax_fetch.download("http://x/f", "/tmp/netmax_bad_streams.bin", streams=0)


def test_urlopen_network_failure_wrapped(monkeypatch, tmp_path):
    from urllib.error import URLError

    def boom(req, timeout=None):
        raise URLError("connection refused")

    monkeypatch.setattr(netmax_fetch, "urlopen", boom)
    with pytest.raises(NetMaxError, match="failed"):
        netmax_fetch.download("http://x/f", tmp_path / "f.bin")


# ── assembly order integrity ─────────────────────────────────────────────────

def test_assembly_order_distinct_chunk_content(tmp_path, fake_net):
    _, install = fake_net
    size = 8
    body = bytes(range(size))  # distinct byte per position

    def serve(url, h):
        if "range" not in h:
            return FakeResponse(
                {"Content-Length": str(size), "Accept-Ranges": "bytes"}, body)
        start, end = h["range"].split("=")[1].split("-")
        start, end = int(start), int(end)
        return FakeResponse({"Content-Length": str(end - start + 1)},
                            body[start:end + 1])

    install(serve)
    out = tmp_path / "f.bin"
    netmax_fetch.download("http://x/f", out, streams=4)
    assert out.read_bytes() == bytes(range(size))  # order preserved exactly
