"""B-09: pf/dnctl apply is transactional. No host pf/dnctl is ever called —
every command goes through a recording fake."""

from __future__ import annotations

from collections import namedtuple

import pytest

import netmax_shape

FakeProc = namedtuple("FakeProc", "stdout returncode")
ANCHOR = netmax_shape.ANCHOR
PIPE = str(netmax_shape.PIPE_NO)


class Backend:
    """Stateful fake: tracks pf enabled state, the live ruleset, anchor and pipes."""

    def __init__(self, enabled=True, rules="pass all\n", pipes="", fail=(), raise_on=()):
        self.enabled, self.rules, self.pipes = enabled, rules, pipes
        self.fail, self.raise_on = tuple(fail), tuple(raise_on)
        self.anchor_loaded = False
        self.pipe_cfg = False
        self.calls: list[list[str]] = []
        self.loaded_main: list[str] = []

    def key(self, argv):
        return " ".join(argv[:4]) if argv[:2] in (["pfctl", "-a"], ["dnctl", "pipe"]) else " ".join(argv[:3])

    def __call__(self, argv, input_text=None):
        self.calls.append(argv)
        k = self.key(argv)
        if any(k.startswith(r) for r in self.raise_on):
            raise OSError("boom")
        if any(k.startswith(f) for f in self.fail):
            return FakeProc("", 1)
        if argv[:3] == ["pfctl", "-s", "info"]:
            return FakeProc("Status: Enabled\n" if self.enabled else "Status: Disabled\n", 0)
        if argv[:3] == ["pfctl", "-s", "rules"]:
            return FakeProc(self.rules, 0)
        if argv[:2] == ["dnctl", "list"]:
            return FakeProc(self.pipes, 0)
        if argv[:2] == ["dnctl", "pipe"] and argv[3] == "config":
            self.pipe_cfg = True
        elif argv[:2] == ["dnctl", "pipe"] and argv[3] == "delete":
            self.pipe_cfg = False
        elif argv[:3] == ["pfctl", "-a", ANCHOR] and "-f" in argv:
            self.anchor_loaded = True
        elif argv[:3] == ["pfctl", "-a", ANCHOR] and "-F" in argv:
            self.anchor_loaded = False
        elif argv == ["pfctl", "-e"]:
            self.enabled = True
        elif argv == ["pfctl", "-d"]:
            self.enabled = False
        elif argv[:2] == ["pfctl", "-f"]:
            text = self.files[argv[2]]
            self.loaded_main.append(text)
            self.rules = text.replace('dummynet-anchor "netmax_strict_limit"\n', "")
            if 'anchor "netmax_strict_limit"' in text:
                self.rules += 'anchor "netmax_strict_limit" all\n'
        return FakeProc("", 0)


@pytest.fixture
def env(monkeypatch):
    monkeypatch.setattr(netmax_shape.os, "geteuid", lambda: 0)
    files: dict[str, str] = {}

    def write(text):
        path = f"/tmp/fake-{len(files)}.conf"
        files[path] = text
        return path

    monkeypatch.setattr(netmax_shape, "_write_temp", write)

    def make(**kw):
        b = Backend(**kw)
        b.files = files
        return b

    return make


STAGES = [
    ("dnctl pipe", "dnctl pipe 20000 config"),
    ("anchor load", "pfctl -a netmax_strict_limit -f"),
    ("pf merged ruleset", "pfctl -f"),
]


@pytest.mark.parametrize("was_enabled", [True, False])
@pytest.mark.parametrize("label,prefix", STAGES)
def test_failure_at_each_stage_restores_prior_state(env, was_enabled, label, prefix):
    b = env(enabled=was_enabled, rules="pass all\n")
    before_rules = b.rules
    with pytest.raises(netmax_shape.ShapeError, match="rolled back"):
        netmax_shape.apply(2.0, run=b.__class__.__call__.__get__(b) if False else _failing(b, prefix))
    assert b.enabled is was_enabled, "pf enabled state restored exactly"
    assert not b.pipe_cfg and not b.anchor_loaded, "our pipe/anchor removed"
    assert 'anchor "netmax_strict_limit"' not in b.rules
    assert b.rules == before_rules


def _failing(b, prefix):
    b.fail = (prefix,)
    return b


def test_pf_enable_failure_rolls_back_without_disabling_twice(env):
    b = env(enabled=False)
    b.fail = ("pfctl -e",)
    with pytest.raises(netmax_shape.ShapeError, match="rolled back"):
        netmax_shape.apply(2.0, run=b)
    assert b.enabled is False and not b.pipe_cfg and not b.anchor_loaded
    assert ["pfctl", "-d"] not in b.calls, "we never enabled pf, so we must not 'disable' it"


def test_success_installs_expected_state(env):
    b = env(enabled=False, rules="pass all\n")
    state = netmax_shape.apply(2.0, run=b)
    assert state["we_enabled"] is True and state["pipe_no"] == netmax_shape.PIPE_NO
    assert b.enabled and b.pipe_cfg and b.anchor_loaded
    assert 'anchor "netmax_strict_limit"' in b.rules
    errs = netmax_shape.remove(state, run=b)
    assert errs == []
    assert not b.enabled and not b.pipe_cfg and not b.anchor_loaded
    assert b.rules == "pass all\n"


def test_rollback_failure_is_reported_alongside_primary_error(env):
    b = env()
    b.fail = ("pfctl -f", "dnctl pipe 20000 delete")
    with pytest.raises(netmax_shape.ShapeError) as exc:
        netmax_shape.apply(2.0, run=b)
    msg = str(exc.value)
    assert "pf refused the merged ruleset" in msg and "rollback problems" in msg and "delete pipe failed" in msg


def test_exception_during_mutation_is_rolled_back(env):
    b = env()
    b.raise_on = ("pfctl -f",)
    with pytest.raises(netmax_shape.ShapeError):
        netmax_shape.apply(2.0, run=b)
    assert not b.pipe_cfg and not b.anchor_loaded


@pytest.mark.parametrize("kw", [
    {"rules": 'pass all\nanchor "netmax" all\n'},
    {"pipes": "00010: 2.000 Mbit/s 0 ms burst 0\n"},
])
def test_legacy_state_is_refused_and_untouched(env, kw):
    b = env(**kw)
    with pytest.raises(netmax_shape.ShapeError, match="foreign"):
        netmax_shape.apply(2.0, run=b)
    mutating = [c for c in b.calls if (c[0] in ("dnctl",) and c[1] == "pipe") or c[:2] in (["pfctl", "-e"], ["pfctl", "-d"], ["pfctl", "-f"]) or "-F" in c]
    assert mutating == [], "nothing may be flushed, deleted, or reloaded"


def test_legacy_pipe_regex_is_exact(env):
    b = env(pipes="00110: 1.000 Mbit/s\n20000: 5 Mbit/s\n")
    netmax_shape.apply(2.0, run=b)  # 110 is not 10 → allowed


def test_rollback_strips_only_our_refs_and_keeps_concurrent_changes(env):
    """Another firewall manager adds a rule after our snapshot; rollback must
    preserve it rather than reloading the stale snapshot."""
    b = env(rules="pass all\n")
    orig_call = b.__call__

    def racing(argv, input_text=None):
        proc = orig_call(argv, input_text)
        if argv[:2] == ["pfctl", "-f"]:  # our merged load lands, then someone else edits
            b.rules += "block drop quick proto tcp to port 23\n"
            b.fail = ("pfctl -f",)  # and our next reload (rollback strip) must still use fresh rules
        return proc

    b.fail = ()
    first_f = {"seen": False}

    def wrapper(argv, input_text=None):
        if argv[:2] == ["pfctl", "-f"] and not first_f["seen"]:
            first_f["seen"] = True
            orig_call(argv, input_text)
            b.rules += "block drop quick proto tcp to port 23\n"
            return FakeProc("", 1)  # report failure after the concurrent edit
        return orig_call(argv, input_text)

    with pytest.raises(netmax_shape.ShapeError):
        netmax_shape.apply(2.0, run=wrapper)
    last_reload = b.loaded_main[-1]
    assert "block drop quick proto tcp to port 23" in last_reload, "concurrent rule preserved"
    assert "netmax_strict_limit" not in last_reload
    assert racing  # (kept for readability of the scenario above)
