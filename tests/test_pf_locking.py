"""B-10: shaping serialization, owner persistence, dynamic pipe allocation,
and owner-scoped cleanup under failure."""

from __future__ import annotations

import json
import os
import pytest

import netmax_shape
from test_pf_transactional import Backend


@pytest.fixture
def run_env(monkeypatch, tmp_path):
    monkeypatch.setattr(netmax_shape.os, "geteuid", lambda: 0)
    files: dict[str, str] = {}

    def write(text):
        p = str(tmp_path / f"conf-{len(files)}.conf")
        files[p] = text
        return p

    monkeypatch.setattr(netmax_shape, "_write_temp", write)
    lock_file = str(tmp_path / "lock")
    state_file = str(tmp_path / "owner.json")
    monkeypatch.setattr(netmax_shape, "LOCK_PATH", lock_file)
    monkeypatch.setattr(netmax_shape, "STATE_DIR", str(tmp_path))
    monkeypatch.setattr(netmax_shape, "STATE_FILE", state_file)

    def make(**kw):
        b = Backend(**kw)
        b.files = files
        return b

    return make, lock_file, state_file


def test_allocate_pipe_picks_first_free():
    used = "00100: 1 Mbit/s\n20000: 5 Mbit/s\n20001: 5 Mbit/s\n"
    assert netmax_shape.allocate_pipe(used) == 20002
    assert netmax_shape.allocate_pipe("") == 20000


def test_allocate_pipe_exhaustion():
    used = "\n".join(f"{p}: 1 Mbit/s" for p in range(20000, 30000)) + "\n"
    with pytest.raises(netmax_shape.ShapeError, match="exhausted|all shaping pipes"):
        netmax_shape.allocate_pipe(used)


def test_lock_contention_rejects_second_holder(tmp_path):
    lock = str(tmp_path / "l.lock")
    fd1 = netmax_shape.acquire_lock(lock)
    try:
        with pytest.raises(netmax_shape.ShapeError, match="another shaping process"):
            netmax_shape.acquire_lock(lock)
    finally:
        os.close(fd1)
    # Freed: next attempt succeeds
    fd2 = netmax_shape.acquire_lock(lock)
    os.close(fd2)


def test_wrong_token_does_not_clear_owner(tmp_path):
    sf = str(tmp_path / "owner.json")
    state = {"token": "correct-token", "pid": 1234}
    netmax_shape.save_owner(state, str(tmp_path), sf)
    assert not netmax_shape.clear_owner("wrong-token", sf)
    with open(sf) as f:
        assert json.load(f)["token"] == "correct-token"
    assert netmax_shape.clear_owner("correct-token", sf)
    assert not os.path.exists(sf)


def test_stale_owner_dead_pid_recovers(run_env):
    make, _, sf = run_env
    b = make(enabled=False, rules='pass all\nanchor "netmax_strict_limit" all\n')
    state = {"was_enabled": False, "we_enabled": True, "pipe_no": 20005,
             "token": "tok", "pid": 999999999, "anchor": netmax_shape.ANCHOR}
    with open(sf, "w") as f:
        json.dump(state, f)
    netmax_shape.recover_stale_owner(run=b, state_file=sf)
    assert not os.path.exists(sf), "stale owner file removed after recovery"
    assert ["dnctl", "pipe", "20005", "delete"] in b.calls
    assert not b.enabled


def test_stale_owner_live_pid_refuses(run_env):
    make, _, sf = run_env
    b = make()
    state = {"was_enabled": True, "pipe_no": 20001, "token": "tok",
             "pid": os.getpid(), "anchor": netmax_shape.ANCHOR}
    with open(sf, "w") as f:
        json.dump(state, f)
    with pytest.raises(netmax_shape.ShapeError, match="currently active"):
        netmax_shape.recover_stale_owner(run=b, state_file=sf)
    assert os.path.exists(sf)


def test_stale_owner_unrecognized_metadata_fails_closed(run_env):
    make, _, sf = run_env
    b = make()
    # Bad anchor marker (e.g. Someone tampered with it)
    state = {"was_enabled": True, "pipe_no": 20001, "token": "tok",
             "pid": 999999999, "anchor": "evil_anchor"}
    with open(sf, "w") as f:
        json.dump(state, f)
    with pytest.raises(netmax_shape.ShapeError, match="unrecognized owner metadata"):
        netmax_shape.recover_stale_owner(run=b, state_file=sf)
    assert b.calls == []
    assert os.path.exists(sf)


def test_hold_completes_full_lifecycle(run_env, monkeypatch):
    make, _, sf = run_env
    b = make(enabled=False, rules="pass all\n")
    now = [0.0]
    monkeypatch.setattr(netmax_shape._time, "monotonic", lambda: now[0])
    monkeypatch.setattr(netmax_shape._time, "sleep", lambda s: now.__setitem__(0, now[0] + s))
    netmax_shape.hold(2.0, 5, run=b)
    assert not os.path.exists(sf), "owner file cleaned up at end of hold"
    assert ["dnctl", "pipe", "20000", "delete"] in b.calls
    assert not b.enabled
