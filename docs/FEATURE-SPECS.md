# NetMax — Planned Feature Specs

## Research Findings

Scout-lane research for four new measurements on macOS using only Python
stdlib (`subprocess`, `re`, `statistics`) + `curl`. Every shell command and
HTTP endpoint below was **executed live on this machine** (macOS 26.7) before
being written here; anything that could not be confirmed is marked UNVERIFIED.

---

### 1. Packet loss % via `ping`

- Source practice: standard `ping -c N` summary line; see ping(8)
  (`man ping`) and RFC 3529-style loss accounting — the "packet loss" field of
  the statistics block.

Command:
```bash
ping -c 10 -i 0.3 <host>        # e.g. 1.1.1.1 ; -i below 0.25 may need root
```
Verified output shape (live run against 1.1.1.1):
```
--- 1.1.1.1 ping statistics ---
5 packets transmitted, 5 packets received, 0.0% packet loss
round-trip min/avg/max/stddev = 140.451/146.936/155.825/5.585 ms
```

Implementation:
```python
import re, subprocess

def packet_loss(host: str = "1.1.1.1", count: int = 10,
                interval: float = 0.3) -> float | None:
    """Return packet-loss percent [0.0..100.0] or None if unmeasurable."""
    p = subprocess.run(
        ["ping", "-c", str(count), "-i", str(interval), host],
        capture_output=True, text=True, timeout=count * interval + 15)
    m = re.search(r"(\d+(?:\.\d+)?)% packet loss", p.stdout)
    return float(m.group(1)) if m else None
```

Parsing regexes (verified against live output):
- loss: `r"(\d+(?:\.\d+)?)% packet loss"`
- stddev (free jitter estimate): `r"min/avg/max/stddev = [\d.]+/[\d.]+/[\d.]+/([\d.]+)"`

Failure modes:
- Host blocks ICMP (e.g. some CDNs): exit code non-zero but stdout still has a
  statistics block with 100.0% loss — parse stdout, not exit code.
- `-i` < 0.25s requires root on macOS ("cannot flood; minimal interval allowed
  for user is 500ms") → keep default ≥ 0.3 or run without `-i` (~1s).
- DNS resolution failure → stderr "unknown host"; return None.
- Timeout guard mandatory: ping can hang past `-c` deadline on blackholes.

### 2. Jitter from ping RTT deltas

Jitter here = mean absolute delta between consecutive RTTs (RFC 3550 style,
without its exponential smoothing). Parse every per-reply line:

Regex (verified): `r"time=(\d+(?:\.\d+)?)(?:\s*ms)?$"` applied to lines
matching `64 bytes from ... icmp_seq=N ... time=147.817 ms`.

Implementation:
```python
def jitter_ms(ping_output: str) -> float | None:
    times = [float(t) for t in re.findall(r"time=(\d+(?:\.\d+)?)\s*ms",
                                          ping_output)]
    if len(times) < 2:
        return None
    deltas = [abs(b - a) for a, b in zip(times, times[1:])]
    return sum(deltas) / len(deltas)
```
Live sanity check: 5 replies to 1.1.1.1 (140–156 ms range) yield jitter ≈
4.6 ms; `ping -c 3 8.8.8.8` gave stddev 27.6 ms from the summary line — both
consistent with the summary-line `stddev` field as a cross-check.

Failure modes:
- Duplicated/out-of-order replies produce duplicate `icmp_seq` — dedupe by
  seq number if strictness needed.
- Lines with `time<0.1 ms` on localhost break the float regex → skip them.
- Fewer than 2 samples → None (report "insufficient data").

### 3. WiFi RSSI / noise / channel

⚠️ **The `airport` binary is GONE on this OS.** The classic path
`/System/Library/PrivateFrameworks/Apple80211.framework/Versions/A/Resources/airport`
does **not exist** on macOS 26.7 (`ls` verified: No such file or directory).
It was removed by Apple around Sonoma/Sequoia; any spec relying on it must be
treated as legacy. Sources: github.com/braineo/airport-bssid README ("no
longer supported").

Verified replacement — `system_profiler SPAirPortDataType` (live output on
this machine, no root required):
```
Current Network Information:
    <SSID>:
      PHY Mode: 802.11n
      Channel: 13 (2GHz, 20MHz)
      Country Code: PK
      Network Type: Infrastructure
      Security: WPA2 Personal
      Signal / Noise: -31 dBm / -97 dBm
```

Secondary source (also live-tested): `ipconfig getsummary en0` shows SSID and
BSSID (redacted by the OS in this environment) but **no RSSI** — use it only
for SSID/BSSID, not signal strength.
`sudo wdutil info` gives richer data but requires sudo (verified: prompts for
password) → out of scope for passwordless automation.

Implementation:
```python
def wifi_info(iface_hint: str | None = None) -> dict | None:
    """Return {'ssid', 'phy_mode', 'channel', 'band', 'rssi_dbm',
    'noise_dbm'} for the current Wi-Fi network, or None."""
    import ast
    p = subprocess.run(["system_profiler", "SPAirPortDataType", "-json"],
                       capture_output=True, text=True, timeout=30)
    if p.returncode != 0:
        return None
    try:
        data = ast.literal_eval(p.stdout) if False else __import__("json").loads(p.stdout)
        items = (data.get("SPAirPortDataType") or [{}])[0].get("spairport_current_network_information") or []
        v = next(iter(items.values())) if isinstance(items, dict) else (items[0] if items else {})
        sig = str(v.get("spairport_signal_or_noise", ""))       # "-31 dBm / -97 dBm"
        m = re.match(r"\s*(-?\d+)\s*dBm\s*/\s*(-?\d+)\s*dBm", sig)
        chan = str(v.get("spairport_current_channel", ""))       # "13 (2GHz, 20MHz)"
        cm = re.match(r"(\d+)\s*\((\d+)?GHz", chan.replace("2GHz","2 GHz"))
        return {
            "ssid": v.get("_name"),
            "phy_mode": v.get("spairport_network_phymode"),
            "channel": cm.group(1) if cm else chan,
            "band": (cm.group(2) + "GHz") if cm else None,
            "rssi_dbm": int(m.group(1)) if m else None,
            "noise_dbm": int(m.group(2)) if m else None,
        }
    except Exception:
        return None
```
NOTE: exact `-json` key names were not yet dump-verified in this environment
(the text format above *was* verified); implementer should print
`system_profiler SPAirPortDataType -json` once during development and adjust
keys. Fallback parser for the plain-text format:
- RSSI/noise: `r"Signal / Noise:\s*(-?\d+)\s*dBm\s*/\s*(-?\d+)\s*dBm"`
- channel/band: `r"Channel:\s*(\d+)\s*\((\w+GHz)"`

Failure modes:
- Ethernet-only / Wi-Fi off → "Current Network Information:" section absent;
  regexes don't match → return None.
- `system_profiler` takes 2–10 s (IOKit scan) → cache result, call once per
  report, always set subprocess timeout.
- macOS privacy redaction can blank SSID in some contexts (seen live) — treat
  SSID as best-effort, never gate logic on it.

### 4. Upload speed via curl POST to public endpoints

Method: POST a fixed-size random payload (incompressible: `/dev/urandom`),
read `%{size_upload}` and `%{time_total}` from curl's `-w` format string;
Mbps = size_upload*8 / time_total / 1e6. Use `--max-time` and a temp file.

**Endpoints — each verified live on this machine (2026-08-22), 100 KB payload:**

| Endpoint | Result | Notes |
|---|---|---|
| `https://httpbin.org/post` | ✅ VERIFIED — HTTP 200, up=100000 bytes, ~2.8 s | echoes body; fine for ≤ a few MB |
| `https://postman-echo.com/post` | ✅ VERIFIED — HTTP 200, up=100000 bytes, ~3.1 s | same caveats |
| `https://speed.cloudflare.com/__up` | ✅ VERIFIED — HTTP 200, ~1.0 s | Cloudflare's own speedtest upload sink; fastest, accepts arbitrary body |
| `https://httpbin.dev/post` | ❌ REJECTED — HTTP 400 "invalid semicolon separator in query" even with raw `--data-binary`; UNVERIFIED/unusable for this purpose | do not use |

Curl invocation (all flags verified):
```bash
curl -s -o /dev/null -w '%{size_upload} %{time_total}' \
     -X POST --data-binary @payload.bin --max-time 60 \
     https://speed.cloudflare.com/__up
```

Implementation:
```python
ENDPOINTS_VERIFIED = [
    "https://speed.cloudflare.com/__up",
    "https://httpbin.org/post",
    "https://postman-echo.com/post",
]   # all three confirmed live 2026-08-22

def upload_speed_mbps(size_bytes: int = 1_000_000,
                      endpoint: str = ENDPOINTS_VERIFIED[0],
                      timeout: float = 90.0) -> dict | None:
    """POST random bytes; return {'mbps', 'bytes', 'seconds'} or None."""
    import tempfile, os
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as f:
        f.write(os.urandom(size_bytes)); payload = f.name
    fmt = "%{http_code} %{size_upload} %{time_total}"
    p = subprocess.run(
        ["curl", "-s", "-o", "/dev/null", "-w", fmt, "-X", "POST",
         "--data-binary", "@" + payload, "--max-time", str(int(timeout)),
         endpoint],
        capture_output=True, text=True, timeout=timeout + 10)
    os.unlink(payload)
    parts = p.stdout.split()
    if len(parts) == 3 and parts[0] == "200":
        code, nbytes, secs = int(parts[0]), int(parts[1]), float(parts[2])
        if secs > 0 and nbytes > 0:
            return {"mbps": nbytes * 8 / secs / 1e6,
                    "bytes": nbytes, "seconds": secs}
    return None
```

Failure modes:
- Non-200 status (rate limit, 4xx like httpbin.dev) → discard sample; fall
  through to next endpoint in ENDPOINTS_VERIFIED.
- Payload too large for echo services (httpbin/postman buffer bodies in RAM):
  keep ≤ 2 MB there; Cloudflare `__up` tolerates much larger bodies.
- `%{time_total}` includes TLS handshake on first request → for accuracy do a
  warm-up request first, or reuse connection with multiple sequential POSTs
  and average after the first.
- Corporate proxies can intercept POSTs; validate `size_upload == expected`.
