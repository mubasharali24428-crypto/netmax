"""Offline tests for netmax_shape (Wave-3 strict limiter core).

No root, no pf, no dnctl ever runs: os.geteuid and the _run/_write_temp
seams are faked per test (conftest tripwires stay armed otherwise).
"""

from __future__ import annotations

from collections import namedtuple

import pytest

import netmax_shape
from netmax import NetMaxError

FakeProc = namedtuple("FakeProc", "stdout returncode")


def _ok(stdout=""):
    return FakeProc(stdout, 0)


class FakeRunner:
    """Canned pf/dnctl backend; records every argv in order."""

    def __init__(self, enabled=True, rules="", fail_on=()):
        self.enabled = enabled
        self.rules = rules
        self.fail_on = fail_on
        self.calls: list[list[str]] = []

    def __call__(self, argv, input_text=None):
        self.calls.append(argv)
        head = " ".join(argv[:3])
        if head in self.fail_on:
            return FakeProc("", 1)
        if argv[:3] == ["pfctl", "-s", "info"]:
            return _ok("Status: Enabled\n" if self.enabled else "Status: Disabled\n")
        if argv[:3] == ["pfctl", "-s", "rules"]:
            return _ok(self.rules)
        return _ok("")


@pytest.fixture
def as_root(monkeypatch):
    monkeypatch.setattr(netmax_shape.os, "geteuid", lambda: 0)


@pytest.fixture
def as_user(monkeypatch):
    monkeypatch.setattr(netmax_shape.os, "geteuid", lambda: 501)


def _no_temp(monkeypatch):
    paths = ["/tmp/netmax-main.conf", "/tmp/netmax-anchor.conf"]
    monkeypatch.setattr(netmax_shape, "_write_temp", lambda text: paths.pop(0))
    return paths


class TestRateFormat:
    def test_whole_mbps(self):
        assert netmax_shape.kbit_str(2.0) == "2000Kbit/s"

    def test_fractional_stays_exact(self):
        assert netmax_shape.kbit_str(0.5) == "500Kbit/s"
        assert netmax_shape.kbit_str(2.5) == "2500Kbit/s"

    def test_out_of_range_rejected(self):
        with pytest.raises(NetMaxError):
            netmax_shape.kbit_str(0.4)
        with pytest.raises(NetMaxError):
            netmax_shape.kbit_str(10_001)


class TestRules:
    def test_anchor_shapes_both_directions_off_lo0(self):
        body = netmax_shape.anchor_rules()
        assert "pipe 10" in body
        assert "on ! lo0" in body
        assert "dummynet in" in body and "dummynet out" in body

    def test_merge_appends_refs_and_preserves_existing(self):
        merged = netmax_shape.merge_main_rules("pass all\n")
        assert merged.startswith("pass all\n")
        assert 'dummynet-anchor "netmax"' in merged
        assert 'anchor "netmax"' in merged

    def test_merge_is_idempotent(self):
        once = netmax_shape.merge_main_rules("")
        assert netmax_shape.merge_main_rules(once) == once

    def test_merge_handles_missing_trailing_newline(self):
        assert netmax_shape.merge_main_rules("pass all").startswith("pass all\n")


class TestApply:
    def test_refuses_without_root(self, as_user):
        with pytest.raises(netmax_shape.ShapeError, match="sudo"):
            netmax_shape.apply(2.0, run=FakeRunner())

    def test_require_root_prefails_before_any_output(self, as_user):
        with pytest.raises(netmax_shape.ShapeError, match="sudo"):
            netmax_shape.require_root(2.0)

    def test_require_root_passes_as_root(self, as_root):
        netmax_shape.require_root(2.0)  # must not raise

    def test_install_sequence(self, as_root, monkeypatch):
        _no_temp(monkeypatch)
        runner = FakeRunner(enabled=True, rules="pass all\n")
        state = netmax_shape.apply(2.0, run=runner)
        assert state == {"was_enabled": True, "rate": "2000Kbit/s"}
        verbs = [" ".join(c[:3]) for c in runner.calls]
        assert verbs == [
            "pfctl -s info",
            "pfctl -s rules",
            "pfctl -e",
            "pfctl -f /tmp/netmax-main.conf",
            "dnctl pipe 10",
            "pfctl -a netmax",
        ]
        assert runner.calls[4][-1] == "2000Kbit/s"  # pipe bw last arg

    def test_anchor_failure_deletes_pipe(self, as_root, monkeypatch):
        _no_temp(monkeypatch)
        runner = FakeRunner(fail_on={"pfctl -a netmax"})
        with pytest.raises(netmax_shape.ShapeError, match="anchor"):
            netmax_shape.apply(2.0, run=runner)
        assert ["dnctl", "pipe", "10", "delete"] in runner.calls

    def test_shape_error_is_dispatch_catchable(self):
        """Dual-module trap: under `python3 netmax.py`, this module's
        `import netmax` is a second copy — NetMaxError identity does NOT
        cross the boundary, so the shaper raises its own error type."""
        assert not issubclass(netmax_shape.ShapeError, NetMaxError)


class TestRemove:
    def test_restores_disabled_pf(self, as_root):
        runner = FakeRunner()
        netmax_shape.remove({"was_enabled": False}, run=runner)
        verbs = [" ".join(c[:2]) for c in runner.calls]
        assert verbs == ["pfctl -a", "dnctl pipe", "pfctl -d"]

    def test_leaves_enabled_pf_on(self, as_root):
        runner = FakeRunner()
        netmax_shape.remove({"was_enabled": True}, run=runner)
        assert all(c[:2] != ["pfctl", "-d"] for c in runner.calls)

    def test_never_raises(self, as_root):
        def boom(argv, input_text=None):
            raise OSError("gone")

        netmax_shape.remove({"was_enabled": False}, run=boom)  # must not raise


class TestHold:
    def test_hold_applies_sleeps_removes(self, as_root, monkeypatch):
        _no_temp(monkeypatch)
        runner = FakeRunner()
        now = [0.0]
        sleeps = []
        monkeypatch.setattr(netmax_shape._time, "monotonic", lambda: now[0])

        def fake_sleep(s):
            sleeps.append(s)
            now[0] += s

        monkeypatch.setattr(netmax_shape._time, "sleep", fake_sleep)
        out = netmax_shape.hold(2.0, 5, run=runner)
        assert out == 2.0
        assert sleeps, "must actually wait out the window"
        assert ["dnctl", "pipe", "10", "delete"] in runner.calls

    def test_ctrl_c_still_cleans_up(self, as_root, monkeypatch):
        _no_temp(monkeypatch)
        runner = FakeRunner()

        def interrupt(s):
            raise KeyboardInterrupt

        monkeypatch.setattr(netmax_shape._time, "sleep", interrupt)
        with pytest.raises(KeyboardInterrupt):
            netmax_shape.hold(2.0, 1800, run=runner)
        assert ["dnctl", "pipe", "10", "delete"] in runner.calls

    def test_sigterm_guard_installed_fires_restored(
        self, as_root, monkeypatch
    ):
        """Timeout kills (MCP/Swift) arrive as SIGTERM — the guard must
        convert to SystemExit (cleanup runs) and restore the old handler."""
        import signal as _sig

        _no_temp(monkeypatch)
        runner = FakeRunner()
        now = [0.0]
        monkeypatch.setattr(netmax_shape._time, "monotonic", lambda: now[0])
        monkeypatch.setattr(
            netmax_shape._time, "sleep",
            lambda s: now.__setitem__(0, now[0] + s),
        )
        seen = []
        monkeypatch.setattr(
            netmax_shape.signal, "getsignal", lambda s: "PREV")
        monkeypatch.setattr(
            netmax_shape.signal, "signal",
            lambda s, h: seen.append((s, h)),
        )
        netmax_shape.hold(2.0, 5, run=runner)
        assert seen[0] == (_sig.SIGTERM, seen[0][1])
        assert seen[0][1] != "PREV"
        assert seen[-1] == (_sig.SIGTERM, "PREV")  # restored
        with pytest.raises(SystemExit):
            seen[0][1](_sig.SIGTERM, None)  # the guard itself raises


class TestIntegrity:
    """Root must never execute group/world-writable engine files."""

    def test_clean_tree_passes(self, tmp_path):
        (tmp_path / "a.py").write_text("x = 1\n")
        assert netmax_shape.engine_integrity_error(str(tmp_path)) is None

    def test_group_writable_file_fails(self, tmp_path):
        target = tmp_path / "evil.py"
        target.write_text("x = 1\n")
        target.chmod(0o664)
        err = netmax_shape.engine_integrity_error(str(tmp_path))
        assert err is not None and "evil.py" in err

    def test_group_writable_dir_fails(self, tmp_path):
        tmp_path.chmod(0o775)
        err = netmax_shape.engine_integrity_error(str(tmp_path))
        assert err is not None and "dir" in err

    def test_missing_dir_fails_closed(self, tmp_path):
        assert netmax_shape.engine_integrity_error(
            str(tmp_path / "gone")) is not None

    def test_apply_refuses_before_touching_pf(self, as_root, monkeypatch,
                                              tmp_path):
        eng = tmp_path / "eng"
        eng.mkdir()
        mod = eng / "netmax_shape.py"
        mod.write_text("x = 1\n")
        mod.chmod(0o664)
        monkeypatch.setattr(netmax_shape, "__file__", str(mod))
        runner = FakeRunner()
        with pytest.raises(netmax_shape.ShapeError, match="group/world-writable"):
            netmax_shape.apply(2.0, run=runner)
        assert runner.calls == []  # no pf/dnctl command was issued
