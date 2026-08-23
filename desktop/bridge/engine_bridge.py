#!/usr/bin/env python3
"""UI <-> engine bridge for NetMax Desktop (contract C1, mission P0).

CLI:
    engine_bridge.py run <mode> [--streams N] [--seconds N] [--count N] \
        --json-out PATH
    engine_bridge.py selftest

`run` executes `<python> netmax.py <mode> ...` from the repository root,
where <python> is $NETMAX_PYTHON (fallback: sys.executable), and writes a
JSON envelope to PATH:

    success: {"success": true,  "mode": ..., "data": {...}, "error": null}
    failure: {"success": false, "mode": ..., "data": null,
              "error": "<stderr tail <=400 chars>"}

Exit code mirrors the envelope: 0 on success, 1 on failure. This script
never raises past main(); every failure lands in the envelope.

Engine stdout is mostly human text: valid JSON is embedded parsed, any
other stdout is wrapped as {"raw": "..."} inside `data`.

`selftest` performs OFFLINE checks only (argument mapping, envelope
writer against a temp file, interpreter-resolution logic with mocked
env). It never spawns the engine and never touches the network.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from collections.abc import Mapping
from pathlib import Path
from typing import Any

# Repo root resolved from this file: desktop/bridge/engine_bridge.py
REPO_ROOT = Path(__file__).resolve().parents[2]
ENGINE_SCRIPT = "netmax.py"
TIMEOUT_S = 180
STDERR_TAIL_CHARS = 400

# mode -> flags the engine's argparse accepts for that mode (netmax.py
# subparsers near line 350). Only these are ever forwarded; anything else
# the caller passes on our CLI is dropped.
MODE_FLAGS: dict[str, tuple[str, ...]] = {
    "baseline": ("seconds",),
    "turbo": ("streams", "seconds"),
    "boost": ("streams", "seconds"),
    "dns": (),
    "bloat": ("streams", "seconds"),
    "full": ("streams", "seconds"),
    "upload": ("seconds",),
    "loss": ("count",),
    "jitter": ("count",),
    "wifi": (),
}
ALLOWED_MODES: tuple[str, ...] = tuple(MODE_FLAGS)

_FLAG_SPELLING = {"streams": "--streams", "seconds": "--seconds", "count": "--count"}


# ── pure helpers (unit-tested offline) ───────────────────────────────────────


def resolve_interpreter(env: Mapping[str, str] | None = None) -> str:
    """$NETMAX_PYTHON wins; empty/unset falls back to sys.executable."""
    environ = os.environ if env is None else env
    candidate = environ.get("NETMAX_PYTHON", "").strip()
    return candidate or sys.executable


def build_command(
    mode: str,
    streams: int | None = None,
    seconds: int | None = None,
    count: int | None = None,
    *,
    python: str | None = None,
) -> list[str]:
    """Full argv for the engine call; only mode-supported flags forwarded."""
    given: dict[str, int | None] = {
        "streams": streams,
        "seconds": seconds,
        "count": count,
    }
    cmd = [python if python is not None else resolve_interpreter(), ENGINE_SCRIPT, mode]
    for key in MODE_FLAGS[mode]:
        value = given[key]
        if value is not None:
            cmd += [_FLAG_SPELLING[key], str(int(value))]
    return cmd


def stderr_tail(text: str, limit: int = STDERR_TAIL_CHARS) -> str:
    """Last `limit` characters of `text` (contract: tail <=400 chars)."""
    return (text or "")[-limit:]


def write_envelope(
    path: str | os.PathLike[str],
    *,
    success: bool,
    mode: str,
    data: Any,
    error: str | None,
) -> dict[str, Any]:
    """Write the C1 envelope to `path`; returns what was written."""
    target = Path(path)
    parent = target.parent
    if str(parent) not in ("", "."):
        parent.mkdir(parents=True, exist_ok=True)
    payload: dict[str, Any] = {
        "success": bool(success),
        "mode": mode,
        "data": data,
        "error": error,
    }
    target.write_text(json.dumps(payload), encoding="utf-8")
    return payload


def parse_engine_stdout(stdout: str) -> Any:
    """Valid JSON stdout -> parsed object; otherwise {'raw': stdout}."""
    try:
        return json.loads(stdout)
    except (json.JSONDecodeError, ValueError):
        return {"raw": stdout}


# ── engine invocation ────────────────────────────────────────────────────────


def run_engine(
    mode: str,
    streams: int | None,
    seconds: int | None,
    count: int | None,
    json_out: str,
    *,
    runner=None,
    env: Mapping[str, str] | None = None,
    repo_root: Path | None = None,
    timeout_s: float = TIMEOUT_S,
) -> int:
    """Run one engine mode and write the envelope. Returns exit code."""
    root = REPO_ROOT if repo_root is None else Path(repo_root)
    command = build_command(
        mode, streams, seconds, count, python=resolve_interpreter(env)
    )
    try:
        completed = (subprocess.run if runner is None else runner)(
            command,
            cwd=str(root),
            capture_output=True,
            text=True,
            timeout=timeout_s,
        )
    except subprocess.TimeoutExpired:
        # subprocess.run killed the child before raising (contract: kill).
        write_envelope(
            json_out,
            success=False,
            mode=mode,
            data=None,
            error=f"engine timed out after {int(timeout_s)}s and was killed",
        )
        return 1
    except FileNotFoundError as exc:
        write_envelope(
            json_out, success=False, mode=mode, data=None, error=stderr_tail(str(exc))
        )
        return 1
    except OSError as exc:
        write_envelope(
            json_out, success=False, mode=mode, data=None, error=stderr_tail(str(exc))
        )
        return 1

    if completed.returncode == 0:
        write_envelope(
            json_out,
            success=True,
            mode=mode,
            data=parse_engine_stdout(completed.stdout),
            error=None,
        )
        return 0

    detail = stderr_tail(completed.stderr)
    if not detail:
        detail = f"engine exited with code {completed.returncode}"
    write_envelope(json_out, success=False, mode=mode, data=None, error=detail)
    return 1


# ── selftest (offline only: no engine spawn, no network) ────────────────────


def _check_arg_mapping() -> None:
    fixed_py = "/opt/fake-python/bin/python"
    expectations = [
        (("turbo", {"streams": 4, "seconds": 9}), [fixed_py, "netmax.py", "turbo", "--streams", "4", "--seconds", "9"]),
        (("baseline", {"seconds": 7}), [fixed_py, "netmax.py", "baseline", "--seconds", "7"]),
        (("dns", {}), [fixed_py, "netmax.py", "dns"]),
        (("loss", {"count": 20}), [fixed_py, "netmax.py", "loss", "--count", "20"]),
        (("wifi", {}), [fixed_py, "netmax.py", "wifi"]),
        # Unsupported flag for the mode is never forwarded.
        (("turbo", {"count": 99}), [fixed_py, "netmax.py", "turbo"]),
    ]
    for (mode, kwargs), expected in expectations:
        actual = build_command(mode, python=fixed_py, **kwargs)
        if actual != expected:
            raise AssertionError(f"{mode}: {actual} != {expected}")


def _check_envelope_writer(tmp_dir: str) -> None:
    ok_path = os.path.join(tmp_dir, "nested", "ok.json")
    written = write_envelope(
        ok_path, success=True, mode="turbo", data={"mbps": 42.5}, error=None
    )
    loaded = json.loads(Path(ok_path).read_text(encoding="utf-8"))
    if loaded != written or loaded["success"] is not True or loaded["error"] is not None:
        raise AssertionError(f"success envelope mismatch: {loaded}")

    bad_path = os.path.join(tmp_dir, "bad.json")
    write_envelope(bad_path, success=False, mode="full", data=None, error="boom")
    loaded = json.loads(Path(bad_path).read_text(encoding="utf-8"))
    keys = ("success", "mode", "data", "error")
    if set(loaded) != set(keys) or loaded["success"] or loaded["data"] is not None:
        raise AssertionError(f"failure envelope mismatch: {loaded}")


def _check_interpreter_resolution() -> None:
    if resolve_interpreter({"NETMAX_PYTHON": "/x/py"}) != "/x/py":
        raise AssertionError("NETMAX_PYTHON not honored")
    if resolve_interpreter({}) != sys.executable:
        raise AssertionError("empty env must fall back to sys.executable")
    if resolve_interpreter({"NETMAX_PYTHON": "   "}) != sys.executable:
        raise AssertionError("blank NETMAX_PYTHON must fall back")


def selftest() -> int:
    """Offline self-checks. Prints PASS/FAIL lines; exits 0/1."""
    results: list[tuple[str, bool, str]] = []
    with tempfile.TemporaryDirectory(prefix="netmax-bridge-selftest-") as tmp_dir:
        checks: list[tuple[str, Any]] = [
            ("arg_mapping_per_mode", lambda: _check_arg_mapping()),
            ("envelope_writer_temp_file", lambda: _check_envelope_writer(tmp_dir)),
            ("interpreter_resolution_mocked_env", _check_interpreter_resolution),
        ]
        for name, fn in checks:
            try:
                fn()
                results.append((name, True, ""))
            except Exception as exc:  # noqa: BLE001 - report, don't crash
                results.append((name, False, str(exc)))

    ok = True
    for name, passed, detail in results:
        if passed:
            print(f"PASS {name}")
        else:
            ok = False
            print(f"FAIL {name}: {detail}")
    print(f"selftest: {sum(p for _, p, _ in results)}/{len(results)} checks passed")
    return 0 if ok else 1


# ── CLI ──────────────────────────────────────────────────────────────────────


def _argv_mode(argv: list[str]) -> str | None:
    """Mode token from raw argv ('run <mode> ...'), if present."""
    if len(argv) >= 2 and argv[0] == "run":
        return argv[1]
    return None


def _argv_json_out(argv: list[str]) -> str | None:
    """--json-out value from raw argv (space or '=' form), if present."""
    for index, token in enumerate(argv):
        if token == "--json-out" and index + 1 < len(argv):
            return argv[index + 1]
        if token.startswith("--json-out="):
            return token.split("=", 1)[1]
    return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="engine_bridge",
        description="NetMax desktop UI <-> engine bridge (contract C1).",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    run_parser = sub.add_parser("run", help="run an engine mode, emit JSON envelope")
    run_parser.add_argument("mode", choices=ALLOWED_MODES)
    run_parser.add_argument("--streams", type=int, default=None)
    run_parser.add_argument("--seconds", type=int, default=None)
    run_parser.add_argument("--count", type=int, default=None)
    run_parser.add_argument("--json-out", dest="json_out", required=True)

    sub.add_parser("selftest", help="offline self-checks (no network, no engine)")

    def _fail_envelope(message: str) -> None:
        """argparse usage error -> C1 envelope (when derivable), exit 1."""
        raw = list(sys.argv[1:]) if argv is None else argv
        mode = _argv_mode(raw)
        if mode is not None:
            json_out = _argv_json_out(raw)
            detail = f"invalid arguments: {message}"[:STDERR_TAIL_CHARS]
            if json_out:
                write_envelope(json_out, success=False, mode=mode, data=None,
                               error=detail)
                print(f"engine_bridge: {detail}", file=sys.stderr)
            else:
                print(f"engine_bridge: {message}", file=sys.stderr)
        else:
            print(f"engine_bridge: {message}", file=sys.stderr)
        raise SystemExit(1)

    # Subparsers are separate ArgumentParser instances with their own
    # error(); route every parser's usage errors through the envelope.
    for err_parser in (parser, run_parser, sub.choices["selftest"]):
        err_parser.error = _fail_envelope  # type: ignore[method-assign]

    args = parser.parse_args(argv)
    if args.cmd == "selftest":
        return selftest()
    return run_engine(
        args.mode, args.streams, args.seconds, args.count, args.json_out
    )


if __name__ == "__main__":
    sys.exit(main())
