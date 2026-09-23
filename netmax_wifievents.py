#!/usr/bin/env python3
"""netmax_wifievents.py -- WiFi event detector (Mission W5, lane E1).

Polls `system_profiler SPAirPortDataType` every N seconds (default 30),
diffs consecutive snapshots, and emits events::

    {"ts": "2026-08-24T12:00:30Z", "kind": "roam",
     "details": {...}}

Event kinds (W5 graph contract, Squad 1 / E1):
    roam            SSID or BSSID changed between polls
    channel_change  current channel number changed
    rssi_drop       RSSI fell by more than RSSI_DROP_THRESHOLD_DB (10 dB)
    rssi_recover    RSSI rose by at least the same threshold after a sample

PLATFORM NOTE (honest limitation): macOS 14.4+ removed the private
`/System/Library/PrivateFrameworks/Apple80211.frameworkairport` binary, so
the classic push-style `airport -I` watch loop is unavailable. This module
therefore POLLS system_profiler instead; detection latency is bounded by the
poll interval, not instantaneous.
[UNCERTAIN] Alternative: bind CoreWLAN via PyObjC and observe
CWEventType notifications (roam/link quality) for true push events. Not used
here because PyObjC is a third-party dependency and this repo is stdlib-only;
if that constraint lifts, `CWInterface.interface().monitorEventDelivery_()`
is the documented entry point.

Output goes through E2's event store when present (contract TC3:
~/Library/Application Support/NetMaxDesktop/wifi_events.jsonl); otherwise it
falls back to printing JSON lines on stdout (one event per line).

Stdlib only. Owned path: netmax_wifievents.py (do not edit siblings here).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import threading
from collections.abc import Callable
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# --- Sibling dependency (E2's event store) ---------------------------------
# E2 owns netmax_eventstore.py and lands it separately; until it appears in
# the repo root we degrade gracefully to stdout JSON lines. This import guard
# is deliberate, not an error.
try:
    from netmax_eventstore import append_event  # type: ignore

    EVENTSTORE_AVAILABLE = True
except ImportError:  # pragma: no cover - depends on sibling lane landing
    append_event = None
    EVENTSTORE_AVAILABLE = False


DEFAULT_INTERVAL_S = 30
RSSI_DROP_THRESHOLD_DB = 10.0
PROFILER_TIMEOUT_S = 30

# Snapshot parsing -----------------------------------------------------------
# Field names observed in `system_profiler SPAirPortDataType -json`; several
# have varied across macOS releases, so candidates are tried in order and a
# missing field becomes None rather than a crash.
_SIGNAL_KEYS = ("spairport_signal_noise", "spairport_signal_or_noise")
_CHANNEL_KEYS = (
    "spairport_current_network_wireless_channel",
    "spairport_network_channel",
)
_BSSID_KEY = "spairport_mac_address"

_SIGNAL_NOISE_RE = re.compile(r"\s*(-?\d+)\s*dBm\s*/\s*(-?\d+)\s*dBm")
_CHANNEL_RE = re.compile(r"(\d+)\s*\((\w+GHz)")


def _first(v: dict, keys: tuple[str, ...]) -> Any:
    for k in keys:
        if k in v and v[k] is not None:
            return v[k]
    return None


def _now_iso() -> str:
    """UTC timestamp, second resolution, RFC3339-style trailing Z."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_snapshot(profiler_json: str) -> dict:
    """Parse `system_profiler SPAirPortDataType -json` text -> snapshot dict.

    Returns {"associated": False} when no current network block exists
    (Wi-Fi off, disassociated, or Ethernet-only machine), otherwise:
    {"associated": True, "ssid": str, "bssid": str|None,
     "channel": str|None, "band": str|None,
     "rssi_dbm": int|None, "noise_dbm": int|None}

    Never raises on malformed content: unknown shapes degrade to fields=None.
    """
    try:
        data = json.loads(profiler_json)
        items = data.get("SPAirPortDataType") or []
        item = items[0] if items else {}
        cur = item.get("spairport_current_network_information")
    except (ValueError, AttributeError, IndexError, TypeError):
        return {"associated": False}

    # The block is a dict keyed by SSID ({SSID: {fields}}); tolerate a list
    # shape [ {fields} ] seen in some captures.
    if isinstance(cur, dict) and cur:
        key, fields = next(iter(cur.items()))
        ssid = key if isinstance(key, str) else None
    elif isinstance(cur, list) and cur:
        ssid, fields = None, cur[0]
    else:
        return {"associated": False}
    if not isinstance(fields, dict):
        return {"associated": False}

    sig = _first(fields, _SIGNAL_KEYS)
    chan = _first(fields, _CHANNEL_KEYS)
    sm = _SIGNAL_NOISE_RE.match(str(sig)) if sig is not None else None
    cm = _CHANNEL_RE.match(str(chan)) if chan is not None else None
    # F7: SSID/BSSID are hashed immediately — raw values exist only in this
    # function frame. Roam detection compares hashes (same inequality).
    return {
        "associated": True,
        "ssid": hash_identifier(ssid if isinstance(ssid, str) else None),
        "bssid": hash_identifier(_as_str(fields.get(_BSSID_KEY))),
        "channel": cm.group(1) if cm else (str(chan) if chan is not None else None),
        "band": cm.group(2) if cm else None,
        "rssi_dbm": int(sm.group(1)) if sm else None,
        "noise_dbm": int(sm.group(2)) if sm else None,
    }


def capture_snapshot() -> dict | None:
    """Run system_profiler once and parse it. Returns None on tool failure."""
    try:
        proc = subprocess.run(
            ["system_profiler", "SPAirPortDataType", "-json"],
            capture_output=True,
            text=True,
            timeout=PROFILER_TIMEOUT_S,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"netmax_wifievents: profiler error: {exc}", file=sys.stderr)
        return None
    if proc.returncode != 0:
        print(
            f"netmax_wifievents: profiler rc={proc.returncode}: "
            f"{proc.stderr.strip()[:120]}",
            file=sys.stderr,
        )
        return None
    return parse_snapshot(proc.stdout)


def _as_str(value: Any) -> str | None:
    """Coerce profiler fields to str (None stays None) — F7 hashing input."""
    return value if isinstance(value, str) and value else None


def _event(kind: str, details: dict, ts: str | None = None) -> dict:
    return {
        "ts": ts or _now_iso(),
        "kind": kind,
        "details": details,
    }


def diff_snapshots(
    prev: dict | None, curr: dict | None, ts: str | None = None
) -> list[dict]:
    """Diff two parsed snapshots -> list of events (pure; no I/O).

    Rules:
      * Either side missing/unparsed (None)          -> [] (no baseline yet)
      * Association gained/lost across the pair      -> [] (baseline resets to
        `curr`; comparing RSSI/BSSID across a dead interval would invent
        phantom drops and roams)
      * Both associated:
          roam            SSID differs, or both BSSIDs known and differ
          channel_change  both channels known and numerically different
          rssi_drop       both RSSIs known and prev - curr > threshold
          rssi_recover    both RSSIs known and curr - prev >= threshold
        (drop and recover are mutually exclusive by arithmetic)
    """
    if prev is None or curr is None:
        return []
    if not (prev.get("associated") and curr.get("associated")):
        return []

    events: list[dict] = []
    psid, csid = prev.get("ssid"), curr.get("ssid")
    pbssid, cbssid = prev.get("bssid"), curr.get("bssid")

    roamed = bool(psid and csid and psid != csid) or bool(
        pbssid and cbssid and pbssid != cbssid
    )
    if roamed:
        events.append(
            _event(
                "roam",
                {
                    # F7: hashed identifiers only — never raw SSID/BSSID
                    "from_ssid_hash": psid,
                    "to_ssid_hash": csid,
                    "from_bssid_hash": pbssid,
                    "to_bssid_hash": cbssid,
                },
                ts=ts,
            )
        )

    pch, cch = prev.get("channel"), curr.get("channel")
    if pch is not None and cch is not None and str(pch) != str(cch):
        events.append(
            _event(
                "channel_change",
                {
                    "from_channel": str(pch),
                    "to_channel": str(cch),
                    "band": curr.get("band"),
                },
                ts=ts,
            )
        )

    prssi, crssi = prev.get("rssi_dbm"), curr.get("rssi_dbm")
    if prssi is not None and crssi is not None:
        delta = prssi - crssi  # positive => got weaker
        if delta > RSSI_DROP_THRESHOLD_DB:
            events.append(
                _event(
                    "rssi_drop",
                    {
                        "previous_rssi_dbm": prssi,
                        "rssi_dbm": crssi,
                        "delta_db": -delta,
                    },
                    ts=ts,
                )
            )
        elif -delta >= RSSI_DROP_THRESHOLD_DB:
            events.append(
                _event(
                    "rssi_recover",
                    {
                        "previous_rssi_dbm": prssi,
                        "rssi_dbm": crssi,
                        "delta_db": -delta,
                    },
                    ts=ts,
                )
            )
    return events


# --- Poller state ------------------------------------------------------------
# The desktop app invokes this detector once per scheduler tick (--once),
# so the diff baseline must SURVIVE process exits (audit F3 follow-up: an
# in-memory-only baseline meant every --once call saw a first snapshot and
# no roam/channel/RSSI event could ever fire). Baseline lives in a 0600
# file beside the event store; a missing/corrupt file degrades to "seed on
# first poll" exactly like a fresh long-running process.
STATE_FILENAME = "wifi_baseline.json"
# F7: shared salt file for at-rest SSID/BSSID hashing. Same file the Swift
# side reads (see HistoryStore.swift) so both lanes hash identically.
SALT_FILENAME = "privacy.salt"
_HASH_PREFIX = "nm1:"


def _privacy_salt() -> bytes:
    """Load-or-create the per-install salt (16 random bytes, 0600 file)."""
    path = _state_path().parent / SALT_FILENAME
    try:
        raw = path.read_bytes()
        if len(raw) >= 16:
            return raw[:32]
    except OSError:
        pass
    fresh = os.urandom(32)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as fh:
            fh.write(fresh)
    except OSError:
        return fresh  # unsalted session salt; still no raw IDs at rest
    return fresh


def hash_identifier(value: str | None) -> str | None:
    """F7 minimization: salted SHA-256 of an SSID/BSSID, prefix nm1:.

    Raw SSIDs/BSSIDs never persist anywhere (events, baseline). The UI only
    ever consumes ts/kind/id, so hashing is lossless for every consumer.
    """
    if not value:
        return None
    import hashlib
    digest = hashlib.sha256(_privacy_salt() + b"\x00" + value.encode("utf-8", "replace")).hexdigest()
    return _HASH_PREFIX + digest


def _state_path() -> Path:
    try:
        base = Path.home() / "Library" / "Application Support" / "NetMaxDesktop"
    except RuntimeError:  # no home: temp fallback
        import tempfile
        base = Path(tempfile.gettempdir()) / "netmax-wifievents"
    return base / STATE_FILENAME


def _load_persisted_baseline() -> dict | None:
    try:
        raw = _state_path().read_text(encoding="utf-8")
        data = json.loads(raw)
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


def _persist_baseline(snapshot: dict) -> None:
    path = _state_path()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(snapshot, fh)
    except OSError:
        pass  # baseline persistence is best-effort; in-memory still works


_last_snapshot: dict | None = _load_persisted_baseline()
_state_lock = threading.Lock()
_stop = threading.Event()


def emit_events(events: list[dict]) -> None:
    """Deliver events via E2's store if importable, else stdout JSON lines."""
    if not events:
        return
    if EVENTSTORE_AVAILABLE and append_event is not None:
        for ev in events:
            try:
                append_event(ev)
            except Exception as exc:  # store down: never lose the poller
                print(f"netmax_wifievents: store error: {exc}", file=sys.stderr)
                print(json.dumps(ev), flush=True)
    else:
        for ev in events:
            print(json.dumps(ev), flush=True)


def poll_once(snapshot: dict | None = None) -> list[dict]:
    """Capture (or accept an injected) snapshot, diff against previous, emit.

    `snapshot=` exists for deterministic testing: pass an already-parsed
    snapshot to avoid running system_profiler.
    """
    global _last_snapshot
    snap = snapshot if snapshot is not None else capture_snapshot()
    if snap is None:
        return []  # tool failure: keep previous baseline, try again next cycle
    with _state_lock:
        events = diff_snapshots(_last_snapshot, snap)
        _last_snapshot = snap
        _persist_baseline(snap)
    emit_events(events)
    return events


def reset_baseline(snapshot: dict | None = None) -> None:
    """Seed/clear the previous-snapshot baseline (test + startup helper)."""
    global _last_snapshot
    with _state_lock:
        _last_snapshot = snapshot


def _request_stop(signum: int, frame: Any) -> None:
    _stop.set()


def run_poller(
    interval: int = DEFAULT_INTERVAL_S,
    max_cycles: int | None = None,
    snapshot_fn: Callable[[], dict | None] = capture_snapshot,
) -> int:
    """Poll every `interval` seconds until SIGTERM/SIGINT/max_cycles.

    Returns process exit code (0 = clean stop).
    """
    signal.signal(signal.SIGTERM, _request_stop)
    signal.signal(signal.SIGINT, _request_stop)
    cycles = 0
    while not _stop.is_set():
        poll_once(snapshot=snapshot_fn())
        cycles += 1
        if max_cycles is not None and cycles >= max_cycles:
            break
        if _stop.wait(float(interval)):
            break
    print(
        f"netmax_wifievents: stopped cleanly after {cycles} cycle(s)",
        file=sys.stderr,
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="WiFi event detector (W5-E1)")
    ap.add_argument("-i", "--interval", type=int, default=DEFAULT_INTERVAL_S,
                    help="poll interval seconds (default %(default)s)")
    ap.add_argument("--max-cycles", type=int, default=None,
                    help="stop after N polls (default: until SIGTERM)")
    ap.add_argument("--once", action="store_true",
                    help="single snapshot+diff, then exit")
    args = ap.parse_args(argv)
    if args.interval < 1:
        ap.error("--interval must be >= 1 (0 or negative busy-loops the poller)")

    mode = "eventstore(netmax_eventstore.append_event)" if EVENTSTORE_AVAILABLE \
        else "fallback(stdout JSON lines)"
    print(f"netmax_wifievents: sink={mode}", file=sys.stderr)
    if args.once:
        poll_once()
        return 0
    return run_poller(interval=args.interval, max_cycles=args.max_cycles)


if __name__ == "__main__":
    sys.exit(main())
