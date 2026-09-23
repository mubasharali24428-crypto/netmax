"""Offline tests for netmax_watch.watch_loop."""

import pytest

import netmax
import netmax_watch


@pytest.fixture
def mock_net(monkeypatch):
    """Patch bloat_grade/dns_ranking/sleep on the netmax_watch module."""
    calls = {"bloat": 0, "dns": 0, "sleeps": []}

    def fake_bloat(streams, seconds):
        calls["bloat"] += 1
        return (20.0, 15.0 + calls["bloat"], "B")

    def fake_dns():
        calls["dns"] += 1
        return [("Cloudflare", 11.5), ("Google", 22.0)]

    def fake_sleep(s):
        calls["sleeps"].append(s)

    monkeypatch.setattr(netmax_watch.netmax, "bloat_grade", fake_bloat)
    monkeypatch.setattr(netmax_watch.netmax, "dns_ranking", fake_dns)
    monkeypatch.setattr(netmax_watch.time, "sleep", fake_sleep)
    return calls


def test_validation():
    with pytest.raises(ValueError):
        netmax_watch.watch_loop(4, 3)
    with pytest.raises(ValueError):
        netmax_watch.watch_loop(5, 0)


def test_happy_path(mock_net, capsys):
    hist = netmax_watch.watch_loop(5, 3)
    assert len(hist) == 3
    assert mock_net["bloat"] == 3 and mock_net["dns"] == 3
    # interruptible sleep polls every 0.5s; total between cycles still = 2×interval
    assert len(mock_net["sleeps"]) > 0
    assert abs(sum(mock_net["sleeps"]) - 10.0) < 0.01
    assert all(set(h) == {"delta_ms", "grade", "dns_ms"} for h in hist)
    out = capsys.readouterr().out
    lines = out.strip().splitlines()
    assert len(lines) == 3
    for line in lines:
        assert "\n" not in line
    assert "[00:00:00] cycle 1" in lines[0] or "cycle 1:" in lines[0]


def test_appends_to_existing_history(mock_net):
    existing = [{"delta_ms": 1.0, "grade": "A", "dns_ms": None}]
    hist = netmax_watch.watch_loop(5, 2, history=existing)
    assert len(hist) == 3
    assert hist[0]["delta_ms"] == 1.0


def test_degrades_on_netmax_error(monkeypatch, capsys):
    def boom(streams, seconds):
        raise netmax.NetMaxError("down")

    def no_dns():
        raise netmax.NetMaxError("no dns")

    monkeypatch.setattr(netmax_watch.netmax, "bloat_grade", boom)
    monkeypatch.setattr(netmax_watch.netmax, "dns_ranking", no_dns)
    monkeypatch.setattr(netmax_watch.time, "sleep", lambda s: None)
    hist = netmax_watch.watch_loop(5, 2)
    assert len(hist) == 2
    assert all(h["delta_ms"] == 999.0 and h["grade"] == "F" for h in hist)


def test_stops_after_five_consecutive_failures(monkeypatch):
    n = {"calls": 0}

    def boom(streams, seconds):
        n["calls"] += 1
        raise netmax.NetMaxError("down")

    monkeypatch.setattr(netmax_watch.netmax, "bloat_grade", boom)
    monkeypatch.setattr(netmax_watch.netmax, "dns_ranking",
                        lambda: [("X", 10.0)])
    monkeypatch.setattr(netmax_watch.time, "sleep", lambda s: None)
    hist = netmax_watch.watch_loop(5, 50)
    assert n["calls"] == 5
    assert len(hist) == 5


def test_sigint_stops_cleanly(monkeypatch):
    import signal

    state = {"cycles_done": 0}

    def bloat(streams, seconds):
        state["cycles_done"] += 1
        if state["cycles_done"] == 2:
            # simulate Ctrl+C arriving during cycle 2
            handler = signal.getsignal(signal.SIGINT)
            assert handler is not signal.SIG_DFL
            handler(signal.SIGINT, None)
        return (20.0, 10.0, "B")

    monkeypatch.setattr(netmax_watch.netmax, "bloat_grade", bloat)
    monkeypatch.setattr(netmax_watch.netmax, "dns_ranking",
                        lambda: [("X", 10.0)])
    monkeypatch.setattr(netmax_watch.time, "sleep", lambda s: None)

    prev = signal.signal(signal.SIGINT, signal.SIG_DFL)
    try:
        hist = netmax_watch.watch_loop(5, 10)
    finally:
        signal.signal(signal.SIGINT, prev)
    assert state["cycles_done"] == 2
    assert len(hist) == 2
    # default handler restored before returning
    assert signal.getsignal(signal.SIGINT) in (signal.SIG_DFL,
                                               signal.default_int_handler)


def test_on_interrupt_called_on_sigint(monkeypatch):
    """Daemon seam: on_interrupt fires when SIGINT interrupts the loop."""
    import signal

    state = {"cycles_done": 0, "interrupted": []}

    def bloat(streams, seconds):
        state["cycles_done"] += 1
        if state["cycles_done"] == 1:
            handler = signal.getsignal(signal.SIGINT)
            handler(signal.SIGINT, None)
        return (20.0, 10.0, "B")

    monkeypatch.setattr(netmax_watch.netmax, "bloat_grade", bloat)
    monkeypatch.setattr(netmax_watch.netmax, "dns_ranking",
                        lambda: [("X", 10.0)])
    monkeypatch.setattr(netmax_watch.time, "sleep", lambda s: None)

    prev = signal.signal(signal.SIGINT, signal.SIG_DFL)
    try:
        hist = netmax_watch.watch_loop(
            5, 10, on_interrupt=lambda: state["interrupted"].append(True)
        )
    finally:
        signal.signal(signal.SIGINT, prev)
    assert state["interrupted"] == [True]
    assert len(hist) == 1
    assert state["cycles_done"] == 1
