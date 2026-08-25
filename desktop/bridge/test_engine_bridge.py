#!/usr/bin/env python3
"""Offline pytest suite for the engine bridge (contract C1).

Every subprocess interaction is mocked with unittest.mock — no network,
no real engine. Run: python -m pytest desktop/bridge/test_engine_bridge.py -q
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
BRIDGE_DIR = REPO_ROOT / "desktop" / "bridge"
if str(BRIDGE_DIR) not in sys.path:
    sys.path.insert(0, str(BRIDGE_DIR))

import engine_bridge as eb  # noqa: E402

PY = "/opt/fake/bin/python"
MODES = (
    "baseline", "turbo", "boost", "dns", "bloat", "full",
    "upload", "loss", "jitter", "wifi",
)


def _completed(returncode=0, stdout="", stderr=""):
    return SimpleNamespace(returncode=returncode, stdout=stdout, stderr=stderr)


def _run(runner, tmp_path, mode="turbo", streams=4, seconds=9):
    """Invoke run_engine against a mocked runner; load the envelope."""
    out = tmp_path / "env.json"
    code = eb.run_engine(mode, streams, seconds, None, str(out), runner=runner)
    return code, json.loads(out.read_text(encoding="utf-8"))


def _timeout_exc():
    # subprocess.TimeoutExpired requires real args on 3.13.
    return subprocess.TimeoutExpired(cmd=["netmax.py"], timeout=eb.TIMEOUT_S)


# ── interpreter resolution ───────────────────────────────────────────────────


def test_env_python_wins_over_sys_executable():
    assert eb.resolve_interpreter({"NETMAX_PYTHON": PY}) == PY


def test_empty_env_falls_back_to_sys_executable():
    assert eb.resolve_interpreter({}) is sys.executable


def test_blank_env_var_falls_back_to_sys_executable():
    assert eb.resolve_interpreter({"NETMAX_PYTHON": "   "}) is sys.executable


def test_real_environ_used_when_no_mapping_given(monkeypatch):
    monkeypatch.setenv("NETMAX_PYTHON", PY)
    assert eb.resolve_interpreter() == PY
    monkeypatch.delenv("NETMAX_PYTHON")
    assert eb.resolve_interpreter() is sys.executable


def test_build_command_uses_resolved_interpreter():
    with mock.patch.dict(os.environ, {"NETMAX_PYTHON": PY}):
        cmd, _dropped = eb.build_command("dns")
    assert cmd[0] == PY


# ── arg mapping per mode (parametrized) ──────────────────────────────────────


@pytest.mark.parametrize(
    "mode,kwargs,expected_tail",
    [
        ("baseline", {"seconds": 7}, ["--seconds", "7"]),
        ("turbo", {"streams": 4, "seconds": 9},
         ["--streams", "4", "--seconds", "9"]),
        ("boost", {"streams": 16}, ["--streams", "16"]),
        ("bloat", {"streams": 2, "seconds": 12},
         ["--streams", "2", "--seconds", "12"]),
        ("full", {"streams": 8, "seconds": 30},
         ["--streams", "8", "--seconds", "30"]),
        ("dns", {}, []),
        ("upload", {"seconds": 15}, ["--seconds", "15"]),
        ("loss", {"count": 25}, ["--count", "25"]),
        ("jitter", {"count": 5}, ["--count", "5"]),
        ("wifi", {}, []),
    ],
    ids=MODES,
)
def test_build_command_maps_only_supported_flags(mode, kwargs, expected_tail):
    cmd, dropped = eb.build_command(mode, **kwargs, python=PY, bundled=False)
    assert cmd == [PY, str(eb.ENGINE_PATH), mode] + expected_tail
    assert dropped == []  # supported flags are never reported as dropped


def test_every_contract_mode_is_known():
    assert sorted(eb.MODE_FLAGS) == sorted(MODES)


def test_unsupported_flag_is_dropped():
    # --count means nothing to turbo; it must not leak into the command —
    # but it IS surfaced in dropped_flags (F1: never silently lost).
    cmd, dropped = eb.build_command("turbo", streams=4, count=99, python=PY, bundled=False)
    assert "--count" not in cmd and cmd == [PY, str(eb.ENGINE_PATH), "turbo",
                                            "--streams", "4"]
    assert dropped == ["count"]


def test_defaults_omit_unset_flags():
    cmd, dropped = eb.build_command("turbo", python=PY, bundled=False)
    assert cmd == [PY, str(eb.ENGINE_PATH), "turbo"]
    assert dropped == []


# ── W7-4 (F2): bridge-side range validation ──────────────────────────────────


@pytest.mark.parametrize(
    "name,value,expected",
    [
        ("streams", 0, "netmax: --streams must be 1..32, got 0"),
        ("streams", 1, None),
        ("streams", 32, None),
        ("streams", 33, "netmax: --streams must be 1..32, got 33"),
        ("seconds", 4, "netmax: --seconds must be 5..21600, got 4"),
        ("seconds", 5, None),
        ("seconds", 30, None),
        ("seconds", 31, None),
        ("count", 0, "netmax: --count must be 1..100, got 0"),
        ("count", 1, None),
        ("count", 100, None),
        ("count", 101, "netmax: --count must be 1..100, got 101"),
    ],
)
def test_validate_ranges_boundaries(name, value, expected):
    kwargs = {"streams": None, "seconds": None, "count": None}
    kwargs[name] = value
    assert eb.validate_ranges(**kwargs) == expected


def test_validate_ranges_unset_flags_pass_and_inclusive_bounds_hold():
    assert eb.validate_ranges(None, None, None) is None
    assert eb.validate_ranges(1, 5, 1) is None
    assert eb.validate_ranges(32, 30, 100) is None


def test_run_engine_rejects_out_of_range_before_spawning(tmp_path):
    """F2 contract: bad value -> failure envelope + exit 1, engine NEVER runs."""

    def runner(cmd, **kw):  # pragma: no cover - must never be reached
        raise AssertionError(f"engine spawned despite invalid range: {cmd}")

    out = tmp_path / "env.json"
    code = eb.run_engine("boost", 4, 0, None, str(out), runner=runner)
    env = json.loads(out.read_text(encoding="utf-8"))
    assert code == 1
    assert env["success"] is False
    assert env["mode"] == "boost"
    assert env["data"] is None
    assert env["error"] == "netmax: --seconds must be 5..21600, got 0"


def test_bundled_flag_prepends_B_and_keeps_absolute_engine_path():
    cmd, _dropped = eb.build_command("dns", python=PY, bundled=True)
    assert cmd[:2] == [PY, "-B"] and cmd[2] == str(eb.ENGINE_PATH)


def test_auto_detect_bundled_matches_file_location():
    # Dev checkout: not bundled. (The deployed bundle copy self-detects.)
    assert eb._is_bundled() is False


# ── envelope writer + stderr tail ────────────────────────────────────────────


def test_write_envelope_success_shape(tmp_path):
    path = tmp_path / "out.json"
    payload = eb.write_envelope(path, success=True, mode="m",
                                data={"a": 1}, error=None)
    on_disk = json.loads(path.read_text(encoding="utf-8"))
    assert on_disk == payload
    assert on_disk == {"success": True, "mode": "m", "data": {"a": 1},
                       "error": None}


def test_write_envelope_failure_shape(tmp_path):
    path = tmp_path / "out.json"
    eb.write_envelope(path, success=False, mode="m", data=None,
                      error="boom")
    on_disk = json.loads(path.read_text(encoding="utf-8"))
    assert set(on_disk) == {"success", "mode", "data", "error"}
    assert on_disk["success"] is False
    assert on_disk["data"] is None
    assert on_disk["error"] == "boom"


def test_stderr_tail_caps_at_400_chars():
    assert len(eb.stderr_tail("x" * 500)) == 400
    assert eb.stderr_tail("") == ""


# ── stdout parsing ───────────────────────────────────────────────────────────


def test_parse_engine_stdout_json_object_embedded_parsed():
    assert eb.parse_engine_stdout('{"mbps": 42}') == {"mbps": 42}


def test_parse_engine_stdout_human_text_wrapped_as_raw():
    out = eb.parse_engine_stdout("download 100.0 Mbps\n✓ done")
    assert out == {"raw": "download 100.0 Mbps\n✓ done"}


# ── run_engine end-to-end with mocked subprocess.run ────────────────────────


def test_run_success_envelope_exit_0(tmp_path):
    seen = {}

    def runner(cmd, **kw):
        seen.update(kw)
        seen["cmd"] = cmd
        return _completed(0, stdout='{"mbps": 123.4}')

    code, env = _run(runner, tmp_path)
    assert code == 0
    assert env == {"success": True, "mode": "turbo", "data": {"mbps": 123.4},
                   "error": None}
    assert seen["cmd"][1:] == [str(eb.ENGINE_PATH), "turbo", "--streams", "4",
                               "--seconds", "9"]
    assert seen["cwd"] == str(REPO_ROOT)
    assert seen["timeout"] == eb.TIMEOUT_S
    assert seen["capture_output"] is True


def test_run_nonzero_exit_failure_envelope_exit_1(tmp_path):
    def runner(cmd, **kw):
        return _completed(2, stdout="",
                          stderr="netmax: --streams must be 1..32, got 99\n")

    code, env = _run(runner, tmp_path)
    assert code == 1
    assert env["success"] is False
    assert "--streams must be 1..32" in env["error"]
    assert env["data"] is None


def test_run_missing_interpreter_file_not_found(tmp_path):
    def runner(cmd, **kw):
        raise FileNotFoundError(2, "No such file or directory")

    code, env = _run(runner, tmp_path)
    assert code == 1
    assert env["success"] is False
    assert "No such file or directory" in env["error"]
    assert env["data"] is None


def test_run_timeout_kills_and_fails_envelope(tmp_path):
    seen = {}

    def runner(cmd, **kw):
        seen["timeout"] = kw.get("timeout")
        raise _timeout_exc()

    code, env = _run(runner, tmp_path)
    assert seen["timeout"] == eb.TIMEOUT_S
    assert code == 1
    assert env["success"] is False
    assert "timed out" in env["error"]
    assert env["data"] is None


def test_run_stderr_longer_than_400_truncated_to_tail(tmp_path):
    def runner(cmd, **kw):
        return _completed(1, stdout="", stderr="A" * 250 + "B" * 300)

    code, env = _run(runner, tmp_path)
    assert code == 1
    assert len(env["error"]) == 400
    assert env["error"].endswith("B" * 300)  # newest output kept intact
    assert not env["error"].startswith("A" * 250)  # oldest head dropped


def test_run_failure_with_empty_stderr_gets_synthetic_error(tmp_path):
    def runner(cmd, **kw):
        return _completed(returncode=3)

    code, env = _run(runner, tmp_path)
    assert code == 1
    assert env["error"] == "engine exited with code 3"


def test_run_raw_stdout_wrapped_when_not_json(tmp_path):
    def runner(cmd, **kw):
        return _completed(0, stdout="human text output\nline two")

    code, env = _run(runner, tmp_path)
    assert code == 0
    assert env["success"] is True
    assert env["data"] == {"raw": "human text output\nline two"}


def test_run_never_raises_past_call(tmp_path):
    """Contract: every failure lands in the envelope, none escape."""

    class Boom(Exception):
        pass

    def runner(cmd, **kw):
        raise OSError(5, "io exploded")

    try:
        code, env = _run(runner, tmp_path)
        assert code == 1 and env["success"] is False
    except Exception as exc:  # pragma: no cover - failure of the contract
        pytest.fail(f"run_engine leaked an exception: {exc!r}")


# ── CLI surface ──────────────────────────────────────────────────────────────


def test_cli_run_happy_path_via_main(monkeypatch, tmp_path):
    out = tmp_path / "cli.json"
    monkeypatch.setattr(
        eb.subprocess, "run",
        lambda *a, **k: _completed(0, stdout=json.dumps({"ok": True})),
    )
    rc = eb.main(["run", "loss", "--count", "3", "--json-out", str(out)])
    assert rc == 0
    env = json.loads(out.read_text(encoding="utf-8"))
    assert env["success"] is True and env["data"] == {"ok": True}


def test_cli_rejects_unknown_mode(tmp_path):
    # argparse errors are routed through parser.error -> envelope + exit 1.
    out = tmp_path / "x.json"
    with pytest.raises(SystemExit) as excinfo:
        eb.main(["run", "not-a-mode", "--json-out", str(out)])
    assert excinfo.value.code == 1


def test_cli_unknown_mode_writes_failure_envelope(tmp_path, capsys):
    out = tmp_path / "bad.json"
    with pytest.raises(SystemExit):
        eb.main(["run", "not-a-mode", "--json-out", str(out)])
    env = json.loads(out.read_text(encoding="utf-8"))
    assert set(env) == {"success", "mode", "data", "error"}
    assert env["success"] is False
    assert env["mode"] == "not-a-mode"
    assert env["data"] is None
    assert "not-a-mode" in env["error"]
    assert len(env["error"]) <= eb.STDERR_TAIL_CHARS
    assert "engine_bridge" in capsys.readouterr().err


def test_cli_invalid_arg_value_writes_envelope_with_mode(tmp_path):
    # --count must be int; 'abc' is a usage error, mode still derivable.
    out = tmp_path / "missing.json"
    with pytest.raises(SystemExit) as excinfo:
        eb.main(["run", "loss", "--count", "abc", "--json-out", str(out)])
    assert excinfo.value.code == 1
    env = json.loads(out.read_text(encoding="utf-8"))
    assert env["success"] is False and env["mode"] == "loss"
    assert env["data"] is None and env["error"]


def test_cli_usage_error_without_json_out_still_exits_nonzero(capsys):
    with pytest.raises(SystemExit) as excinfo:
        eb.main(["run", "nope"])
    assert excinfo.value.code == 1
    assert "engine_bridge" in capsys.readouterr().err


def test_argv_json_out_parses_space_and_eq_forms():
    assert eb._argv_json_out(["run", "dns", "--json-out", "/tmp/a.json"]) == \
        "/tmp/a.json"
    assert eb._argv_json_out(["run", "dns", "--json-out=/tmp/b.json"]) == \
        "/tmp/b.json"
    assert eb._argv_json_out(["run", "dns"]) is None


def test_cli_selftest_subcommand_exits_zero(capsys):
    assert eb.main(["selftest"]) == 0
    assert "PASS" in capsys.readouterr().out


# ── selftest itself ──────────────────────────────────────────────────────────


def test_selftest_passes_all_offline_checks(capsys):
    rc = eb.selftest()
    captured = capsys.readouterr()
    assert rc == 0
    for name in ("arg_mapping_per_mode", "envelope_writer_temp_file",
                 "interpreter_resolution_mocked_env"):
        assert f"PASS {name}" in captured.out
    assert "FAIL" not in captured.out


def test_selftest_reports_and_fails_on_broken_check(capsys):
    original = eb._check_arg_mapping

    def broken():
        raise AssertionError("seeded failure")

    eb._check_arg_mapping = broken
    try:
        rc = eb.selftest()
    finally:
        eb._check_arg_mapping = original
    captured = capsys.readouterr()
    assert rc == 1
    assert "FAIL arg_mapping_per_mode: seeded failure" in captured.out
