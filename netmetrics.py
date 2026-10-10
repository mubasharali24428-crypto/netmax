"""Network metrics: packet loss, jitter, Wi-Fi info (macOS).

Implements M2/N1 per docs/FEATURE-SPECS.md '## Research Findings'.
All functions are offline-testable: they shell out via subprocess and parse
stdout only — never exit codes alone. Failures raise netmax.NetMaxError.
"""

from __future__ import annotations

import json
import re
import statistics
import subprocess
import time

from netmax import NetMaxError
from netmax_platform import (
    PLATFORM,
    parse_netsh_wlan,
    parse_ping_loss,
    parse_ping_times,
    ping_cmd,
    ping_timeout_s,
    wifi_cmd,
)


def _run(cmd: list[str], timeout: float) -> subprocess.CompletedProcess:
    """Run a command, converting spawn/timeout failures into NetMaxError."""
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (subprocess.TimeoutExpired, OSError) as exc:
        raise NetMaxError(f"{cmd[0]} failed to run: {exc}") from exc


def packet_loss(host: str = "1.1.1.1", count: int = 10, interval: float = 0.3) -> float:
    """Packet-loss percent [0.0..100.0] parsed from ping's stdout summary line.

    Ping exits non-zero when the host blocks ICMP but still prints a
    statistics block with 100.0% loss — we parse stdout, not the exit code.
    On Windows the flags and output format differ; netmax_platform handles it.
    """
    proc = _run(ping_cmd(host, count, interval),
                timeout=ping_timeout_s(count, interval))
    try:
        return parse_ping_loss(proc.stdout, host)
    except NetMaxError:
        raise NetMaxError(
            f"ping to {host} produced no loss statistics: "
            f"{proc.stderr.strip()[:120] or 'no output'}"
        ) from None


def jitter_ms(host: str = "1.1.1.1", count: int = 10, interval: float = 0.3) -> float:
    """Mean absolute delta between consecutive RTTs (ms), RFC 3550 style.

    Parses every `time=X ms` reply line; skips `time<0.1 ms` lines (localhost),
    which break the float regex. Windows `time<1ms` lines are likewise
    skipped — never fabricated.
    """
    proc = _run(ping_cmd(host, count, interval),
                timeout=ping_timeout_s(count, interval))
    times = parse_ping_times(proc.stdout)
    if len(times) < 2:
        raise NetMaxError(
            f"insufficient RTT samples from ping to {host} "
            f"({len(times)} replies): {proc.stderr.strip()[:120]}"
        )
    deltas = [abs(b - a) for a, b in zip(times, times[1:])]
    return statistics.fmean(deltas)


# Wi-Fi scan cache: system_profiler takes seconds per spawn and the radio
# barely moves within 10 s — serve repeats from memory.
WIFI_CACHE_TTL_S = 10.0
_WIFI_CACHE: dict = {"at": float("-inf"), "info": None}


def _reset_wifi_cache() -> None:
    _WIFI_CACHE["at"] = float("-inf")
    _WIFI_CACHE["info"] = None


def wifi_info(iface_hint: str | None = None) -> dict:
    """Current Wi-Fi network info: {'rssi_dbm', 'noise_dbm', 'channel', ...}.

    Uses `system_profiler SPAirPortDataType` (the airport binary was removed
    in modern macOS). Prefers -json; falls back to plain-text regexes.
    On Windows uses `netsh wlan show interfaces` (signal % → estimated dBm,
    flagged). On Linux raises NetMaxError honestly (no universal CLI).
    """
    del iface_hint  # reserved; system_profiler reports all interfaces
    if PLATFORM == "windows":
        return _wifi_info_windows()
    now = time.monotonic()
    if _WIFI_CACHE["info"] is not None and now - _WIFI_CACHE["at"] < WIFI_CACHE_TTL_S:
        return dict(_WIFI_CACHE["info"])
    info = _wifi_info_uncached()
    _WIFI_CACHE["at"] = now
    _WIFI_CACHE["info"] = info
    return dict(info)


def _wifi_info_windows() -> dict:
    """Windows Wi-Fi info via netsh. netsh is fast; no cache needed."""
    proc = _run(wifi_cmd(), timeout=30)
    if proc.returncode != 0:
        raise NetMaxError(
            f"netsh wlan failed: {proc.stderr.strip()[:120]}"
        )
    return parse_netsh_wlan(proc.stdout)


def _wifi_info_uncached() -> dict:
    proc = _run(["system_profiler", "SPAirPortDataType", "-json"], timeout=30)
    if proc.returncode != 0:
        raise NetMaxError(
            f"system_profiler failed: {proc.stderr.strip()[:120]}"
        )
    try:
        data = json.loads(proc.stdout)
        items = (
            (data.get("SPAirPortDataType") or [{}])[0]
            .get("spairport_current_network_information")
            or []
        )
        v = next(iter(items.values())) if isinstance(items, dict) else (items[0] if items else {})
        sig = str(v.get("spairport_signal_or_noise", ""))
        chan = str(v.get("spairport_current_channel", ""))
        m = re.match(r"\s*(-?\d+)\s*dBm\s*/\s*(-?\d+)\s*dBm", sig)
        cm = re.match(r"(\d+)\s*\((\w+GHz)", chan)
        result = {
            "rssi_dbm": int(m.group(1)) if m else None,
            "noise_dbm": int(m.group(2)) if m else None,
            "channel": cm.group(1) if cm else chan or None,
        }
    except (ValueError, AttributeError, IndexError, TypeError):
        result = {"rssi_dbm": None, "noise_dbm": None, "channel": None}
    if any(result[k] is None for k in ("rssi_dbm", "noise_dbm", "channel")):
        # JSON keys unverified on this OS / no association — fall back to the
        # live-verified plain-text format.
        txt = _run(["system_profiler", "SPAirPortDataType"], timeout=30).stdout
        sm = re.search(r"Signal / Noise:\s*(-?\d+)\s*dBm\s*/\s*(-?\d+)\s*dBm", txt)
        chm = re.search(r"Channel:\s*(\d+)\s*\((\w+GHz)", txt)
        result = {
            "rssi_dbm": int(sm.group(1)) if sm else result["rssi_dbm"],
            "noise_dbm": int(sm.group(2)) if sm else result["noise_dbm"],
            "channel": chm.group(1) if chm else result["channel"],
        }
    if result["rssi_dbm"] is None:
        raise NetMaxError("no Wi-Fi network associated (Wi-Fi off or Ethernet)")
    return result
