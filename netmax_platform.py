"""netmax_platform: per-OS probe command tables and output parsers.

The probe layer (netmetrics) shells out to system utilities whose flags and
output formats differ per OS. This module centralizes every platform
difference so probes stay honest on macOS, Linux, and Windows.

Design rules (match the engine's honesty contract):
- Every parser either returns a genuine measurement or raises NetMaxError.
- Estimated/derived values are flagged (e.g. ``rssi_estimated: True``),
  never silently passed off as measured.
- Only stdlib. No side effects at import.

Platform coverage:
- ping: macOS + Linux (``ping -c/-i``) and Windows (``ping -n/-w``).
- Wi-Fi: macOS (``system_profiler``), Windows (``netsh wlan show interfaces``).
  Linux has no universal Wi-Fi CLI — raises NetMaxError honestly.
"""

from __future__ import annotations

import re
import sys

from netmax import NetMaxError


def detect() -> str:
    """'macos', 'windows', or 'linux' (other Unix -> 'linux' path)."""
    p = sys.platform
    if p == "darwin":
        return "macos"
    if p.startswith("win"):
        return "windows"
    return "linux"


PLATFORM = detect()


# ── ping ─────────────────────────────────────────────────────────────────────

def ping_cmd(host: str, count: int, interval_s: float = 0.3) -> list[str]:
    """Per-OS ping argv. Windows has no interval flag (sends 1/sec)."""
    if count < 1:
        raise NetMaxError(f"ping count must be >= 1, got {count}")
    if PLATFORM == "windows":
        # -n count, -w per-reply timeout in ms.
        return ["ping", "-n", str(count), "-w", "1000", host]
    if PLATFORM == "macos":
        # macOS ping -i accepts fractional seconds for unprivileged users.
        return ["ping", "-c", str(count), "-i", str(interval_s), host]
    return ["ping", "-c", str(count), "-i", str(interval_s), host]


def ping_timeout_s(count: int, interval_s: float = 0.3) -> float:
    """Generous subprocess timeout for the ping command just built."""
    if PLATFORM == "windows":
        return count * 2.0 + 15.0  # 1/sec spacing + per-reply timeout
    return count * interval_s + 15.0


_LOSS_UNIX_RE = re.compile(r"(\d+(?:\.\d+)?)% packet loss")
_LOSS_WIN_RE = re.compile(r"Lost = \d+ \((\d+)% loss\)")


def parse_ping_loss(stdout: str, host: str = "") -> float:
    """Packet-loss percent [0.0..100.0] from ping stdout, any platform."""
    m = _LOSS_UNIX_RE.search(stdout) or _LOSS_WIN_RE.search(stdout)
    if not m:
        raise NetMaxError(
            f"ping to {host} produced no loss statistics: "
            f"{stdout.strip()[-120:] or 'no output'}"
        )
    return float(m.group(1))


# Unix: "time=12.3 ms". Windows: "time=12ms" or "time<1ms" (sub-ms, skipped —
# same policy as the engine's existing localhost handling: never fabricate).
_TIME_RE = re.compile(r"time=(\d+(?:\.\d+)?)\s*ms")


def parse_ping_times(stdout: str) -> list[float]:
    """All RTT samples in ms from ping stdout, any platform."""
    return [float(t) for t in _TIME_RE.findall(stdout)]


# ── Wi-Fi ────────────────────────────────────────────────────────────────────

def wifi_cmd() -> list[str]:
    """Per-OS Wi-Fi info command. Raises NetMaxError where unsupported."""
    if PLATFORM == "macos":
        return ["system_profiler", "SPAirPortDataType", "-json"]
    if PLATFORM == "windows":
        return ["netsh", "wlan", "show", "interfaces"]
    raise NetMaxError(
        "Wi-Fi info has no universal CLI on Linux "
        "(try `iw dev` or `nmcli` manually)"
    )


_NETSH_KV_RE = re.compile(r"^\s{4}(\w[\w ]*?)\s*:\s*(.+?)\s*$")


def parse_netsh_wlan(stdout: str) -> dict:
    """Parse `netsh wlan show interfaces` into the wifi_info contract.

    Windows reports signal as a percentage, not dBm. rssi_dbm is a
    rough conversion ((pct/2) - 100) and is flagged estimated — the
    percentage itself is the honest measurement.
    """
    fields: dict[str, str] = {}
    for line in stdout.splitlines():
        m = _NETSH_KV_RE.match(line)
        if m:
            fields[m.group(1).strip().lower()] = m.group(2).strip()
    if fields.get("state", "").lower() != "connected":
        raise NetMaxError("no Wi-Fi network associated (Wi-Fi off or Ethernet)")
    ssid = fields.get("ssid")
    pct_m = re.search(r"(\d+)\s*%", fields.get("signal", ""))
    chan_m = re.search(r"(\d+)", fields.get("channel", ""))
    if ssid is None or not pct_m:
        raise NetMaxError("netsh wlan output unparseable: no SSID/signal")
    pct = int(pct_m.group(1))
    return {
        "rssi_dbm": int(pct / 2 - 100),
        "rssi_estimated": True,
        "signal_pct": pct,
        "noise_dbm": None,
        "channel": chan_m.group(1) if chan_m else None,
        "ssid": ssid,
        "radio": fields.get("radio type"),
    }


# ── interfaces (phase 2; documented for the next adapter slice) ──────────────

def iface_cmd() -> list[str]:
    """Per-OS interface listing command."""
    if PLATFORM == "windows":
        return ["ipconfig", "/all"]
    return ["ifconfig", "-a"]
