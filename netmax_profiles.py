#!/usr/bin/env python3
"""Network-aware run profiles and context resolution (P3 items 46 + 43).

A single measurement profile is wrong for every network. A 5 GHz link at
-45 dBm and a coffee-shop 2.4 GHz AP at -75 dBm have different honest
answers to "how many streams?", and the difference is not opinion — it is
signal, band and channel.

This module turns a measured snapshot plus the current context into the
settings a run should use. It resolves, it never configures: no `sudo`, no
`networksetup`, no interface mutation. The caller applies what it wants.

Privacy: SSIDs are never stored or compared in the clear. Profiles are keyed
on the same salted hash `netmax_wifievents` emits (the F7 minimisation), so
the raw network name exists only in the frame that configures a profile —
exactly the property that module already guarantees for its own events.

Composition (item 43): the resolved settings are the intersection of three
independent inputs — the network profile, the power policy from
netmax_schedule, and whatever context the caller supplies (a call in
progress, a deadline). Each may only make a run *gentler*, never bolder:
that direction is a deliberate safety property, so a mis-detected context
can cost accuracy but cannot cause a saturating run nobody asked for.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from netmax_schedule import PowerPolicy, apply_policy
from netmax_wifievents import hash_identifier

# Signal thresholds in dBm. Chosen from the usual WiFi engineering bands:
# -67 is where throughput starts degrading meaningfully, -75 is where a
# client is effectively one wall away.
RSSI_GOOD_DBM = -55
RSSI_FAIR_DBM = -67
RSSI_POOR_DBM = -75


@dataclass
class RunProfile:
    """Settings a run should use on a given kind of network."""
    name: str
    streams: int
    seconds: int
    #: Aggregate cap in Mbps; None means "measure the line honestly".
    cap_mbps: float | None = None
    #: Skip the saturating bufferbloat grade and use the ~100 KB estimate.
    bloat_eco_only: bool = False
    rationale: str = ""
    source: str = "local"

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name, "streams": self.streams,
            "seconds": self.seconds, "cap_mbps": self.cap_mbps,
            "bloat_eco_only": self.bloat_eco_only,
            "rationale": self.rationale, "source": self.source,
        }


# The profiles we can infer from a measurement alone. A named profile the
# user configures overrides these by SSID hash.
BUILTIN_PROFILES: dict[str, RunProfile] = {
    "strong": RunProfile(
        name="strong", streams=8, seconds=10, cap_mbps=None,
        bloat_eco_only=False,
        rationale="clean high-bandwidth link — measure it properly"),
    "fair": RunProfile(
        name="fair", streams=4, seconds=10, cap_mbps=None,
        bloat_eco_only=False,
        rationale="usable link — fewer streams, still a real measurement"),
    "poor": RunProfile(
        name="poor", streams=1, seconds=15, cap_mbps=None,
        bloat_eco_only=True,
        rationale="weak or congested link — single stream and the eco "
                  "bufferbloat estimate, because a saturating grade on a "
                  "bad link measures the radio, not the ISP"),
    "wired": RunProfile(
        name="wired", streams=8, seconds=10, cap_mbps=None,
        bloat_eco_only=False,
        rationale="Ethernet — no wireless hop to characterise"),
    "unknown": RunProfile(
        name="unknown", streams=4, seconds=10, cap_mbps=None,
        bloat_eco_only=True,
        rationale="no usable snapshot — conservative settings"),
}


def classify_snapshot(snapshot: dict[str, Any] | None) -> str:
    """Pick a builtin profile key from a measured snapshot.

    Order matters: a wired machine outranks any wireless reading, and a
    5 GHz link with mediocre signal outranks a 2.4 GHz link with the same
    signal.
    """
    if not snapshot or not snapshot.get("associated"):
        return "unknown"

    # An Ethernet interface reports no SSID/channel at all.
    if not snapshot.get("ssid") and snapshot.get("channel") is None:
        return "wired"

    rssi = snapshot.get("rssi_dbm")
    channel = snapshot.get("channel")
    band = (str(snapshot.get("band") or "")).lower()
    if rssi is None:
        return "unknown"

    if rssi >= RSSI_GOOD_DBM and "2.4" not in channel_text(channel, band):
        return "strong"
    if rssi >= RSSI_FAIR_DBM and "2.4" not in channel_text(channel, band):
        return "fair"
    return "poor"


def channel_text(channel: Any, band: str) -> str:
    """Best-effort 'is this 2.4 GHz' test.

    Channels 1-14 are the 2.4 GHz band. `band` from the profiler is a
    secondary signal because some snapshots carry a band label without a
    usable channel number.
    """
    text = str(channel or "")
    if "2.4" in band:
        return "2.4"
    match = re.match(r"^\s*(\d+)", text)
    if match:
        try:
            return "2.4" if 1 <= int(match.group(1)) <= 14 else "5"
        except ValueError:
            pass
    if "5" in band:
        return "5"
    return text or band


# ── named profiles, keyed by SSID hash (F7: raw SSIDs never persist) ──────────


@dataclass
class ProfileStore:
    """User-configured per-network overrides, keyed by SSID hash."""
    by_hash: dict[str, RunProfile] = field(default_factory=dict)
    #: Where they came from, so a caller can report "no profile configured".
    path: str | None = None

    @staticmethod
    def key_for(ssid: str) -> str | None:
        """Hash an SSID the same way the detector does.

        This is the ONLY place a raw SSID is accepted, and it is hashed
        immediately — the plaintext never leaves this call.
        """
        return hash_identifier(ssid)

    def set_for_ssid(self, ssid: str, profile: RunProfile) -> str | None:
        key = self.key_for(ssid)
        if key is None:
            return None
        self.by_hash[key] = profile
        return key

    def get(self, snapshot: dict[str, Any] | None) -> RunProfile | None:
        if not snapshot:
            return None
        key = snapshot.get("ssid")
        if not key:
            return None
        return self.by_hash.get(key)

    def save(self, path: str) -> None:
        file = Path(path).expanduser()
        file.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "version": 1,
            # Hashes only. There is deliberately no plaintext SSID field.
            "profiles": {k: v.to_dict() for k, v in self.by_hash.items()},
        }
        file.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        self.path = str(file)

    @classmethod
    def load(cls, path: str) -> "ProfileStore":
        store = cls(path=path)
        file = Path(path).expanduser()
        if not file.exists():
            return store
        try:
            payload = json.loads(file.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            return store
        for key, row in (payload.get("profiles") or {}).items():
            if not isinstance(row, dict):
                continue
            store.by_hash[key] = RunProfile(
                name=str(row.get("name", "custom")),
                streams=_clamp(row.get("streams", 4), 1, 50),
                seconds=_clamp(row.get("seconds", 10), 5, 3600),
                cap_mbps=row.get("cap_mbps"),
                bloat_eco_only=bool(row.get("bloat_eco_only", False)),
                rationale=str(row.get("rationale", "configured profile")),
                source="configured",
            )
        return store


def _clamp(value: Any, low: int, high: int, fallback: int | None = None) -> int:
    """Coerce to an int inside [low, high], or `fallback` when impossible.

    `fallback` defaults to `low` so a corrupt stored value can never produce
    an out-of-range or zero setting.
    """
    if fallback is None:
        fallback = low
    try:
        return max(low, min(high, int(value)))
    except (TypeError, ValueError):
        return fallback


# ── context (item 43) ────────────────────────────────────────────────────────


@dataclass
class RunContext:
    """What the caller knows about the situation right now.

    Deliberately plain data: the macOS sources that would populate this
    (Calendar, meeting state) need TCC permissions and belong to whoever
    owns the UI layer. The policy below is complete without them.
    """
    #: An interactive session is live — calls, meetings, gaming.
    interactive: bool = False
    #: The user has a deadline this run must not blow.
    time_sensitive: bool = False
    #: Seconds the user is willing to spend on this run.
    budget_seconds: float | None = None
    #: True when the caller knows a real context source, not a default.
    context_known: bool = False


def resolve_settings(
    snapshot: dict[str, Any] | None,
    *,
    policy: PowerPolicy | None = None,
    context: RunContext | None = None,
    store: ProfileStore | None = None,
) -> dict[str, Any]:
    """Resolve one run's settings from network + power + context.

    Each input may only make the run gentler. A configured profile can
    lower the cap or the stream count but never raise them above what the
    measured link supports, and context can only reduce further.
    """
    ctx = context or RunContext()

    configured = store.get(snapshot) if store else None
    base = configured or BUILTIN_PROFILES.get(
        classify_snapshot(snapshot), BUILTIN_PROFILES["unknown"])
    profile_source = "configured" if configured else "inferred"

    streams = base.streams
    seconds = base.seconds
    cap = base.cap_mbps
    bloat_eco = base.bloat_eco_only
    notes = [base.rationale]
    if profile_source == "inferred":
        notes.append(
            "no profile configured for this network — settings inferred "
            "from signal and band"
        )

    # 1. Network quality already handled above. A configured profile may
    #    only ever tighten, so re-apply the inferred ceiling as a cap on
    #    whatever the profile asked for.
    inferred_key = classify_snapshot(snapshot)
    inferred = BUILTIN_PROFILES.get(inferred_key, BUILTIN_PROFILES["unknown"])
    if configured:
        if inferred.streams < streams:
            notes.append(
                f"configured profile asked for {streams} streams but the "
                f"measured link supports {inferred.streams}")
            streams = inferred.streams
        if inferred.bloat_eco_only:
            bloat_eco = True

    # 2. Interactive traffic outranks throughput.
    if ctx.interactive:
        if streams > 2:
            notes.append(
                f"interactive session detected — reducing {streams} streams "
                "to 2 so per-flow latency stays low")
            streams = 2
        if cap is None:
            notes.append(
                "interactive session — holding the line at 80% of whatever "
                "the link delivers, rather than saturating it")
            cap = None      # measured later; recorded as a constraint below

    # 3. Power.
    if policy is not None:
        resolved = apply_policy(policy, seconds=seconds, interval_s=30)
        if resolved["skipped_mode"]:
            bloat_eco = True
        seconds = resolved["seconds"]
        if not resolved["run"] and not ctx.time_sensitive:
            return {
                "run": False, "profile": base.name,
                "profile_source": profile_source,
                "streams": streams, "seconds": seconds, "cap_mbps": cap,
                "bloat_eco_only": bloat_eco, "notes": notes,
                "reason": policy.reason, "source": "local",
            }
        if policy.duration_scale < 1.0:
            notes.append(policy.reason)

    # 4. An explicit budget beats everything else.
    if ctx.budget_seconds is not None:
        budget = int(max(5, min(3600, ctx.budget_seconds)))
        if budget < seconds:
            notes.append(
                f"budget of {budget}s is shorter than the profile's {seconds}s "
                "— using the budget")
            seconds = budget

    return {
        "run": True,
        "profile": base.name,
        "profile_source": profile_source,
        "streams": streams,
        "seconds": seconds,
        "cap_mbps": cap,
        "bloat_eco_only": bloat_eco,
        # Interactive sessions must leave headroom for the call itself.
        "reserve_for_interactive": bool(ctx.interactive),
        "notes": notes,
        "reason": "; ".join(notes),
        "source": "local",
    }