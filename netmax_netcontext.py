"""Network context probe (W13B UA-1): VPN / offline detection.

Implements S-048 (offline detection) and the detection half of S-049
(VPN notice) for mission W13B TEAM-ULTIMATE-A "Honest Context".

House style (netmetrics.py): everything is offline-testable — we shell out via
subprocess, parse stdout only, never exit codes alone, and raise NetMaxError
when a probe cannot run. The offline suite's conftest tripwires subprocess.run,
so every test must monkeypatch it with canned output.

Detection rules:

- **VPN**: an interface named like a tunnel/IPsec transport (`utun*`, `ipsec*`,
  `ppp*`) that carries traffic — i.e. `netstat -rn` lists at least one active
  route through it. A utun that exists but routes nothing (macOS keeps several
  idle ones around for Back to My Mac / Handoff) must NOT read as VPN.
- **Offline**: no non-loopback interface has an IPv4/IPv6 address or reports
  link status "active". Loopback never counts as connectivity.
- Both probes are independent: VPN without general connectivity is reported as
  vpn=True, online=False (a walled garden is not "online").
"""

from __future__ import annotations

import re

from netmax import NetMaxError

__all__ = ["get_context"]


def _run(cmd: list[str], timeout: float):
    """Run a command, converting spawn/timeout failures into NetMaxError."""
    import subprocess

    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (subprocess.TimeoutExpired, OSError) as exc:
        raise NetMaxError(f"{cmd[0]} failed to run: {exc}") from exc


# Interface-name prefixes that indicate a tunnel / IPsec transport.
_TUNNEL_RE = re.compile(r"^(utun|ipsec|ppp|tun|tap)[0-9]")

# `ifconfig <name>`: status line, e.g. "status: active" / "status: inactive".
_STATUS_RE = re.compile(r"^\s*status:\s*(\S+)", re.MULTILINE)

# IPv4 (inet x.x.x.x) or IPv6 (inet6 xxxx::…) address lines.
_INET_RE = re.compile(r"\b(inet6?)\s+([0-9a-fA-F:.]+)")


def _parse_ifconfig(text: str) -> dict:
    """Split `ifconfig -a` stdout into {iface_name: {"inet": [...], "status": str}}."""
    interfaces: dict[str, dict] = {}
    current = None
    for line in text.splitlines():
        if line and not line[0].isspace() and ":" in line:
            name = line.split(":", 1)[0].strip()
            if name:
                current = name
                interfaces.setdefault(current, {"inet": [], "status": ""})
            continue
        if current is None:
            continue
        entry = interfaces[current]
        m = _INET_RE.search(line)
        # Loopback 127.0.0.1/::1 proves nothing about real connectivity.
        if m and m.group(2) not in ("127.0.0.1", "::1"):
            entry["inet"].append(m.group(2))
        sm = _STATUS_RE.search(line)
        if sm:
            entry["status"] = sm.group(1)
    return interfaces


def _parse_routes(text: str) -> set:
    """Set of interfaces that carry at least one route in `netstat -rn` output."""
    routed: set[str] = set()
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 4:
            # Route table rows end with the outgoing interface name.
            routed.add(parts[-1])
    return routed


def _active_tunnel_interfaces(interfaces: dict) -> set:
    """Tunnel-class interfaces that are both link-active AND carry routes."""
    routed = _parse_routes(_run(["/usr/sbin/netstat", "-rn"], timeout=10).stdout)
    active = {
        name
        for name, entry in interfaces.items()
        if _TUNNEL_RE.match(name)
        and entry["status"] == "active"
        and name in routed
    }
    return active


def _has_connectivity(interfaces: dict) -> bool:
    """True when some non-loopback interface has an address or is up."""
    for name, entry in interfaces.items():
        if name == "lo0":
            continue
        if entry["inet"] or entry["status"] == "active":
            return True
    return False


def get_context() -> dict:
    """Detect active VPN and offline state from local interface state.

    Returns ``{"online": bool, "vpn": bool}``:

    - ``vpn``: a tunnel-class interface (utun/ipsec/ppp/tun/tap) carries at
      least one route AND reports status "active".
    - ``online``: some non-loopback interface has an address or is up.
    - VPN-only connectivity stays honest: ``{"online": False, "vpn": True}``.
    """
    try:
        ifc = _run(["/sbin/ifconfig", "-a"], timeout=10)
    except NetMaxError:
        # Some systems keep ifconfig outside /sbin; retry via PATH.
        ifc = _run(["ifconfig", "-a"], timeout=10)
    interfaces = _parse_ifconfig(ifc.stdout)
    return {
        "online": _has_connectivity(interfaces),
        "vpn": bool(_active_tunnel_interfaces(interfaces)),
    }


def main() -> int:
    ctx = get_context()
    print(f"online={ctx['online']} vpn={ctx['vpn']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
