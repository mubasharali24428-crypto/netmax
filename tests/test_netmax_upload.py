"""Offline tests for netmax.upload_probe — no real network, ever.

Mirrors tests/conftest.py: an autouse fixture arms tripwires on subprocess.run
and the socket layer; each test then installs a fake on exactly the seams it
needs (a later monkeypatch.setattr wins, disarming that one tripwire).
"""

import socket
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

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
    monkeypatch.setattr(socket, "getaddrinfo", _tripwire("socket.getaddrinfo"))
    monkeypatch.setattr(socket, "create_connection", _tripwire("socket.create_connection"))
    monkeypatch.setattr(socket, "socket", _tripwire("socket.socket"))


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


def test_payload_tempfile_cleaned_up(monkeypatch, tmp_path):
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
