"""Daemon wrapper around netmax_watch.watch_loop.

Runs the watch loop indefinitely as a single-instance daemon:
a PID lockfile in the temp dir prevents concurrent instances (with
stale-lock recovery), and SIGTERM/SIGINT set a shutdown flag so the
loop unwinds cleanly, prints the session summary, and exits 0.

Usage:
    python netmax_watch_daemon.py [--interval SECONDS]
"""

from __future__ import annotations

import argparse
import errno
import os
import signal
import sys
import tempfile
from pathlib import Path

import netmax
import netmax_watch

LOCKFILE_PREFIX = "netmax-watch-daemon"
MIN_INTERVAL_S = 5


def _lockfile_path() -> Path:
    """Return the per-user PID lockfile path in the system temp dir."""
    try:
        import getpass

        user = getpass.getuser()
    except Exception:  # pragma: no cover - fallback when no user context
        user = f"uid{os.getuid()}"
    return Path(tempfile.gettempdir()) / f"{LOCKFILE_PREFIX}.{user}.pid"


def _read_pid(path: Path) -> int | None:
    """Return the PID stored in the lockfile, or None if unreadable/garbage."""
    try:
        raw = path.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    try:
        return int(raw)
    except ValueError:
        return None


def _process_alive(pid: int) -> bool:
    """True if a process with pid exists (or is owned by another user)."""
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except OSError as exc:
        # EPERM: process exists but belongs to someone else -> alive.
        return exc.errno == errno.EPERM
    return True


def _acquire_lock(path: Path) -> bool:
    """Create the PID lockfile atomically; recover stale locks.

    Returns True if the lock was acquired. Refuses (False) when another
    live instance already holds it.
    """
    for _attempt in range(3):
        try:
            # 0o600 (audit F15): a world-readable lockfile in shared /tmp leaks
            # the daemon's PID and lets any local user pre-create/inspect it.
            fd = os.open(str(path), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError:
            pid = _read_pid(path)
            if pid == os.getpid():
                return True  # already ours (recovery raced us and lost)
            if pid is None or not _process_alive(pid):
                # Stale lock: dead owner or unparseable contents. Remove it.
                try:
                    path.unlink()
                except FileNotFoundError:
                    pass
                continue
            return False  # another live instance holds the lock
        else:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(f"{os.getpid()}\n")
            return True
    return False


def _release_lock(path: Path) -> None:
    """Remove the lockfile only if we still own it (PID matches ours)."""
    try:
        if _read_pid(path) == os.getpid():
            path.unlink()
    except OSError:
        pass


class ShutdownFlag:
    """Process-wide shutdown flag flipped by SIGTERM/SIGINT handlers."""

    def __init__(self) -> None:
        import threading

        self._event = threading.Event()

    def request(self, signum=None, frame=None) -> None:  # noqa: ARG001 - signal API
        self._event.set()

    @property
    def requested(self) -> bool:
        return self._event.is_set()

    def wait(self, timeout: float) -> bool:
        """Block up to timeout; return True as soon as shutdown is requested."""
        return self._event.wait(timeout)


def run_daemon(interval_s: int, shutdown: ShutdownFlag) -> list[dict]:
    """Watch forever via netmax_watch.watch_loop until shutdown is requested.

    Each sweep delegates one cycle to watch_loop (which owns per-cycle
    measurement, formatting and failure counting) and paces the next sweep
    with an interruptible wait, so a signal stops the daemon promptly
    instead of sleeping through a full interval. All cycles accumulate in
    one history list, returned to the caller for summarization.
    """
    history: list[dict] = []
    while not shutdown.requested:
        netmax_watch.watch_loop(interval_s, 1, history=history)
        if shutdown.requested:
            break
        shutdown.wait(timeout=float(interval_s))
    return history


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="netmax_watch_daemon",
        description=(
            "Single-instance watch daemon: runs netmax_watch.watch_loop "
            "every --interval seconds until SIGTERM/SIGINT, then prints "
            "the watch summary and exits 0."
        ),
    )
    parser.add_argument(
        "--interval",
        type=int,
        default=MIN_INTERVAL_S,
        metavar="SECONDS",
        help=f"seconds between watch cycles (int >= {MIN_INTERVAL_S}; default %(default)s)",
    )
    args = parser.parse_args(argv)

    if not isinstance(args.interval, int) or args.interval < MIN_INTERVAL_S:
        parser.error(f"--interval must be an int >= {MIN_INTERVAL_S}")

    lock_path = _lockfile_path()
    if not _acquire_lock(lock_path):
        holder = _read_pid(lock_path)
        print(
            f"netmax_watch_daemon: another instance appears to be running "
            f"(pid {holder}, lock {lock_path}); refusing to start.",
            file=sys.stderr,
        )
        return 1

    shutdown = ShutdownFlag()

    def _on_signal(signum, frame):  # noqa: ARG001 - signal handler API
        shutdown.request(signum, frame)

    prev_handlers = {}
    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            prev_handlers[sig] = signal.signal(sig, _on_signal)
        except (ValueError, OSError):
            # Not the main thread or unsupported platform signal; proceed.
            pass

    print(
        f"netmax_watch_daemon started: pid={os.getpid()} "
        f"interval={args.interval}s lock={lock_path}",
        flush=True,
    )
    exit_code = 0
    history: list[dict] = []
    try:
        history = run_daemon(args.interval, shutdown)
    except ValueError as exc:
        print(f"netmax_watch_daemon: bad configuration: {exc}", file=sys.stderr)
        exit_code = 2
    except KeyboardInterrupt:  # belt-and-braces if a handler was unavailable
        pass
    finally:
        for sig, handler in prev_handlers.items():
            try:
                signal.signal(sig, handler)
            except (ValueError, OSError):
                pass

    print(netmax.summarize_watch_history(history), flush=True)
    print("netmax_watch_daemon: clean shutdown.", flush=True)
    _release_lock(lock_path)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
