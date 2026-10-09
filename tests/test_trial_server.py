"""Tests for trial_server (reference trial registry).

The real server is started on an ephemeral 127.0.0.1 port in a background
thread. The repo's offline test tripwires (tests/conftest.py) block socket
creation, so this module captures the real socket functions at import time
and re-arms them inside the server fixture only — loopback only, no WAN.
"""

import hashlib
import hmac
import http.client
import json
import socket
import threading
from datetime import datetime, timezone

import pytest

import trial_server.server as trial_server

# Captured BEFORE tests/conftest.py's autouse fixture swaps them for tripwires.
_REAL_SOCKET = socket.socket
_REAL_GETADDRINFO = socket.getaddrinfo
_REAL_CREATE_CONNECTION = socket.create_connection

SECRET = "test-secret-123"
FP = "ab" * 32
FP2 = "cd" * 32
FP3 = "ef" * 32


@pytest.fixture()
def registry(tmp_path, monkeypatch):
    """Live server on 127.0.0.1:<ephemeral> with a throwaway SQLite DB."""
    monkeypatch.setattr(socket, "socket", _REAL_SOCKET)
    monkeypatch.setattr(socket, "getaddrinfo", _REAL_GETADDRINFO)
    monkeypatch.setattr(socket, "create_connection", _REAL_CREATE_CONNECTION)
    srv = trial_server.TrialServer(
        ("127.0.0.1", 0),
        db_path=str(tmp_path / "trials.db"),
        hmac_secret=SECRET,
    )
    thread = threading.Thread(target=srv.serve_forever, daemon=True)
    thread.start()
    yield srv
    srv.shutdown()
    thread.join(timeout=10)
    srv.server_close()


def _call(registry, method, path, body=None):
    host, port = registry.server_address
    conn = http.client.HTTPConnection(host, port, timeout=10)
    data = None
    headers = {}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    conn.request(method, path, body=data, headers=headers)
    resp = conn.getresponse()
    payload = json.loads(resp.read().decode("utf-8"))
    conn.close()
    return resp.status, payload


def _activate(registry, fp=FP, vm_suspected=False, app_version="1.0.7"):
    return _call(
        registry,
        "POST",
        "/v1/trial/activate",
        {
            "fingerprint_sha256": fp,
            "app_version": app_version,
            "vm_suspected": vm_suspected,
        },
    )


def _status(registry, fp=FP, token=""):
    return _call(registry, "GET", f"/v1/trial/status?fp={fp}&token={token}")


def _expected_token(fp, start, end):
    msg = f"{fp}|{start}|{end}".encode("utf-8")
    return hmac.new(SECRET.encode("utf-8"), msg, hashlib.sha256).hexdigest()


# ---------------------------------------------------------------------------
# activate
# ---------------------------------------------------------------------------


def test_healthz(registry):
    status, payload = _call(registry, "GET", "/healthz")
    assert status == 200
    assert payload == {"ok": True}


def test_activate_mints_verifiable_token(registry):
    status, payload = _activate(registry)
    assert status == 200
    assert payload["ok"] is True
    start, end = payload["trial_start"], payload["trial_end"]
    assert payload["token"] == _expected_token(FP, start, end)
    # 14-day window, UTC ISO format.
    delta = datetime.strptime(end, "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=timezone.utc
    ) - datetime.strptime(start, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    assert delta.days == 14


def test_activate_twice_is_consumed(registry):
    status1, first = _activate(registry)
    assert status1 == 200
    status2, payload = _activate(registry)
    assert status2 == 403
    assert payload["ok"] is False
    assert payload["error"] == "trial_already_consumed"
    assert payload["trial_start"] == first["trial_start"]
    assert payload["trial_end"] == first["trial_end"]


def test_vm_suspected_denied_by_default(registry):
    status, payload = _activate(registry, fp=FP2, vm_suspected=True)
    assert status == 403
    assert payload["error"] == "vm_not_allowed"


def test_vm_suspected_allowed_when_policy_disabled(registry, monkeypatch):
    monkeypatch.setattr(trial_server, "DENY_VM_TRIALS", False)
    status, payload = _activate(registry, fp=FP2, vm_suspected=True)
    assert status == 200
    assert payload["ok"] is True


@pytest.mark.parametrize(
    "bad_fp", ["xyz", "", "AB" * 32, "ab" * 31, "ab" * 32 + "ab", "not-hex!" + "0" * 56]
)
def test_activate_rejects_malformed_fingerprint(registry, bad_fp):
    status, payload = _activate(registry, fp=bad_fp)
    assert status == 400
    assert payload["error"] == "malformed_fingerprint"


def test_activate_rate_limited(registry, monkeypatch):
    monkeypatch.setattr(trial_server, "ACTIVATE_LIMIT_PER_IP_HOUR", 1)
    status, _ = _activate(registry, fp=FP)
    assert status == 200
    status, payload = _activate(registry, fp=FP2)
    assert status == 429
    assert payload["error"] == "rate_limited"


# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------


def test_status_active_with_valid_token(registry):
    _, first = _activate(registry)
    status, payload = _status(registry, fp=FP, token=first["token"])
    assert status == 200
    assert payload["ok"] is True
    assert payload["active"] is True
    assert payload["trial_start"] == first["trial_start"]
    assert payload["trial_end"] == first["trial_end"]


def test_status_bad_token(registry):
    _activate(registry)
    status, payload = _status(registry, fp=FP, token="00" * 32)
    assert status == 403
    assert payload["error"] == "bad_token"


def test_status_unknown_fingerprint(registry):
    status, payload = _status(registry, fp=FP3, token="00" * 32)
    assert status == 404
    assert payload["error"] == "unknown_fingerprint"


def test_status_malformed_fingerprint(registry):
    status, payload = _status(registry, fp="nope", token="00" * 32)
    assert status == 400
    assert payload["error"] == "malformed_fingerprint"


def test_status_rate_limited(registry, monkeypatch):
    monkeypatch.setattr(trial_server, "STATUS_LIMIT_PER_IP_HOUR", 1)
    _, first = _activate(registry)
    status, _ = _status(registry, fp=FP, token=first["token"])
    assert status == 200
    status, payload = _status(registry, fp=FP, token=first["token"])
    assert status == 429
    assert payload["error"] == "rate_limited"


# ---------------------------------------------------------------------------
# startup guard
# ---------------------------------------------------------------------------


def test_missing_secret_refuses_to_start(monkeypatch, capsys):
    monkeypatch.delenv("NETMAX_TRIAL_HMAC_SECRET", raising=False)
    rc = trial_server.main(["--port", "1"])
    assert rc == 2
    assert "NETMAX_TRIAL_HMAC_SECRET" in capsys.readouterr().err
