"""Offline tests for netmax_netcontext.get_context() (W13B UA-1).

The conftest tripwires subprocess.run, so every test feeds canned ifconfig /
netstat stdout through a monkeypatched subprocess.run and asserts on the parsed
verdict — same style as tests/test_netmetrics.py.
"""

import subprocess

import pytest

from netmax import NetMaxError

import netmax_netcontext as nc


LO = """\
lo0: flags=8049<UP,LOOPBACK,RUNNING> mtu 16384
\tinet 127.0.0.1 netmask 0xff000000
\tinet6 ::1 prefixlen 128
\tstatus: active
"""

EN0_UP = """\
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
\tinet 192.168.1.23 netmask 0xffffff00 broadcast 192.168.1.255
\tstatus: active
"""

UTUN_IDLE = """\
utun3: flags=8051<UP,POINTOPOINT,RUNNING> mtu 1380
\tstatus: inactive
"""

UTUN_ACTIVE = """\
utun5: flags=8051<UP,POINTOPOINT,RUNNING> mtu 1380
\tinet 10.8.0.2 --> 10.8.0.1 netmask 0xffffffff
\tstatus: active
"""


def install(monkeypatch, calls, if_out: str, route_ifaces: list[str]) -> None:
    """Patch subprocess.run with canned ifconfig/netstat output."""
    routes = "\n".join(
        f"default 10.8.0.{i + 1} UGSc {i} {i} {name}"
        for i, name in enumerate(route_ifaces)
    ) + ("\n" if route_ifaces else "")

    def fake(cmd, timeout=0, **kw):
        calls.append(list(cmd))
        out = if_out if "ifconfig" in cmd[0] else routes
        return subprocess.CompletedProcess(cmd, 0, stdout=out, stderr="")

    monkeypatch.setattr(subprocess, "run", fake)


def test_online_no_vpn(monkeypatch):
    calls: list[list[str]] = []
    install(monkeypatch, calls, LO + EN0_UP + UTUN_IDLE, [])
    assert nc.get_context() == {"online": True, "vpn": False}
    # Proved the probes ran: one ifconfig + one netstat invocation.
    assert any("ifconfig" in c[0] for c in calls)
    assert any("netstat" in c[0] for c in calls)


def test_offline_when_only_loopback(monkeypatch):
    install(monkeypatch, [], LO + UTUN_IDLE, [])
    assert nc.get_context() == {"online": False, "vpn": False}


def test_vpn_requires_active_status_and_route(monkeypatch):
    # Active utun carrying a route ⇒ VPN.
    install(monkeypatch, [], LO + EN0_UP + UTUN_ACTIVE, ["utun5"])
    assert nc.get_context() == {"online": True, "vpn": True}

    # Same active utun but no route through it (idle macOS utun) ⇒ not VPN.
    install(monkeypatch, [], LO + EN0_UP + UTUN_ACTIVE, ["en0"])
    assert nc.get_context() == {"online": True, "vpn": False}

    # Route present but interface reports status: inactive ⇒ still not VPN.
    install(monkeypatch, [], LO + EN0_UP + UTUN_IDLE, ["utun3"])
    assert nc.get_context() == {"online": True, "vpn": False}


def test_vpn_only_connectivity_is_online_and_vpn(monkeypatch):
    # Tunnel up while the LAN is down: the utun itself is a non-loopback
    # interface with an address ⇒ online=True, and vpn=True alongside.
    install(monkeypatch, [], LO + UTUN_ACTIVE, ["utun5"])
    assert nc.get_context() == {"online": True, "vpn": True}


def test_addressed_utun_without_route_still_not_vpn(monkeypatch):
    # Address on a tunnel-class iface but no route through it ⇒ not VPN,
    # though its address alone keeps the host "online" per the lane spec.
    install(monkeypatch, [], LO + UTUN_ACTIVE, ["en0"])
    assert nc.get_context() == {"online": True, "vpn": False}


def test_link_status_alone_counts_as_online(monkeypatch):
    up_no_address = EN0_UP.splitlines()[0] + "\n\tstatus: active\n"
    install(monkeypatch, [], LO + up_no_address, [])
    assert nc.get_context()["online"] is True


def test_missing_binary_raises_netmax_error(monkeypatch):
    def boom(cmd, timeout=0, **kw):
        raise OSError("ifconfig missing")

    monkeypatch.setattr(subprocess, "run", boom)
    with pytest.raises(NetMaxError):
        nc.get_context()
