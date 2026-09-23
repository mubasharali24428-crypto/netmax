"""WiFi event store (contract TC3) — JSONL persistence for timeline markers.

Mirrors ``HistoryStore.swift`` conventions one-for-one, on the Python side:

- Storage is append-only JSON Lines at
  ``~/Library/Application Support/NetMaxDesktop/wifi_events.jsonl``:
  one event object per line, oldest-first on disk.
- Event shape (mission W5 graph, Squad 1): ``{"ts": <ISO8601>, "kind": str,
  "details": {...}}`` with ``kind`` ∈ roam / rssi_drop / channel_change
  (open set — readers tolerate future kinds).
- Failure policy: capture must never take the poller down. Unreadable or
  corrupt lines are skipped silently on load; append errors are swallowed
  (reported via the ``False`` return instead of raising). The storage
  directory is created lazily on first write.
- Thread safety: every public function takes a shared lock, so the poller,
  ScheduleRunner, and any UI reader can hit the store concurrently.

Timestamps follow HistoryStore's ISO8601 encoder output
(``2026-08-24T12:34:56Z``, UTC, second precision); timezone-less stamps in
existing files are read as UTC, matching ``netmax_retention.parse_ts``.

Stdlib only. Intended callers: ``netmax_wifievents.py`` (E1 poller appends),
Swift timeline merge (reads the same file via its own tolerant decoder).
"""

from __future__ import annotations

import json
import os
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

__all__ = ["EVENT_KINDS", "append_event", "clear", "default_path", "load_events"]

# Kinds the W5 poller emits today. Open set: unknown kinds still round-trip.
EVENT_KINDS = ("roam", "rssi_drop", "channel_change")

_LOCK = threading.Lock()


def default_path() -> Path:
    """Contract TC3 location: ~/Library/Application Support/…/wifi_events.jsonl."""
    return (
        Path.home()
        / "Library"
        / "Application Support"
        / "NetMaxDesktop"
        / "wifi_events.jsonl"
    )


def _now_iso() -> str:
    """Current UTC instant in HistoryStore's ISO8601 wire format."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _resolve(path: str | os.PathLike[str] | None) -> Path:
    return Path(path) if path is not None else default_path()


def _parse_ts(raw: object) -> datetime | None:
    """Parse an ISO8601 ``ts`` value to an aware UTC datetime, else None.

    Tolerates a trailing ``Z`` and treats timezone-less stamps as UTC,
    matching netmax_retention.parse_ts / HistoryStore's encoder output.
    """
    if not isinstance(raw, str) or not raw.strip():
        return None
    text = raw.strip()
    if text.endswith(("Z", "z")):
        text = text[:-1] + "+00:00"
    try:
        stamp = datetime.fromisoformat(text)
    except ValueError:
        return None
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=timezone.utc)
    return stamp.astimezone(timezone.utc)


def _coerce_bound(bound: datetime | str | None) -> datetime | None:
    """Accept a datetime or an ISO8601 string for since/until; None passes through."""
    if bound is None or isinstance(bound, datetime):
        stamp = bound
    else:
        stamp = _parse_ts(bound)
        if stamp is None:
            raise ValueError(f"not an ISO8601 timestamp: {bound!r}")
    if stamp is not None and stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=timezone.utc)
    return stamp


# ── API ──────────────────────────────────────────────────────────────────────


def append_event(
    event: dict[str, Any], *, path: str | os.PathLike[str] | None = None
) -> bool:
    """Append one WiFi event as a single newline-terminated JSON line.

    Creates the containing directory and file lazily on first write.
    Thread-safe; the append is a single O_APPEND write, so concurrent
    writers (this poller, the desktop app) cannot interleave mid-line.

    The event is stored with exactly the contract keys ``ts``/``kind``/
    ``details``: an existing string ``ts`` is preserved verbatim, otherwise
    the current UTC instant is stamped. Extra keys are kept as-is (readers
    ignore them). Returns True on success, False if the write failed —
    capture is best-effort and must never crash the caller (HistoryStore's
    failure policy).
    """
    target = _resolve(path)
    record = dict(event)
    if not isinstance(record.get("ts"), str):
        record["ts"] = _now_iso()

    line = json.dumps(record, ensure_ascii=False) + "\n"

    with _LOCK:
        try:
            target.parent.mkdir(parents=True, exist_ok=True)
            fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            try:
                view = memoryview(line.encode("utf-8"))
                while view:  # paranoia: complete the write even if partial
                    view = view[os.write(fd, view):]
            finally:
                os.close(fd)
            return True
        except OSError:
            return False


def load_events(
    since: datetime | str | None = None,
    until: datetime | str | None = None,
    *,
    path: str | os.PathLike[str] | None = None,
) -> list[dict[str, Any]]:
    """Load readable events, oldest-first (file order).

    Missing file → empty list. Corrupt/partial lines — anything that fails
    to parse as a JSON object with a string ``kind``, a dict ``details`` and
    a parseable ISO8601 ``ts`` — are skipped silently, so a truncated last
    line (crash mid-write) costs nothing, exactly like HistoryStore.loadAll.

    Args:
        since: inclusive lower bound on ``ts`` (datetime or ISO8601 string;
          timezone-less values are treated as UTC). None = no lower bound.
        until: exclusive upper bound on ``ts`` (same forms). None = no upper
          bound. Half-open [since, until) so adjacent ranges never overlap.
        path: override the storage path (tests / self-checks).

    Events whose ``ts`` cannot be parsed are always dropped: the timeline
    merge is by ts sort, and an unparsable stamp has no place on it.
    """
    lo = _coerce_bound(since)
    hi = _coerce_bound(until)
    target = _resolve(path)

    with _LOCK:
        try:
            text = target.read_text(encoding="utf-8")
        except OSError:
            return []

    events: list[dict[str, Any]] = []
    for line in text.splitlines():
        trimmed = line.strip()
        if not trimmed:
            continue
        try:
            record = json.loads(trimmed)
        except ValueError:
            continue  # corrupt line: skip silently
        if not isinstance(record, dict):
            continue
        if not isinstance(record.get("kind"), str):
            continue
        if not isinstance(record.get("details"), dict):
            continue
        stamp = _parse_ts(record.get("ts"))
        if stamp is None:
            continue
        if lo is not None and stamp < lo:
            continue
        if hi is not None and stamp >= hi:
            continue
        events.append(record)
    return events


def clear(*, path: str | os.PathLike[str] | None = None) -> None:
    """Delete the entire event file. The next append recreates it. Thread-safe."""
    target = _resolve(path)
    with _LOCK:
        try:
            target.unlink()
        except FileNotFoundError:
            pass  # nothing to clear — already clean
        except OSError:
            pass  # best-effort, mirroring HistoryStore.clear
