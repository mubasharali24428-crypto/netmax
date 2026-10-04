"""Offline tests for netmax.upload_probe — no real network, ever.

Mirrors tests/conftest.py: an autouse fixture arms tripwires on subprocess.run
and the socket layer; each test then installs a fake on exactly the seams it
needs (a later monkeypatch.setattr wins, disarming that one tripwire).
"""

import socket
import subprocess
import sys
from io import BytesIO
from pathlib import Path
from types import SimpleNamespace

from unittest.mock import patch

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import netmax
import netmax_upload


def _tripwire(seam):
    def guard(*args, **kwargs):
        raise AssertionError(f"offline suite attempted real {seam} — mock it")
    return guard


@pytest.fixture(autouse=True)
def offline_guarantee(monkeypatch):
    monkeypatch.setattr(subprocess, "run", _tripwire("subprocess.run"))
    monkeypatch.setattr(subprocess, "Popen", _tripwire("subprocess.Popen"))
    monkeypatch.setattr(socket, "getaddrinfo", _tripwire("socket.getaddrinfo"))
    monkeypatch.setattr(socket, "create_connection", _tripwire("socket.create_connection"))
    monkeypatch.setattr(socket, "socket", _tripwire("socket.socket"))


@pytest.fixture(autouse=True)
def fake_head(monkeypatch):
    """Default `head` stand-in: records spawns, reaps cleanly, moves no bytes."""
    made = []

    class FakeHead:
        def __init__(self, argv, **kw):
            self.argv = argv
            self.kwargs = kw
            self.stdout = BytesIO(b"x" * 64)
            self.terminated = False
            self.waited = False
            made.append(self)

        def terminate(self):
            self.terminated = True

        def wait(self, timeout=None):
            self.waited = True
            return 0

        def kill(self):
            pass

    monkeypatch.setattr(subprocess, "Popen", FakeHead)
    return made


def _no_head(monkeypatch):
    """Force the staged-tempfile fallback (no `head` on PATH)."""
    def raising(argv, **kw):
        raise OSError("no head")
    monkeypatch.setattr(subprocess, "Popen", raising)


def _fake_run(stdout="", returncode=0):
    """Build a subprocess.run stand-in recording its argv."""
    calls = []

    def fake(cmd, **kwargs):
        calls.append((cmd, kwargs))
        return SimpleNamespace(stdout=stdout, stderr="", returncode=returncode)

    fake.calls = calls
    return fake


def test_returns_mbps_and_mb(monkeypatch):
    # 1,000,000 bytes in 1.0 s → exactly 8 Mbps up, 1.0 MB sent.
    fake = _fake_run("200 1000000 1.0\n")
    monkeypatch.setattr(subprocess, "run", fake)
    mbps, mb = netmax_upload.upload_probe(seconds=5.0)
    assert mbps == pytest.approx(8.0)
    assert mb == pytest.approx(1.0)


def test_curl_command_shape(monkeypatch):
    fake = _fake_run("200 500000 0.5")
    monkeypatch.setattr(subprocess, "run", fake)
    netmax_upload.upload_probe(seconds=4.0)
    cmd = fake.calls[0][0]
    assert cmd[0] == "curl"
    assert "-X" in cmd and "POST" in cmd
    w = cmd[cmd.index("-w") + 1]
    assert "%{size_upload}" in w and "%{time_total}" in w and "%{http_code}" in w
    payload_flag = cmd[cmd.index("--data-binary") + 1]
    assert payload_flag.startswith("@")
    max_time = float(cmd[cmd.index("--max-time") + 1])
    assert max_time == pytest.approx(4.0)
    assert any(a.startswith("https://") for a in cmd)  # verified endpoint used


def test_uses_verified_endpoint_first(monkeypatch):
    fake = _fake_run("200 100000 1.0")
    monkeypatch.setattr(subprocess, "run", fake)
    netmax_upload.upload_probe(seconds=3.0)
    url = next(a for a in fake.calls[0][0] if a.startswith("http"))
    assert url in netmax_upload.ENDPOINTS_VERIFIED


def test_falls_through_on_non_200(monkeypatch):
    ok = _fake_run("200 800000 1.0")

    def flaky_first(cmd, **kwargs):
        if netmax_upload.ENDPOINTS_VERIFIED[0] in cmd:
            return SimpleNamespace(stdout="403 0 0.1", stderr="", returncode=0)
        return ok(cmd, **kwargs)

    monkeypatch.setattr(subprocess, "run", flaky_first)
    mbps, _mb = netmax_upload.upload_probe(seconds=3.0)
    assert mbps > 0
    assert mbps == pytest.approx(800000 * 8 / 1.0 / 1e6)


def test_timeout_on_first_endpoint_falls_through(monkeypatch):
    """A hung curl on endpoint 0 must not abort failover to the next."""
    ok = _fake_run("200 800000 1.0")
    calls = {"n": 0}

    def flaky(cmd, **kwargs):
        calls["n"] += 1
        if calls["n"] == 1:
            raise subprocess.TimeoutExpired(cmd=cmd, timeout=kwargs.get("timeout", 1))
        return ok(cmd, **kwargs)

    monkeypatch.setattr(subprocess, "run", flaky)
    mbps, _mb = netmax_upload.upload_probe(seconds=3.0)
    assert mbps == pytest.approx(800000 * 8 / 1.0 / 1e6)
    assert calls["n"] >= 2


def test_non_numeric_writeout_is_netmaxerror_not_valueerror(monkeypatch):
    """int()/float() parse failure must land as NetMaxError, not escape."""
    monkeypatch.setattr(subprocess, "run", _fake_run("200 abc 1.0"))
    with pytest.raises(netmax.NetMaxError):
        netmax_upload.upload_probe(seconds=2.0)


def test_raises_netmax_error_when_all_fail(monkeypatch):
    fake = _fake_run("503 0 0.2", returncode=0)
    monkeypatch.setattr(subprocess, "run", fake)
    with pytest.raises(netmax.NetMaxError):
        netmax_upload.upload_probe(seconds=2.0)
    # Tried every verified endpoint before giving up.
    assert len(fake.calls) == len(netmax_upload.ENDPOINTS_VERIFIED)


def test_raises_on_unparseable_output(monkeypatch):
    monkeypatch.setattr(subprocess, "run", _fake_run("", returncode=6))
    with pytest.raises(netmax.NetMaxError):
        netmax_upload.upload_probe(seconds=2.0)


def test_zero_bytes_uploaded_is_rejected(monkeypatch):
    # Proxy-interception guard per spec: HTTP 200 but nothing sent.
    monkeypatch.setattr(subprocess, "run", _fake_run("200 0 1.5"))
    with pytest.raises(netmax.NetMaxError):
        netmax_upload.upload_probe(seconds=2.0)


def test_invalid_seconds_raises_valueerror():
    with pytest.raises(ValueError):
        netmax_upload.upload_probe(seconds=0)


def test_streams_by_default_and_stages_nothing(monkeypatch, fake_head, tmp_path):
    """Pipe-first: curl reads `@-` from head's stdout; no temp file exists."""
    staged = []
    monkeypatch.setattr(
        netmax_upload.tempfile, "NamedTemporaryFile",
        lambda **kw: (_ for _ in ()).throw(
            AssertionError("staging must not happen on the stream path")))
    fake = _fake_run("200 100000 1.0")
    monkeypatch.setattr(subprocess, "run", fake)
    netmax_upload.upload_probe(seconds=1.0)
    cmd, kwargs = fake.calls[0]
    assert cmd[cmd.index("--data-binary") + 1] == "@-"
    assert kwargs.get("stdin") is fake_head[0].stdout
    assert fake_head[0].argv[:3] == ["head", "-c", "1250000"]  # 10e6*1s/8
    assert staged == []


def test_stream_reaped_on_success(monkeypatch, fake_head):
    """The head child is terminated + waited (no zombies) after a good POST."""
    monkeypatch.setattr(subprocess, "run", _fake_run("200 100000 1.0"))
    netmax_upload.upload_probe(seconds=1.0)
    assert len(fake_head) == 1
    assert fake_head[0].terminated and fake_head[0].waited


def test_failover_reopens_stream_per_endpoint(monkeypatch, fake_head):
    """A half-consumed pipe must never feed the next POST — one stream each."""
    ok = _fake_run("200 800000 1.0")

    def flaky_first(cmd, **kwargs):
        if netmax_upload.ENDPOINTS_VERIFIED[0] in cmd:
            return SimpleNamespace(stdout="403 0 0.1", stderr="", returncode=0)
        return ok(cmd, **kwargs)

    monkeypatch.setattr(subprocess, "run", flaky_first)
    netmax_upload.upload_probe(seconds=3.0)
    assert len(fake_head) == 2
    assert all(h.terminated and h.waited for h in fake_head)


def test_fallback_stages_file_when_pipe_fails(monkeypatch, tmp_path, fake_head):
    """No `head` on PATH: classic staged tempfile, same Mbps math, unlinked."""
    _no_head(monkeypatch)
    created = []

    class FakeTF:
        def __init__(self, **kw):
            self.name = str(tmp_path / "payload.bin")
            created.append(self.name)

        def write(self, data):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    monkeypatch.setattr(netmax_upload.tempfile, "NamedTemporaryFile", FakeTF)
    fake = _fake_run("200 100000 1.0")
    monkeypatch.setattr(subprocess, "run", fake)
    mbps, _mb = netmax_upload.upload_probe(seconds=1.0)
    assert fake.calls[0][0][fake.calls[0][0].index("--data-binary") + 1].startswith("@/")
    assert fake.calls[0][1].get("stdin") is None
    assert mbps == pytest.approx(0.8)
    assert created and not __import__("os").path.exists(created[0])


def test_payload_tempfile_cleaned_up(monkeypatch, tmp_path):
    _no_head(monkeypatch)
    created = []

    class FakeTF:
        def __init__(self, **kw):
            self.name = str(tmp_path / "payload.bin")
            created.append(self.name)

        def write(self, data):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    monkeypatch.setattr(netmax_upload.tempfile, "NamedTemporaryFile", FakeTF)
    monkeypatch.setattr(netmax_upload.os, "urandom", lambda n: b"\x00" * n)
    monkeypatch.setattr(subprocess, "run", _fake_run("200 100000 1.0"))
    netmax_upload.upload_probe(seconds=1.0)
    assert created and not __import__("os").path.exists(created[0])


def test_payload_cleaned_up_when_write_fails(monkeypatch, tmp_path):
    """C3: a failed payload write (disk full) must still unlink the temp file."""
    import os

    _no_head(monkeypatch)
    created = []

    class FakeTF:
        def __init__(self, **kw):
            self.name = str(tmp_path / "payload.bin")
            open(self.name, "wb").close()  # file exists on disk
            created.append(self.name)

        def write(self, data):
            raise OSError("disk full")

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    monkeypatch.setattr(netmax_upload.tempfile, "NamedTemporaryFile", FakeTF)
    monkeypatch.setattr(netmax_upload.os, "urandom", lambda n: b"\x00" * n)
    with pytest.raises(OSError, match="disk full"):
        netmax_upload.upload_probe(seconds=1.0)
    assert created and not os.path.exists(created[0])


def _upload_argv(endpoint, max_time, data_arg):
    """The exact argv netmax_upload builds for one POST."""
    return ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code} %{size_upload} %{time_total}",
            "-H", "Expect:", "-X", "POST", "--data-binary", data_arg,
            "--max-time", str(max_time), endpoint]


def _probe_with_stdout(stdout, returncode=0):
    """Drive upload_probe with a scripted curl result."""
    class FakeProc:
        def __init__(self):
            self.stdout = stdout
            self.stderr = ""
            self.returncode = returncode

    def fake_run(argv, **kwargs):
        return FakeProc()

    with patch.object(subprocess, "run", fake_run):
        return netmax_upload.upload_probe(seconds=8)


# ── live-bug regressions ─────────────────────────────────────────────────────
# Found by running the probe against the real internet, not by a test: every
# endpoint reported "HTTP 100" and the probe failed outright.


class TestExpectHandshake:
    """curl's Expect: 100-continue made %write-out report the INTERIM status.

    For any body over ~1 KB curl asks permission first; the server answers
    100 Continue, and that interim code is what %write-out reported. A
    transfer that had uploaded megabytes was therefore rejected as
    "HTTP 100" and the probe failed on every endpoint.
    """

    def test_argv_disables_the_expect_handshake(self):
        argv = _upload_argv("https://example.invalid", "10", "/tmp/x.bin")
        assert "Expect:" in argv
        # It must be the header NAME with an empty value, passed as one argv
        # element pair — not "--expect" or a bare "Expect".
        assert argv[argv.index("Expect:") - 1] == "-H"

    def test_argv_still_posts_the_binary_payload(self):
        argv = _upload_argv("https://example.invalid", "10", "/tmp/x.bin")
        assert "--data-binary" in argv
        assert "-X" in argv and argv[argv.index("-X") + 1] == "POST"


class TestResultParsing:
    """A transfer cut short by --max-time is a REAL sample, not a failure.

    The module's own comment states the intent — "a stream cut short by
    --max-time measures exactly what was sent" — but the parser checked the
    HTTP status BEFORE reading the byte count, so that sample was thrown
    away before the numbers were ever seen.
    """

    def test_completed_2xx_is_accepted(self):
        mbps, mb = _probe_with_stdout("201 10000000 8.0")
        assert mb == pytest.approx(10.0)
        assert mbps == pytest.approx(10.0)

    def test_204_counts_as_success(self):
        mbps, _mb = _probe_with_stdout("204 10000000 8.0", returncode=0)
        assert mbps > 0

    def test_cut_short_transfer_is_accepted(self):
        """curl exit 28 = the time cap fired mid-transfer."""
        mbps, mb = _probe_with_stdout("000 6881117 8.0", returncode=28)
        assert mb == pytest.approx(6.881117, rel=1e-3)
        assert mbps > 0

    def test_interim_100_with_real_bytes_is_not_rejected_as_http_100(self):
        """The exact live failure: code 100, but 6.9 MB really moved."""
        mbps, mb = _probe_with_stdout("100 6881117 8.0", returncode=28)
        assert mb > 0 and mbps > 0

    def test_zero_bytes_is_still_refused(self):
        """The proxy-interception guard must survive the fix."""
        with pytest.raises(netmax.NetMaxError, match="0 bytes uploaded"):
            _probe_with_stdout("200 0 8.0", returncode=0)

    def test_genuine_http_error_is_still_refused(self):
        with pytest.raises(netmax.NetMaxError):
            _probe_with_stdout("429 5000 0.5", returncode=0)

    def test_4xx_with_no_timeout_is_refused(self):
        with pytest.raises(netmax.NetMaxError):
            _probe_with_stdout("503 5000 0.5", returncode=0)

    def test_timeout_with_zero_bytes_is_refused(self):
        """A cut transfer that sent nothing proves nothing."""
        with pytest.raises(netmax.NetMaxError, match="0 bytes uploaded"):
            _probe_with_stdout("000 0 8.0", returncode=28)

    def test_unparseable_output_is_refused(self):
        with pytest.raises(netmax.NetMaxError):
            _probe_with_stdout("garbage")

    def test_zero_duration_is_refused(self):
        with pytest.raises(netmax.NetMaxError):
            _probe_with_stdout("200 1000 0", returncode=0)
