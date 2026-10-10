"""Unit tests for netmax_platform (no network, no subprocess)."""
import sys
sys.path.insert(0, ".")

import netmax_platform as plat
from netmax import NetMaxError

passed = failed = 0
def check(name, cond):
    global passed, failed
    if cond: passed += 1; print(f"  PASS {name}")
    else: failed += 1; print(f"  FAIL {name}")

# Real Windows ping output (lossy host)
WIN_LOSSY = """Pinging 8.8.8.8 with 32 bytes of data:
Reply from 8.8.8.8: bytes=32 time=12ms TTL=117
Reply from 8.8.8.8: bytes=32 time=14ms TTL=117
Request timed out.
Reply from 8.8.8.8: bytes=32 time=11ms TTL=117

Ping statistics for 8.8.8.8:
    Packets: Sent = 4, Received = 3, Lost = 1 (25% loss),
Approximate round trip times in milli-seconds:
    Minimum = 11ms, Maximum = 14ms, Average = 12ms
"""
# Real Windows ping output (dead host)
WIN_DEAD = """Pinging 192.0.2.1 with 32 bytes of data:
Request timed out.
Request timed out.

Ping statistics for 192.0.2.1:
    Packets: Sent = 2, Received = 0, Lost = 2 (100% loss),
"""
# Unix ping output (macOS/Linux)
UNIX_OK = """PING 1.1.1.1 (1.1.1.1): 56 data bytes
64 bytes from 1.1.1.1: icmp_seq=0 ttl=57 time=11.234 ms
64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=12.102 ms

--- 1.1.1.1 ping statistics ---
2 packets transmitted, 2 packets received, 0.0% packet loss
round-trip min/avg/max/stddev = 11.234/11.668/12.102/0.434 ms
"""
# Real netsh wlan show interfaces output
NETSH = """There is 1 interface on the system:

    Name                   : Wi-Fi
    Description            : Intel(R) Wi-Fi 6E AX211 160MHz
    GUID                   : 12345678-1234-1234-1234-123456789012
    Physical address       : aa:bb:cc:dd:ee:ff
    State                  : connected
    SSID                   : HomeNet
    BSSID                  : 11:22:33:44:55:66
    Network type           : Infrastructure
    Radio type             : 802.11ax
    Authentication         : WPA2-Personal
    Cipher                 : CCMP
    Connection mode        : Auto Connect
    Channel                : 36
    Receive rate (Mbps)    : 1200
    Transmit rate (Mbps)   : 1200
    Signal                 : 82%
    Profile                : HomeNet
"""
NETSH_DISCONNECTED = """
    Name                   : Wi-Fi
    State                  : disconnected
"""

print("== parse_ping_loss ==")
check("windows 25% loss", plat.parse_ping_loss(WIN_LOSSY) == 25.0)
check("windows 100% loss", plat.parse_ping_loss(WIN_DEAD) == 100.0)
check("unix 0.0% loss", plat.parse_ping_loss(UNIX_OK) == 0.0)
try:
    plat.parse_ping_loss("garbage output")
    check("garbage raises", False)
except NetMaxError:
    check("garbage raises", True)

print("== parse_ping_times ==")
check("windows times [12,14,11]", plat.parse_ping_times(WIN_LOSSY) == [12.0, 14.0, 11.0])
check("windows dead -> []", plat.parse_ping_times(WIN_DEAD) == [])
check("unix times parsed", plat.parse_ping_times(UNIX_OK) == [11.234, 12.102])

print("== parse_netsh_wlan ==")
w = plat.parse_netsh_wlan(NETSH)
check("ssid", w["ssid"] == "HomeNet")
check("signal_pct 82", w["signal_pct"] == 82)
check("rssi estimated -59", w["rssi_dbm"] == -59 and w["rssi_estimated"] is True)
check("channel 36", w["channel"] == "36")
check("radio", w["radio"] == "802.11ax")
check("noise None (honest)", w["noise_dbm"] is None)
try:
    plat.parse_netsh_wlan(NETSH_DISCONNECTED)
    check("disconnected raises", False)
except NetMaxError:
    check("disconnected raises", True)

print("== ping_cmd ==")
check("current platform cmd sane", isinstance(plat.ping_cmd("1.1.1.1", 3), list))
try:
    plat.ping_cmd("1.1.1.1", 0)
    check("count=0 raises", False)
except NetMaxError:
    check("count=0 raises", True)

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
