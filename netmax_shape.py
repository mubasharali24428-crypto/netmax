#!/usr/bin/env python3
"""netmax_shape — system-wide strict speed cap via dnctl + pf (macOS, root).

Unlike `limit` mode (which only paces NetMax's own curl downloads), this
shapes EVERYTHING on the machine: browsers, updaters, other devices can't
— this is the local pipe only. Requires root (`sudo`); refuses otherwise.

Safety contract (never violated, even on crash):
- All rules live in the `netmax` pf ANCHOR — the user's main ruleset is
  read first and restored byte-identical on exit.
- Loopback (`lo0`) is never shaped — local IPC, editors, and MCP clients
  keep full speed; only off-machine traffic passes the pipe.
- `remove()` runs in a `finally` — Ctrl-C still cleans up.

Every OS seam (`_run`, `_write_temp`, `os.geteuid`) is module-level so the
offline suite can fake it (cf. tests/conftest.py tripwires).
"""

from __future__ import annotations

import os
import signal
import subprocess
import tempfile
import time as _time
from pathlib import Path

PIPE_NO = 10
ANCHOR = "netmax"


class ShapeError(Exception):
    """Raised for every shaper failure — deliberately NOT netmax.NetMaxError.

    When the CLI runs as a script, `netmax` is `__main__`, so this module's
    `from netmax import …` loads a SECOND copy whose NetMaxError is a
    different class object — the CLI's `except NetMaxError` would miss it
    and print a traceback. A dedicated error caught explicitly at the
    dispatch site sidesteps the dual-module trap (sibling modules only
    ever READ netmax globals, never raise across the boundary).
    """


def _run(argv: list[str], input_text: str | None = None) -> subprocess.CompletedProcess:
    """Run one privileged command; callers check returncode themselves."""
    return subprocess.run(
        argv, input=input_text, capture_output=True, text=True, timeout=60,
    )


def _write_temp(text: str) -> str:
    """Spill a ruleset to a temp file; returns its path."""
    fd, path = tempfile.mkstemp(prefix="netmax-pf-", suffix=".conf")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(text)
    return path


def kbit_str(mbps: float) -> str:
    """2.0 → '2000Kbit/s' — dnctl's bw unit (no floats, Kbit keeps 0.5 exact)."""
    from netmax import _checked_mbps

    _checked_mbps(mbps)
    return f"{round(mbps * 1000)}Kbit/s"


def anchor_rules(pipe_no: int = PIPE_NO) -> str:
    """pf anchor body: everything off lo0 through the pipe, both directions."""
    return (
        f"dummynet in quick on ! lo0 all pipe {pipe_no}\n"
        f"dummynet out quick on ! lo0 all pipe {pipe_no}\n"
    )


def merge_main_rules(existing: str, anchor: str = ANCHOR) -> str:
    """Existing main ruleset + our anchor refs (idempotent — no doubles)."""
    refs = f'dummynet-anchor "{anchor}"\nanchor "{anchor}"\n'
    if f'"{anchor}"' in existing:
        return existing
    if existing and not existing.endswith("\n"):
        existing += "\n"
    return existing + refs


def pf_enabled(runner=None) -> bool:
    """True iff pf is currently enabled (`pfctl -s info`)."""
    run = runner or _run
    proc = run(["pfctl", "-s", "info"])
    return "Status: Enabled" in (proc.stdout or "")


def require_root(mbps: float) -> None:
    """Pre-flight root check — call before printing anything, so a refusal
    never trails already-printed progress (stdout/stderr interleave)."""
    if os.geteuid() != 0:
        raise ShapeError(
            "limit --strict shapes the whole system and needs root — "
            "re-run with sudo (e.g. sudo python3 netmax.py limit --strict "
            f"--mbps {mbps:g})"
        )


def engine_integrity_error(engine_dir: str | None = None) -> str | None:
    """Fail-closed integrity check on the engine root will execute.

    The privileged python imports its SIBLINGS (netmax, netmetrics, …) as
    root — a group/world-writable engine file (or directory, which allows
    replacing files and planting __pycache__) turns the next strict hold
    into arbitrary root code execution for anyone else on the machine.
    Returns an error string when anything is off, else None.
    """
    root = Path(engine_dir) if engine_dir is not None else Path(__file__).resolve().parent
    try:
        if root.stat().st_mode & 0o022:
            return f"engine dir is group/world-writable: {root}"
        offenders = sorted(
            child.name for child in root.iterdir()
            if child.suffix == ".py" and child.stat().st_mode & 0o022)
    except OSError as exc:
        return f"cannot inspect engine dir {root}: {exc}"
    if offenders:
        return ("engine files are group/world-writable "
                f"({', '.join(offenders)}); fix with chmod 755/644")
    return None


def apply(mbps: float, run=None, write=None) -> dict:
    """Install the cap; returns state needed by remove(). Raises if not root."""
    require_root(mbps)
    bad = engine_integrity_error()
    if bad is not None:
        raise ShapeError(bad)
    run = run or _run
    write = write or _write_temp
    rate = kbit_str(mbps)
    was_enabled = pf_enabled(run)
    existing = run(["pfctl", "-s", "rules"])
    if was_enabled and existing.returncode != 0:
        raise ShapeError("could not read current pf rules — refusing to touch pf")
    main_path = write(merge_main_rules(existing.stdout or ""))
    anchor_path = write(anchor_rules())
    run(["pfctl", "-e"])  # no-op when already enabled; returncode ignored
    if run(["pfctl", "-f", main_path]).returncode != 0:
        raise ShapeError("pf refused the merged ruleset — nothing installed")
    if run(["dnctl", "pipe", str(PIPE_NO), "config", "bw", rate]).returncode != 0:
        raise ShapeError(f"dnctl refused pipe bw {rate} — nothing installed")
    if run(["pfctl", "-a", ANCHOR, "-f", anchor_path]).returncode != 0:
        run(["dnctl", "pipe", str(PIPE_NO), "delete"])
        raise ShapeError("pf refused the netmax anchor — pipe deleted, nothing installed")
    return {"was_enabled": was_enabled, "rate": rate}


def remove(state: dict, run=None) -> None:
    """Tear everything down; restores pf to its prior state. Never raises."""
    run = run or _run
    try:
        run(["pfctl", "-a", ANCHOR, "-F", "all"])
        run(["dnctl", "pipe", str(PIPE_NO), "delete"])
        if not state.get("was_enabled", False):
            run(["pfctl", "-d"])  # we enabled it; turn it back off
    except Exception:
        pass  # cleanup must never raise out of a finally block


def hold(mbps: float, seconds: int, run=None, write=None,
         sleep=None) -> float:
    """Hold the system-wide cap for `seconds`; returns the held Mbps.

    A SIGTERM guard is installed for the whole hold: harness timeouts
    (MCP execFile, Swift task cancel) kill with SIGTERM, whose default
    disposition would skip the `finally` and strand the pf rules. The
    guard converts it to SystemExit so cleanup still runs, then restores
    the previous disposition.
    """
    from netmax import _checked_duration

    seconds = _checked_duration(seconds)
    prev_term = signal.getsignal(signal.SIGTERM)

    def _on_term(_signum, _frame):
        raise SystemExit(143)

    signal.signal(signal.SIGTERM, _on_term)
    try:
        state = apply(mbps, run=run, write=write)
        sleep = sleep or _time.sleep
        try:
            deadline = _time.monotonic() + seconds
            while _time.monotonic() < deadline:
                sleep(min(1.0, deadline - _time.monotonic()))
        finally:
            remove(state, run=run)
    finally:
        signal.signal(signal.SIGTERM, prev_term)
    return mbps
