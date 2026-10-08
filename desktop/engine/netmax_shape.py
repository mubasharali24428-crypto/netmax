#!/usr/bin/env python3
"""netmax_shape — system-wide strict speed cap via dnctl + pf (macOS, root).

Unlike `limit` mode (which only paces NetMax's own curl downloads), this
shapes EVERYTHING on the machine: browsers, updaters, other devices can't
— this is the local pipe only. Requires root (`sudo`); refuses otherwise.

Safety contract (never violated, even on crash):
- All rules live in the `netmax_strict_limit` pf ANCHOR. Setup is
  transactional: any failed step rolls back only what NetMax added (its
  anchor contents, its pipe, its two main-ruleset references, and pf's
  enabled state). A stale whole-ruleset snapshot is never reloaded; the
  legacy anchor `netmax` / pipe 10 are foreign and are refused, not flushed.
- Serialized with root-owned `/var/run/netmax-shaping.lock`.
- Dynamic pipe allocation in 20000–29999.
- Owner state persisted in `/var/run/netmax-shaping/owner.json` (mode 0600).
- Loopback (`lo0`) is never shaped — local IPC, editors, and MCP clients
  keep full speed; only off-machine traffic passes the pipe.
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import secrets
import signal
import subprocess
import tempfile
import time as _time
from pathlib import Path

PIPE_START = 20000
PIPE_END = 29999
PIPE_NO = PIPE_START  # default for standalone anchor_rules() calls
ANCHOR = "netmax_strict_limit"
LEGACY_ANCHOR = "netmax"  # pre-1.2 names: foreign state, never touched
LEGACY_PIPE = 10


def _can_write_var_run() -> bool:
    return os.geteuid() == 0 and os.access("/var/run", os.W_OK)


def _default_paths():
    if _can_write_var_run():
        d = "/var/run"
    else:
        d = os.path.join(tempfile.gettempdir(), f"netmax-run-{os.getuid()}")
    return (
        os.path.join(d, "netmax-shaping.lock"),
        os.path.join(d, "netmax-shaping"),
        os.path.join(d, "netmax-shaping", "owner.json"),
    )


_def_lock, _def_dir, _def_file = _default_paths()
LOCK_PATH = _def_lock
STATE_DIR = _def_dir
STATE_FILE = _def_file


class ShapeError(Exception):
    """Raised for every shaper failure — deliberately NOT netmax.NetMaxError."""


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


def strip_main_rules(existing: str, anchor: str = ANCHOR) -> str:
    """Remove only our anchor references; every other line is untouched."""
    ref = re.compile(rf'^(dummynet-)?anchor "{re.escape(anchor)}"( .*)?$')
    return "".join(ln for ln in existing.splitlines(keepends=True) if not ref.match(ln.rstrip("\n")))


def foreign_state_error(rules: str, pipes: str) -> str | None:
    """Refuse when the legacy NetMax anchor/pipe exists: we cannot prove it is ours."""
    if f'"{LEGACY_ANCHOR}"' in rules or re.search(rf"^0*{LEGACY_PIPE}:", pipes, re.M):
        return (
            f'legacy shaping state (pf anchor "{LEGACY_ANCHOR}" or dnctl pipe {LEGACY_PIPE}) is '
            "present and is treated as foreign — not touching it. Inspect with `sudo pfctl -s rules` "
            f"and `sudo dnctl list`; if stale, clear it manually: `sudo pfctl -a {LEGACY_ANCHOR} -F all` "
            f"and `sudo dnctl pipe {LEGACY_PIPE} delete`"
        )
    return None


def allocate_pipe(used_text: str) -> int:
    """Choose the first unused pipe ID in 20000–29999; raises if exhausted."""
    used = {int(m.group(1)) for m in re.finditer(r"^0*([0-9]+):", used_text, re.M)}
    for pipe in range(PIPE_START, PIPE_END + 1):
        if pipe not in used:
            return pipe
    raise ShapeError(f"all shaping pipes in {PIPE_START}–{PIPE_END} are in use")


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def acquire_lock(lock_path: str | None = None):
    """Serialize shaping; caller must hold the returned file descriptor."""
    lock_path = lock_path or LOCK_PATH
    os.makedirs(os.path.dirname(lock_path), exist_ok=True)
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (BlockingIOError, OSError) as exc:
        os.close(fd)
        raise ShapeError("another shaping process is running or holding the lock") from exc
    return fd


def save_owner(state: dict, state_dir: str | None = None, state_file: str | None = None) -> None:
    state_dir = state_dir or STATE_DIR
    state_file = state_file or STATE_FILE
    os.makedirs(state_dir, mode=0o700, exist_ok=True)
    tmp = f"{state_file}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(state, fh)
    os.chmod(tmp, 0o600)
    os.replace(tmp, state_file)


def clear_owner(token: str, state_file: str | None = None) -> bool:
    """Remove owner.json iff its token matches; returns True if removed."""
    state_file = state_file or STATE_FILE
    try:
        with open(state_file, encoding="utf-8") as fh:
            cur = json.load(fh)
        if cur.get("token") == token:
            try:
                os.unlink(state_file)
            except FileNotFoundError:
                pass
            return True
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        pass
    return False


def recover_stale_owner(run=None, write=None, state_file: str | None = None) -> None:
    """Recover a dead owner's state; fail closed if ownership cannot be proven."""
    state_file = state_file or STATE_FILE
    try:
        with open(state_file, encoding="utf-8") as fh:
            owner = json.load(fh)
    except FileNotFoundError:
        return
    except Exception as exc:
        raise ShapeError(f"corrupt owner file {state_file}; clear manually: {exc}") from exc
    pid = owner.get("pid")
    if pid and _pid_alive(pid):
        raise ShapeError(f"shaping is currently active (PID {pid}, token {owner.get('token')})")
    # Dead PID: verify NetMax markers match before rolling back
    if owner.get("anchor") != ANCHOR or not (PIPE_START <= int(owner.get("pipe_no", 0)) <= PIPE_END):
        raise ShapeError(
            f"unrecognized owner metadata in {state_file} — manual cleanup required: "
            f"sudo pfctl -a {ANCHOR} -F all && sudo rm -f {state_file}"
        )
    remove(owner, run=run, write=write)
    try:
        os.unlink(state_file)
    except OSError:
        pass


def pf_enabled(runner=None) -> bool:
    """True iff pf is currently enabled (`pfctl -s info`)."""
    run = runner or _run
    proc = run(["pfctl", "-s", "info"])
    return "Status: Enabled" in (proc.stdout or "")


def require_root(mbps: float) -> None:
    """Pre-flight root check."""
    if os.geteuid() != 0:
        raise ShapeError(
            "limit --strict shapes the whole system and needs root — "
            "re-run with sudo (e.g. sudo python3 netmax.py limit --strict "
            f"--mbps {mbps:g})"
        )


def engine_integrity_error(engine_dir: str | None = None) -> str | None:
    """Fail-closed integrity check on the engine root."""
    root = Path(engine_dir) if engine_dir is not None else Path(__file__).resolve().parent
    try:
        if root.stat().st_mode & 0o022:
            return f"engine dir is group/world-writable: {root}"
        offenders = sorted(
            child.name for child in root.iterdir()
            if child.suffix == ".py" and child.stat().st_mode & 0o022
        )
    except OSError as exc:
        return f"cannot inspect engine dir {root}: {exc}"
    if offenders:
        return (
            "engine files are group/world-writable "
            f"({', '.join(offenders)}); fix with chmod 755/644"
        )
    return None


def _step(run, label: str, argv: list[str]) -> str | None:
    """Run one mutation; returns an error string (never raises) when it did not succeed."""
    try:
        return None if run(argv).returncode == 0 else f"{label} failed"
    except Exception as exc:
        return f"{label}: {exc}"


def apply(mbps: float, run=None, write=None) -> dict:
    """Install the cap transactionally; returns state needed by remove()."""
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
    pipes_out = run(["dnctl", "list"]).stdout or ""
    foreign = foreign_state_error(existing.stdout or "", pipes_out)
    if foreign:
        raise ShapeError(foreign)
    pipe_no = allocate_pipe(pipes_out)
    state = {
        "was_enabled": was_enabled,
        "rate": rate,
        "pipe_no": pipe_no,
        "we_enabled": False,
        "token": secrets.token_hex(16),
        "pid": os.getpid(),
        "anchor": ANCHOR,
    }

    def fail(msg: str):
        errs = remove(state, run=run, write=write)
        tail = f"; rollback problems: {'; '.join(errs)}" if errs else " — rolled back, nothing installed"
        raise ShapeError(msg + tail)

    anchor_path = write(anchor_rules(pipe_no))
    for label, argv in (
        (f"dnctl refused pipe bw {rate}", ["dnctl", "pipe", str(pipe_no), "config", "bw", rate]),
        ("pf refused the netmax_strict_limit anchor", ["pfctl", "-a", ANCHOR, "-f", anchor_path]),
    ):
        if _step(run, label, argv):
            fail(label)
    fresh = run(["pfctl", "-s", "rules"])
    if was_enabled and fresh.returncode != 0:
        fail("could not re-read pf rules")
    main_path = write(merge_main_rules(fresh.stdout or ""))
    if not was_enabled:
        if _step(run, "pfctl -e", ["pfctl", "-e"]):
            fail("pf could not be enabled")
        state["we_enabled"] = True
    if _step(run, "pf merged ruleset", ["pfctl", "-f", main_path]):
        fail("pf refused the merged ruleset")
    return state


def remove(state: dict, run=None, write=None) -> list[str]:
    """Tear down only what NetMax added; returns error strings, never raises."""
    run = run or _run
    write = write or _write_temp
    errs = [
        e for e in (
            _step(run, "flush anchor", ["pfctl", "-a", ANCHOR, "-F", "all"]),
            _step(run, "delete pipe", ["dnctl", "pipe", str(state.get("pipe_no", PIPE_NO)), "delete"]),
        ) if e
    ]
    try:
        current = run(["pfctl", "-s", "rules"]).stdout or ""
        stripped = strip_main_rules(current)
        if stripped != current:
            err = _step(run, "remove anchor reference", ["pfctl", "-f", write(stripped)])
            errs += [err] if err else []
    except Exception as exc:
        errs.append(f"remove anchor reference: {exc}")
    if state.get("we_enabled", not state.get("was_enabled", False)):
        err = _step(run, "restore pf disabled", ["pfctl", "-d"])
        errs += [err] if err else []
    return errs


def hold(mbps: float, seconds: int, run=None, write=None, sleep=None) -> float:
    """Hold the system-wide cap for `seconds`; returns the held Mbps."""
    from netmax import _checked_duration

    seconds = _checked_duration(seconds)
    prev_term = signal.getsignal(signal.SIGTERM)

    def _on_term(_signum, _frame):
        raise SystemExit(143)

    signal.signal(signal.SIGTERM, _on_term)
    lock_fd = acquire_lock()
    try:
        recover_stale_owner(run=run, write=write)
        state = apply(mbps, run=run, write=write)
        save_owner(state)
        sleep = sleep or _time.sleep
        try:
            deadline = _time.monotonic() + seconds
            while _time.monotonic() < deadline:
                sleep(min(1.0, deadline - _time.monotonic()))
        finally:
            remove(state, run=run, write=write)
            clear_owner(state.get("token"))
    finally:
        os.close(lock_fd)
        signal.signal(signal.SIGTERM, prev_term)
    return mbps
