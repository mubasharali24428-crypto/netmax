"""Offline tests for netmax_watch_daemon — lock, flag, and SIGINT hand-off."""

from __future__ import annotations

import os

import pytest

import netmax_watch
import netmax_watch_daemon as d


# ── ShutdownFlag ──────────────────────────────────────────────────────────────


def test_shutdown_flag_request_sets_requested():
    flag = d.ShutdownFlag()
    assert flag.requested is False
    flag.request()
    assert flag.requested is True


def test_shutdown_flag_wait_returns_immediately_once_set():
    flag = d.ShutdownFlag()
    flag.request()
    assert flag.wait(timeout=10) is True


def test_shutdown_flag_wait_times_out_when_clear():
    flag = d.ShutdownFlag()
    assert flag.wait(timeout=0.01) is False
    assert flag.requested is False


# ── run_daemon SIGINT hand-off ────────────────────────────────────────────────


def test_run_daemon_stops_when_watch_loop_on_interrupt_fires(monkeypatch):
    """Ctrl-C during watch_loop must flip the daemon shutdown flag."""
    shutdown = d.ShutdownFlag()
    seen: dict = {"on_interrupt": None, "calls": 0}

    def fake_watch_loop(interval_s, cycles, history=None, *, on_interrupt=None):
        seen["calls"] += 1
        seen["on_interrupt"] = on_interrupt
        history.append({"delta_ms": 1.0, "grade": "A", "dns_ms": None})
        # Simulate SIGINT arriving mid-cycle: watch_loop invokes the seam.
        if on_interrupt is not None:
            on_interrupt()
        return history

    monkeypatch.setattr(netmax_watch, "watch_loop", fake_watch_loop)
    hist = d.run_daemon(5, shutdown)
    assert seen["calls"] == 1
    assert seen["on_interrupt"] is not None
    assert shutdown.requested is True
    assert len(hist) == 1


def test_run_daemon_loops_until_flag_set(monkeypatch):
    shutdown = d.ShutdownFlag()
    cycles = {"n": 0}

    def fake_watch_loop(interval_s, cycles_arg, history=None, *, on_interrupt=None):
        cycles["n"] += 1
        history.append({"delta_ms": 1.0, "grade": "A", "dns_ms": None})
        if cycles["n"] >= 3:
            shutdown.request()
        return history

    monkeypatch.setattr(netmax_watch, "watch_loop", fake_watch_loop)
    monkeypatch.setattr(shutdown, "wait", lambda timeout: False)
    hist = d.run_daemon(5, shutdown)
    assert cycles["n"] == 3
    assert len(hist) == 3


def test_run_daemon_does_not_start_when_already_shutdown():
    shutdown = d.ShutdownFlag()
    shutdown.request()

    def boom(*a, **k):  # pragma: no cover - must not be reached
        raise AssertionError("watch_loop ran despite shutdown")

    hist = d.run_daemon(5, shutdown)
    assert hist == []


# ── lockfile helpers ──────────────────────────────────────────────────────────


def test_acquire_and_release_lock_roundtrip(tmp_path):
    path = tmp_path / "netmax-watch-daemon.test.pid"
    assert d._acquire_lock(path) is True
    assert d._read_pid(path) == os.getpid()
    d._release_lock(path)
    assert not path.exists()


def test_acquire_lock_refuses_live_holder(tmp_path, monkeypatch):
    path = tmp_path / "lock.pid"
    # Pretend another live process (pid 1 on macOS is launchd — always alive)
    # holds the lock; os.getpid() differs so we don't short-circuit as owner.
    path.write_text("1\n", encoding="utf-8")
    if os.getpid() == 1:  # pragma: no cover
        pytest.skip("running as pid 1")
    assert d._acquire_lock(path) is False
    assert path.exists()  # live holder's lock left intact


def test_acquire_lock_recovers_stale_lock(tmp_path):
    path = tmp_path / "lock.pid"
    # pid 0 is never a live process → stale → recovered.
    path.write_text("0\n", encoding="utf-8")
    assert d._acquire_lock(path) is True
    assert d._read_pid(path) == os.getpid()
    d._release_lock(path)


def test_release_lock_only_removes_own_pid(tmp_path):
    path = tmp_path / "lock.pid"
    path.write_text("999999\n", encoding="utf-8")  # someone else's pid
    d._release_lock(path)
    assert path.exists()  # not ours → left alone
    path.unlink()


# ── main() releases lock on unexpected exception ──────────────────────────────


def test_main_releases_lock_when_run_daemon_raises(monkeypatch, tmp_path,
                                                   capsys):
    lock = tmp_path / "forced-lock.pid"
    monkeypatch.setattr(d, "_lockfile_path", lambda: lock)
    assert d._acquire_lock(lock) is True

    def boom(interval_s, shutdown):
        raise RuntimeError("unexpected")

    monkeypatch.setattr(d, "run_daemon", boom)
    # RuntimeErrors are not caught by main — it must still release the lock
    # via finally and re-raise. We catch here to assert the contract.
    with pytest.raises(RuntimeError, match="unexpected"):
        d.main(["--interval", "5"])
    assert not lock.exists(), "lock leaked after unexpected exception"
