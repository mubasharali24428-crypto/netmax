#!/usr/bin/env python3
"""netmax — squeeze every bit your plan actually pays for.

CAN:  measure true single-stream throughput, claim a larger per-flow share of a
      contended WiFi pipe with N parallel streams (standard TCP fairness),
      rank public DNS resolvers by latency.
CANNOT: exceed the bandwidth your ISP provisions. No software can — the cap is
      enforced on the provider's side. Anyone claiming "10x speed" is selling
      scamware.
"""

from __future__ import annotations

import argparse
import importlib
import json
import os
import random
import re
import socket
import statistics
import string
import struct
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

from netmax_ai import AISpeedGovernor

CF_DOWN = "https://speed.cloudflare.com/__down"
# Four sources, static files first. Cloudflare's bot layer adaptively
# 403-blocks repeated hits from one client (returns a 1-byte body that
# reads as ~0 Mbps), so it is LAST — OVH/Hetzner/CacheFly statics lead.
# Vetted 2026-10-03 (HEAD/ranged-GET only): LeaseWeb's /speedtest path is
# dead (404), Hetzner rejects HEAD but serves GET (which is all we use).
# {cb} = cache-buster.
ENDPOINTS: list[tuple[str, str]] = [
    ("OVH", "https://proof.ovh.net/files/100Mb.dat"),
    ("Hetzner", "https://fsn1-speed.hetzner.com/100MB.bin"),
    ("CacheFly", "https://cachefly.cachefly.net/100mb.test"),
    ("Cloudflare", f"{CF_DOWN}?bytes=50000000&cb={{cb}}"),
]
RESOLVERS = {
    "Cloudflare 1.1.1.1": "1.1.1.1",
    "Google 8.8.8.8": "8.8.8.8",
    "Quad9 9.9.9.9": "9.9.9.9",
}


class NetMaxError(RuntimeError):
    """A measurement could not be completed."""


# ── progress heartbeat ──────────────────────────────────────────────────────
# Long runs (6 h surveillance, strict holds) are otherwise silent until the
# window ends — a hung CDN looks identical to a slow one from outside.
# --progress-out PATH appends one JSON object per line (start/chunk/
# interval/attempt/done) so operators (tail -f) and future watchdogs can
# tell "working" from "stuck". "done" fires on completion OR failure —
# run health comes from the exit code, not the log. Zero cost when unset.
_PROGRESS_LOCK = threading.Lock()
_PROGRESS_FH = None
_PROGRESS_MODE = ""


def _progress_emit(event: dict) -> None:
    fh = _PROGRESS_FH
    if fh is None:
        return
    payload = {"ts": time.time(), "mode": _PROGRESS_MODE}
    payload.update(event)
    line = json.dumps(payload) + "\n"
    with _PROGRESS_LOCK:
        try:
            fh.write(line)
            fh.flush()
        except OSError:
            pass


def _progress_begin(mode: str, path: str | None) -> None:
    """Open the progress log and emit start. No-op when path is None."""
    global _PROGRESS_FH, _PROGRESS_MODE
    if not path:
        return
    try:
        fh = open(path, "w", encoding="utf-8")
    except OSError as exc:
        raise NetMaxError(f"cannot open --progress-out {path}: {exc}") from exc
    _PROGRESS_FH, _PROGRESS_MODE = fh, mode
    _progress_emit({"event": "start"})


def _progress_end() -> None:
    """Emit done, close, restore. Never raises — safe in a finally block."""
    global _PROGRESS_FH, _PROGRESS_MODE
    if _PROGRESS_FH is None:
        return
    try:
        _progress_emit({"event": "done"})
    finally:
        try:
            _PROGRESS_FH.close()
        except OSError:
            pass
        _PROGRESS_FH, _PROGRESS_MODE = None, ""


# ── throughput ────────────────────────────────────────────────────────────────

def _curl_argv(seconds: float, url: str, limit_bps: float | None) -> list[str]:
    """curl argv for one download chunk, optionally rate-limited.

    limit_bps is PLAIN bytes/second (no k/m suffix — curl's suffixes are
    1024-based, which would silently misstate a Mbps target).
    """
    argv = ["curl", "-sS", "-o", "/dev/null", "-w", "%{http_code} %{size_download}",
            "--max-time", str(int(max(seconds, 1)))]
    if limit_bps:
        argv += ["--limit-rate", str(int(limit_bps))]
    return argv + [url]


# Adaptive endpoint order: an endpoint that hard-failed (429/403/TLS) is
# deprioritized so long runs don't waste the head of every chunk — and
# every governor interval — re-hitting a rate-limited CDN before falling
# back. That repeated dead probe read as a sawtooth on the live speedometer
# (observed 2026-09-27: OVH 429 → ~12% of every 5 s interval lost to the
# failed attempt). Cooldown escalates with consecutive failures — a lone
# blip costs 60 s, but an endpoint that keeps failing (Cloudflare's bot
# layer adaptively 403ing repeated hits) backs off 5 min, then 1 h max.
# Any success resets the streak.
_ENDPOINT_FAIL_UNTIL: dict[str, float] = {}
_ENDPOINT_FAIL_COUNT: dict[str, int] = {}
ENDPOINT_COOLDOWN_S = 60.0
ENDPOINT_COOLDOWN_STEPS = (60.0, 300.0, 3600.0)
# Cross-run breaker memory: yesterday's 429s must still count after a
# restart, or every fresh CLI run re-hammers a throttled CDN from zero.
# Wall-clock file (monotonic dies with the process); owner-only, best
# effort — a missing/unreadable file degrades to memory-only, never an
# error. Writes throttled: cooldowns last minutes, losing <60 s is noise.
_ENDPOINT_STATE_NAME = ".netmax-endpoints.json"
_ENDPOINT_SAVE_MIN_INTERVAL_S = 60.0
_ENDPOINT_LOCK = threading.Lock()
_ENDPOINT_STATE_LOADED = False
_LAST_ENDPOINT_SAVE = 0.0


def _reset_endpoint_health() -> None:
    with _ENDPOINT_LOCK:
        _ENDPOINT_FAIL_UNTIL.clear()
        _ENDPOINT_FAIL_COUNT.clear()
        global _ENDPOINT_STATE_LOADED, _LAST_ENDPOINT_SAVE
        _ENDPOINT_STATE_LOADED = True  # forget disk too — clean slate
        _LAST_ENDPOINT_SAVE = 0.0
    try:
        os.unlink(_endpoint_state_path())
    except OSError:
        pass


def _endpoint_state_path() -> str:
    return os.path.join(os.path.expanduser("~"), _ENDPOINT_STATE_NAME)


def _endpoint_state_load_locked() -> None:
    """One-time load of persisted streaks; caller holds _ENDPOINT_LOCK."""
    global _ENDPOINT_STATE_LOADED
    if _ENDPOINT_STATE_LOADED:
        return
    _ENDPOINT_STATE_LOADED = True
    try:
        with open(_endpoint_state_path(), encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return
    if not isinstance(data, dict):
        return
    now_wall, now_mono = time.time(), time.monotonic()
    for name, entry in data.items():
        if not isinstance(name, str) or not isinstance(entry, dict):
            continue
        try:
            streak = int(entry["streak"])
            remaining = float(entry["until_wall"]) - now_wall
        except (KeyError, TypeError, ValueError):
            continue
        if streak >= 1 and remaining > 0:
            _ENDPOINT_FAIL_COUNT[name] = streak
            wait = ENDPOINT_COOLDOWN_STEPS[min(streak, len(ENDPOINT_COOLDOWN_STEPS)) - 1]
            _ENDPOINT_FAIL_UNTIL[name] = now_mono + min(remaining, wait)


def _endpoint_state_save_locked() -> None:
    """Persist live streaks (throttled); caller holds _ENDPOINT_LOCK."""
    global _LAST_ENDPOINT_SAVE
    now_mono = time.monotonic()
    if now_mono - _LAST_ENDPOINT_SAVE < _ENDPOINT_SAVE_MIN_INTERVAL_S:
        return
    _LAST_ENDPOINT_SAVE = now_mono
    payload = {
        name: {"streak": _ENDPOINT_FAIL_COUNT[name],
               "until_wall": time.time() + max(0.0, until - now_mono)}
        for name, until in _ENDPOINT_FAIL_UNTIL.items()
        if name in _ENDPOINT_FAIL_COUNT and until > now_mono
    }
    try:
        path = _endpoint_state_path()
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh)
    except OSError:
        pass  # best effort — memory still protects this run


def _ordered_endpoints() -> list[tuple[str, str]]:
    """Healthy endpoints first, cooled-down ones last (still tried)."""
    with _ENDPOINT_LOCK:
        _endpoint_state_load_locked()
        now = time.monotonic()
        healthy = [e for e in ENDPOINTS if _ENDPOINT_FAIL_UNTIL.get(e[0], 0.0) <= now]
        skipped = [e for e in ENDPOINTS if _ENDPOINT_FAIL_UNTIL.get(e[0], 0.0) > now]
        return healthy + skipped


def _mark_endpoint(name: str, ok: bool) -> None:
    with _ENDPOINT_LOCK:
        if ok:
            _ENDPOINT_FAIL_UNTIL.pop(name, None)
            _ENDPOINT_FAIL_COUNT.pop(name, None)
        else:
            streak = _ENDPOINT_FAIL_COUNT.get(name, 0) + 1
            _ENDPOINT_FAIL_COUNT[name] = streak
            wait = ENDPOINT_COOLDOWN_STEPS[min(streak, len(ENDPOINT_COOLDOWN_STEPS)) - 1]
            _ENDPOINT_FAIL_UNTIL[name] = time.monotonic() + wait
        _endpoint_state_save_locked()


def _pull_chunk(seconds: float, limit_bps: float | None,
                problems: list[str]) -> tuple[int, bool]:
    """One endpoint sweep: curl until `seconds` elapses or data runs out.

    Returns (bytes, hit_time_cap). hit_time_cap is True when curl ended on
    the window cap itself (exit 28) — the caller's deadline is then spent
    and no further chunk should start. Diagnostics accumulate into
    `problems`; a sweep that delivers nothing returns (0, False).

    UX-FIX (P0): the write-out carries %{http_code} and the sample is
    accepted only when the server answered 2xx. Before this, a rate-limited
    429 with a tiny error body (curl exit 0, size_download=162) counted as
    "downloaded data" and fabricated throughput.
    """
    for name, template in _ordered_endpoints():
        url = template.format(cb=random.getrandbits(64))
        try:
            proc = subprocess.run(
                _curl_argv(seconds, url, limit_bps),
                capture_output=True, text=True,
                timeout=seconds + 15,
            )
        except FileNotFoundError:
            raise NetMaxError(
                "curl not found on PATH — install curl to measure"
            ) from None
        except subprocess.TimeoutExpired:
            problems.append(f"{name}: curl hung past subprocess timeout")
            _mark_endpoint(name, ok=False)
            continue
        fields = proc.stdout.strip().split()
        if len(fields) == 2 and fields[0].isdigit() and fields[1].isdigit():
            http_code, received = int(fields[0]), int(fields[1])
        else:
            http_code, received = None, 0
        # curl exit 28 = our own time cap (expected); 0 = clean finish.
        # Anything else (TLS reset, HTTP error, DNS fail) invalidates even a
        # partial byte count — counting it would fabricate throughput.
        if proc.returncode not in (0, 28):
            problems.append(
                f"{name}: {proc.stderr.strip() or f'curl exit {proc.returncode} after {received}B'}"
            )
            _mark_endpoint(name, ok=False)
            continue
        # HTTP status must be 2xx — a 4xx/5xx body (rate-limit page, block
        # page, error JSON) is never throughput, whatever its size.
        if http_code is None or not 200 <= http_code < 300:
            problems.append(
                f"{name}: HTTP {http_code if http_code is not None else 'unparseable'} "
                f"({received}B body — not counted as data)"
            )
            _mark_endpoint(name, ok=False)
            continue
        if received > 0:
            _mark_endpoint(name, ok=True)
            _progress_emit({"event": "chunk", "endpoint": name,
                            "bytes": received,
                            "hit_cap": proc.returncode == 28})
            return received, proc.returncode == 28
        problems.append(f"{name}: 2xx but empty body ({proc.stdout.strip()[:60]!r})")
        _mark_endpoint(name, ok=False)
    _progress_emit({"event": "chunk", "endpoint": None, "bytes": 0})
    return 0, False


def _pull(seconds: float, limit_bps: float | None = None) -> int:
    """Download for the FULL requested window; return total bytes received.

    Sustains the window: no test file is bigger than ~100 MiB, which a
    30 Mbps pipe drains in under half a minute — the W15 long-run feature
    (up to 6 h) therefore serves a run as BACK-TO-BACK curl chunks. A chunk
    that finishes early (exit 0, file exhausted) is immediately replaced by
    the next one with a fresh cache-buster; only the window cap (exit 28)
    ends the pull. Without this loop a "15-minute" run auto-stopped as soon
    as the first file drained — the reported duration then measured the
    file size, not the request.

    Resilience: a mid-run chunk failure (Cloudflare 429/403 bot blocks, TLS
    resets) pauses briefly and retries — a long surveillance run must not
    die on one blip. Bytes from hard-failed chunks are never counted. Only
    a window that received zero bytes raises NetMaxError.

    limit_bps caps this stream at N bytes/s via curl --limit-rate (`limit`
    mode; the caller divides the aggregate cap across streams).
    """
    deadline = time.monotonic() + max(float(seconds), 0.0)
    total = 0
    problems: list[str] = []
    while True:
        chunk_cap = deadline - time.monotonic()
        if chunk_cap <= 0:
            break
        got, hit_cap = _pull_chunk(chunk_cap, limit_bps, problems)
        total += got
        if hit_cap:
            break
        if got == 0 and time.monotonic() < deadline:
            time.sleep(min(2.0, deadline - time.monotonic()))
    if total == 0:
        raise NetMaxError("all speed endpoints failed — " + "; ".join(problems[-6:]))
    return total


def throughput(streams: int, seconds: float,
               limit_bps: float | None = None) -> tuple[float, float]:
    """Open `streams` parallel pulls; return (aggregate Mbps, total MB moved).

    limit_bps (bytes/s) is the AGGREGATE cap; each stream gets an equal
    share so the sum holds even with every stream open.
    """
    started = time.monotonic()
    per_stream_bps = limit_bps / streams if limit_bps else None
    with ThreadPoolExecutor(max_workers=streams) as pool:
        futures = [pool.submit(_pull, seconds, per_stream_bps)
                   for _ in range(streams)]
        counts = [future.result() for future in futures]
    elapsed = max(time.monotonic() - started, 1e-9)
    grand_total = sum(counts)
    return grand_total * 8 / elapsed / 1e6, grand_total / 1e6


# ── DNS ───────────────────────────────────────────────────────────────────────

# RFC 1035 §4.1.1 RCODE values (low 4 bits of byte 3 in the header).
DNS_RCODE_NOERROR = 0
DNS_RCODE_SERVFAIL = 2
DNS_RCODE_NXDOMAIN = 3
DNS_RCODE_REFUSED = 5
DNS_RCODE_NAMES = {
    DNS_RCODE_SERVFAIL: "SERVFAIL",
    DNS_RCODE_REFUSED: "REFUSED",
    1: "FORMERR", 4: "NOTIMP", 6: "YXDOMAIN", 7: "YXRRSET", 8: "NXRRSET",
}


def _udp_query(server: str, name: str, timeout: float = 2.0) -> float:
    """One UDP A-record lookup; return RTT in seconds. Raises on timeout.

    RCODE-aware per RFC 1035 §4.1.1: only a real answer (RCODE 0) or an
    authoritative negative (NXDOMAIN, RCODE 3) proves the resolver is alive.
    SERVFAIL (2) / REFUSED (5) / any other code raise NetMaxError so a broken
    resolver can never rank as "fastest".
    """
    txid = random.getrandbits(16)
    header = struct.pack(">HHHHHH", txid, 0x0100, 1, 0, 0, 0)   # RD set, 1 question
    qname = b"".join(
        bytes([len(label)]) + label.encode("ascii") for label in name.split(".")
    ) + b"\x00"
    packet = header + qname + struct.pack(">HH", 1, 1)           # QTYPE=A, QCLASS=IN

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        sent_at = time.perf_counter()
        sock.sendto(packet, (server, 53))
        while True:                                              # skip late stragglers
            data, _ = sock.recvfrom(512)
            if (
                len(data) >= 12
                and struct.unpack(">H", data[:2])[0] == txid
                and data[2] & 0x80                                # QR bit: is a response
            ):
                rcode = data[3] & 0x0F
                if rcode == DNS_RCODE_NXDOMAIN:
                    return time.perf_counter() - sent_at         # alive, name absent
                if rcode != DNS_RCODE_NOERROR:
                    raise NetMaxError(
                        f"resolver {server} returned {DNS_RCODE_NAMES.get(rcode, rcode)}"
                    )
                return time.perf_counter() - sent_at             # normal A answer
    except TimeoutError as exc:
        raise NetMaxError(f"resolver {server} timed out") from exc
    finally:
        sock.close()


def _fresh_name() -> str:
    """Random subdomain → forces a real lookup; answer is a fast NXDOMAIN."""
    token = "".join(random.choices(string.ascii_lowercase, k=12))
    return f"{token}.cloudflare.com"


def _median_rtt_ms(server: str | None, attempts: int = 3) -> float:
    """Median RTT in ms. server=None measures the system resolver path."""
    samples: list[float] = []
    for _ in range(attempts):
        started = time.perf_counter()
        try:
            if server is None:
                socket.getaddrinfo(_fresh_name(), 443)
            else:
                _udp_query(server, _fresh_name())
        except (socket.gaierror, NetMaxError) as exc:
            elapsed_ms = (time.perf_counter() - started) * 1000
            if isinstance(exc, NetMaxError):
                # RCODE-level failure (SERVFAIL/REFUSED/timeout): the resolver
                # answered but is broken — never a valid latency sample.
                raise NetMaxError(f"resolver {server} unfit: {exc}") from exc
            # System-resolver path: random names never resolve, so a FAST
            # gaierror still proves resolution happened — valid sample.
            if elapsed_ms >= 2000:
                raise NetMaxError(f"resolver unreachable ({exc})") from exc
        else:
            elapsed_ms = (time.perf_counter() - started) * 1000
        samples.append(elapsed_ms)
        time.sleep(0.05)
    return statistics.median(samples)


# DNS ranking cache: resolver latency barely moves within the hour, and a
# full ranking costs seconds of UDP probes — serve repeats from memory.
DNS_CACHE_TTL_S = 3600.0
_DNS_CACHE: dict = {"at": float("-inf"), "rows": None}


def _reset_dns_cache() -> None:
    _DNS_CACHE["at"] = float("-inf")
    _DNS_CACHE["rows"] = None


def dns_ranking() -> list[tuple[str, float]]:
    """Rank resolvers by median RTT; unfit resolvers are skipped, not fatal.

    Results are cached for DNS_CACHE_TTL_S — resolver latency barely moves
    within the hour, and a full ranking costs seconds of UDP probes.
    """
    now = time.monotonic()
    if _DNS_CACHE["rows"] is not None and now - _DNS_CACHE["at"] < DNS_CACHE_TTL_S:
        return [tuple(r) for r in _DNS_CACHE["rows"]]
    rows: list[tuple[str, float]] = []
    try:
        rows.append(("System default", _median_rtt_ms(None)))
    except NetMaxError:
        pass  # system path unusable — still rank the public resolvers
    for label, ip in RESOLVERS.items():
        try:
            rows.append((label, _median_rtt_ms(ip)))
        except NetMaxError as exc:
            print(f"   ({label} skipped — {exc})")
    if not rows:
        raise NetMaxError("no DNS resolver reachable")
    rows = sorted(rows, key=lambda row: row[1])
    _DNS_CACHE["at"] = now
    _DNS_CACHE["rows"] = rows
    return [tuple(r) for r in rows]


# ── reporting ─────────────────────────────────────────────────────────────────

def _hr(title: str) -> None:
    print(f"\n── {title} " + "─" * max(0, 50 - len(title)))


def _print_speed(tag: str, streams: int, mbps: float, mb: float, seconds: int) -> None:
    print(f"{tag:<14} {streams:>2} stream(s)  {mbps:>7.1f} Mbps   ({mb:,.0f} MB in {seconds}s)")


SHARE_NOTE = (
    "note: under contention your share of the pipe scales with connection\n"
    "count — standard per-flow fairness, no packets of other users touched."
)


def run_baseline(seconds: int) -> float:
    mbps, mb = throughput(1, seconds)
    _hr("Baseline — what ordinary apps get")
    _print_speed("single-stream", 1, mbps, mb, seconds)
    return mbps


# ── plugin mode registry (W6-C2) ─────────────────────────────────────────────
# Third-party modes register here instead of editing main(): each entry maps a
# subcommand name to a runner receiving parsed-args + validated helpers.
PLUGIN_MODES: dict[str, dict[str, object]] = {}


def plugin_mode(name: str, help_text: str = ""):
    """Decorator: register a plugin mode callable(args) -> None.

    Usage in an external module imported via NETMAX_PLUGIN env (colon-separated
    module paths), loaded once at startup:

        import netmax
        @netmax.plugin_mode("myprobe", "my custom probe")
        def run(args):
            ...
    """
    def _wrap(fn):
        PLUGIN_MODES[name] = {"fn": fn, "help": help_text}
        return fn
    return _wrap


def _load_plugins() -> list[str]:
    """Import NETMAX_PLUGIN-listed modules so their @plugin_mode decorators run."""
    spec = os.environ.get("NETMAX_PLUGIN", "").strip()
    if not spec:
        return []
    loaded: list[str] = []
    for mod_name in [m.strip() for m in spec.split(":") if m.strip()]:
        try:
            __import__(mod_name)
            loaded.append(mod_name)
            # When run as a script, plugins import the MODULE 'netmax'; their
            # decorators registered into THAT copy's PLUGIN_MODES. Merge them
            # into this (possibly __main__) instance so argparse + dispatch
            # see the plugin subcommands.
            their = getattr(sys.modules.get("netmax"), "PLUGIN_MODES", {})
            if their is not PLUGIN_MODES:
                PLUGIN_MODES.update(their)
        except ImportError as exc:
            print(f"netmax: plugin '{mod_name}' failed to load: {exc}", file=sys.stderr)
    return loaded


def run_turbo(streams: int, seconds: int) -> float:
    mbps, mb = throughput(streams, seconds)
    _hr(f"Turbo — {streams} parallel streams")
    _print_speed("multi-stream", streams, mbps, mb, seconds)
    print(SHARE_NOTE)
    return mbps


def run_boost(streams: int, seconds: int) -> None:
    base = run_baseline(seconds)
    turbo = run_turbo(streams, seconds)
    _hr("Result")
    if base <= 0.5 or turbo <= 0.5:
        # UX-FIX (P0): a near-zero reading is a FAILED measurement, not a
        # "0.0 Mbps success". Exit 1 so the bridge envelope carries
        # success=false and MCP clients see isError instead of prose.
        print("connection dropped mid-measurement — rerun once the link is stable.")
        raise NetMaxError(
            f"measurement unreliable (baseline {base:.2f} / turbo {turbo:.2f} Mbps) "
            "— link dropped mid-measurement; rerun once stable"
        )
    gain = (turbo / base - 1) * 100
    print(f"headroom unlocked: {gain:+.0f}%  ({base:.1f} → {turbo:.1f} Mbps)")
    if gain < 10:
        print("your apps already reach the full provisioned rate — DNS/tuning is all that's left.")
    else:
        print(f"use multi-stream downloads (aria2c -x{streams}, IDM, etc.) to keep this rate.")


def run_dns() -> None:
    _hr("DNS resolver ranking (lower is faster)")
    rows = dns_ranking()
    best_name = rows[0][0]                           # already sorted ascending
    for i, (name, ms) in enumerate(rows, 1):
        marker = "  ← fastest" if name == best_name else ""
        print(f"{i}. {name:<22} {ms:>6.1f} ms{marker}")
    if best_name != "System default":
        print(f"switching tip: set {best_name} in System Settings → Network → DNS.")
    else:
        print("your current resolver is already the fastest tested.")


def run_full(streams: int, seconds: int) -> None:
    run_boost(streams, seconds)
    run_dns()
    run_bloat(streams, seconds)
    _hr("Reversible macOS TCP knobs (inspect, apply manually)")
    print("  sysctl net.inet.tcp.autorcvbufmax net.inet.tcp.autosndbufmax")
    print("  larger buffers help only on high-latency links; revert with sudo sysctl -w …")


# ── bufferbloat (latency under load) ─────────────────────────────────────────

BLOAT_GRADES = [  # (max latency increase ms, grade) — Waveform/DSLReports rubric
    (5, "A+"), (30, "A"), (60, "B"), (200, "C"), (400, "D"),
]


def _ping_median_ms(host: str = "1.1.1.1", count: int = 10) -> float:
    """Median RTT via system ping; raises NetMaxError if ping fails.

    Always passes a Python-level timeout: BSD/macOS `ping -c N` can block
    indefinitely when ICMP is silently dropped (VPN/corporate Wi-Fi), unlike
    relying on ping's own interval math alone.
    """
    # count * 1s interval + 2s reply slack, floor 5s for tiny counts
    timeout = max(5.0, count * 1.0 + 2.0)
    try:
        proc = subprocess.run(
            ["ping", "-c", str(count), host], capture_output=True, text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise NetMaxError(f"ping to {host} timed out after {timeout:.0f}s") from exc
    times = re.findall(r"time[=<]([\d.]+) ms", proc.stdout)
    if not times:
        raise NetMaxError(f"ping to {host} failed: {proc.stderr.strip()[:120]}")
    return statistics.median(float(t) for t in times)


def bloat_grade(streams: int, seconds: float) -> tuple[float, float, str]:
    """Measure idle vs loaded median latency; return (idle_ms, delta_ms, grade).

    Grade rubric follows the Waveform/DSLReports scale. Sampling is bounded by
    the download window: pings are short (count=3) and sized so the saturating
    download outlasts the whole sampling loop.
    """
    idle_ms = _ping_median_ms()
    # 3 loaded samples ≈ 3×(3 pings + 0.2s gaps) ≈ ~4-6s; download must cover it
    window = max(seconds * streams / max(streams, 1), 8.0)
    loaded: list[float] = []
    with ThreadPoolExecutor(max_workers=streams) as pool:
        futures = [pool.submit(_pull, window) for _ in range(streams)]
        try:
            for _ in range(3):
                loaded.append(_ping_median_ms(count=3))
                time.sleep(0.2)
        finally:
            for f in futures:
                f.result()
    delta_ms = max(loaded) - idle_ms if loaded else float("inf")
    for limit, grade in BLOAT_GRADES:
        if delta_ms < limit:
            return idle_ms, delta_ms, grade
    return idle_ms, delta_ms, "F"


def run_bloat(streams: int, seconds: int) -> None:
    _hr("Bufferbloat — latency under load")
    idle_ms, delta_ms, grade = bloat_grade(streams, max(seconds, 6))
    print(f"idle latency:      {idle_ms:>6.1f} ms")
    print(f"loaded increase:   {delta_ms:+6.1f} ms   grade: {grade}")
    if grade in ("A+", "A"):
        print("your link stays responsive under load — nothing to fix.")
    else:
        print(
            "fix: enable SQM/fq_codel or CAKE on your router (OpenWrt/pfSense),\n"
            "or lower your router's shaper slightly below line rate."
        )


# ── speed cap (limit mode) ───────────────────────────────────────────────────

# curl's limiter paces in chunk bursts and TCP ramps up over the first
# seconds, so a held rate wobbles around the target — more with many
# streams (burst granularity × N) and on short windows. Inside this band
# the run counts as "held"; anything beyond is reported as over/short.
LIMIT_TOLERANCE = 0.10
# Closed-loop governor: re-pace curl every LIMIT_INTERVAL_S from measured
# progress, so the aggregate tracks the target as the line wobbles (WiFi
# contention, slow start, limiter bursts) instead of trusting one static
# --limit-rate for the whole window.
LIMIT_INTERVAL_S = 5.0
# Max correction per interval, both ways — one noisy interval can never
# swing the pace wildly (controller stability).
LIMIT_MAX_CORRECT = 1.5
# HARD CEILING on the commanded pace: 1.5× the target aggregate, ever.
# A cap above this can never help — if the line can't reach 1.5× target it
# can't reach the target either — and without a ceiling a degraded stretch
# ratchets the pace upward (×1.5 per interval), so a suddenly recovering
# line would briefly deliver MULTIPLES of the requested speed. This ceiling
# is what bounds the held rate tightly around the target: worst case is one
# 5 s interval at 1.5× target while the controller re-aims.
LIMIT_PACE_CEILING = 1.5
# This many consecutive dead intervals (no bytes at all) reads as a dead
# connection: abort honestly instead of "holding" 0 Mbps forever.
# 60 × 5 s = 5 minutes of total silence survives shorter blips.
LIMIT_DEAD_INTERVALS = 60
# AI-governor telemetry is ICMP, and ping's default interval is 1s — so a
# packet_loss(count=10) probe is ~10s of traffic, LONGER than the 5s slice it
# runs inside. Probing every slice both overruns the governor loop and puts
# more traffic on the wire than the hardcoded path it replaces, which is
# backwards for a cap whose purpose is to be gentle on a contended link.
# Sample every Nth slice instead and reuse the last reading in between.
AI_TELEMETRY_EVERY = 3
AI_PROBE_COUNT = 3


def _checked_mbps(value: float) -> float:
    if not 0.5 <= value <= 10_000:
        raise NetMaxError(f"--mbps must be 0.5..10000, got {value:g}")
    return value


def _limit_governor(
    streams: int,
    seconds: float,
    target_bps: float,
    ai_governor: AISpeedGovernor | None = None,
) -> tuple[int, list[float], float]:
    """Hold target_bps (aggregate bytes/s) for `seconds`; return (bytes, rates, elapsed).

    Each LIMIT_INTERVAL_S slice runs `streams` paced pulls at the current
    per-stream cap; the cap is then corrected by target/achieved (clamped
    to ±LIMIT_MAX_CORRECT) so the sum keeps tracking the target even as
    the line degrades or recovers. The commanded pace is hard-capped at
    LIMIT_PACE_CEILING × target, so the held rate stays in a tight band
    around the target no matter how the line wobbles — a degraded stretch
    can never ratchet the pace into multiples of the request. `rates`
    holds one Mbps sample per interval for the stability report. A single
    dead interval (endpoint blip, WiFi dropout) is survived; only
    LIMIT_DEAD_INTERVALS consecutive dead intervals — or a window with
    zero bytes — raises NetMaxError.
    """
    deadline = time.monotonic() + max(float(seconds), 0.0)
    per_stream_bps = target_bps / streams
    pace_ceiling_bps = target_bps * LIMIT_PACE_CEILING
    total = 0
    rates: list[float] = []
    dead_streak = 0
    slices_done = 0
    elapsed = 0.0
    target_mbps = target_bps * 8 / 1e6
    last_telemetry: dict[str, float] = {}
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        slice_s = min(LIMIT_INTERVAL_S, remaining)
        started = time.monotonic()
        counts = [0] * streams
        with ThreadPoolExecutor(max_workers=streams) as pool:
            futures = [pool.submit(_pull, slice_s, per_stream_bps)
                       for _ in range(streams)]
            for i, future in enumerate(futures):
                try:
                    counts[i] = future.result()
                except NetMaxError:
                    counts[i] = 0            # dead interval — governor holds on
        slice_elapsed = max(time.monotonic() - started, 1e-9)
        elapsed += slice_elapsed
        got = sum(counts)
        total += got
        achieved_bytes_s = got / slice_elapsed          # same unit as target_bps
        achieved_mbps = achieved_bytes_s * 8 / 1e6
        rates.append(achieved_bytes_s * 8 / 1e6)        # Mbps for the report
        _progress_emit({"event": "interval", "mbps": rates[-1]})
        dead_streak = dead_streak + 1 if got == 0 else 0
        if dead_streak >= LIMIT_DEAD_INTERVALS:
            raise NetMaxError(
                f"line delivered nothing for {dead_streak} consecutive "
                f"{int(LIMIT_INTERVAL_S)}s intervals — connection looks dead"
            )
        # Re-pace for the next interval: aim at the target, clamped so one
        # noisy interval can never swing the pace wildly. Three cases keep
        # the pace unchanged: the FIRST interval (TCP slow-start ramp — the
        # low reading is the connection warming up, not the cap being too
        # tight), a starvation interval (<25% of target — boosting into a
        # recovering line only overshoots), and anything inside a ±3%
        # deadband (correcting inside measurement noise oscillates).
        slices_done += 1
        if got > 0 and slices_done > 1 and achieved_bytes_s >= 0.25 * target_bps:
            factor = target_bps / achieved_bytes_s
            if 0.97 * target_bps <= achieved_bytes_s <= 1.03 * target_bps:
                factor = 1.0
            factor = min(max(factor, 1 / LIMIT_MAX_CORRECT), LIMIT_MAX_CORRECT)
            per_stream_bps *= factor
        # The ceiling is unconditional — warm-up, corrections, everything is
        # bounded by it, so the commanded pace can never exceed 1.5× target.
        per_stream_bps = min(per_stream_bps, pace_ceiling_bps / streams)

        # AI governor: best-effort override after the hardcoded correction.
        if ai_governor is not None:
            try:
                # Telemetry is ICMP — sample it every AI_TELEMETRY_EVERY
                # slices and reuse the last reading in between, so the cap
                # adds a trickle of probes instead of a probe per slice.
                if not last_telemetry or slices_done % AI_TELEMETRY_EVERY == 0:
                    latency_ms = 0.0
                    jitter_ms = 0.0
                    loss_pct = 0.0
                    try:
                        latency_ms = _ping_median_ms(count=AI_PROBE_COUNT)
                    except NetMaxError:
                        pass
                    try:
                        import netmetrics as _nm
                        jitter_ms = _nm.jitter_ms(count=AI_PROBE_COUNT)
                    except NetMaxError:
                        pass
                    try:
                        import netmetrics as _nm2
                        loss_pct = _nm2.packet_loss(count=AI_PROBE_COUNT)
                    except NetMaxError:
                        pass
                    last_telemetry = {
                        "latency_ms": latency_ms,
                        "jitter_ms": jitter_ms,
                        "loss_pct": loss_pct,
                    }
                decision = ai_governor.decide(
                    target_mbps,
                    {
                        "mbps": achieved_mbps,
                        "latency_ms": last_telemetry.get("latency_ms", 0.0),
                        "jitter_ms": last_telemetry.get("jitter_ms", 0.0),
                        "loss_pct": last_telemetry.get("loss_pct", 0.0),
                        "streams": streams,
                        "endpoint": "current",
                        "endpoint_health": {},
                        "rssi": "unknown",
                        "noise": "unknown",
                        "channel": "unknown",
                    },
                )
                if decision is not None:
                    ai_governor.record_interval(
                        achieved_mbps,
                        streams,
                        target_mbps,
                    )
                    if decision.streams is not None:
                        streams = decision.streams
                    if decision.pace_bps is not None:
                        per_stream_bps = decision.pace_bps / max(streams, 1)
                    if decision.reasoning:
                        _progress_emit({"event": "ai", "reasoning": decision.reasoning})
            except (OSError, ValueError, TypeError, KeyError):
                pass

    if total == 0:
        raise NetMaxError("no data received — cannot hold the speed cap")
    return total, rates, elapsed


def run_limit(
    streams: int,
    seconds: int,
    mbps: float,
    ai_governor: bool = False,
) -> None:
    """Hold the download rate at `mbps` for the whole window — no more, no less.

    A closed-loop governor re-paces curl every few seconds from measured
    progress, so the aggregate stays pinned at the target over long runs
    as the line wobbles — and however many streams are open, the cap is
    divided evenly across them. If the line cannot reach the cap the
    shortfall is stated plainly (extra streams cannot create bandwidth
    the ISP does not deliver).
    """
    target_bps = mbps * 1e6 / 8
    governor = AISpeedGovernor() if ai_governor else None
    total, rates, elapsed = _limit_governor(streams, seconds, target_bps, ai_governor=governor)
    held = total * 8 / max(elapsed, 1e-9) / 1e6
    _hr(f"Limit — holding {mbps:g} Mbps with {streams} stream(s)")
    _print_speed("capped", streams, held, total / 1e6, int(seconds))
    delta = (held / mbps - 1) * 100
    if abs(delta) <= LIMIT_TOLERANCE * 100:
        print(f"target held: {held:.2f} Mbps vs {mbps:g} requested "
              f"({delta:+.1f}%) for the full {int(seconds)}s window.")
    elif held < mbps:
        print(
            f"short of the cap: the line delivered {held:.2f} Mbps against a "
            f"{mbps:g} Mbps target ({delta:+.1f}%). No software can create "
            "the missing bandwidth — the cap was set above what the link gave."
        )
    else:
        print(
            f"cap overrun: {held:.2f} Mbps vs {mbps:g} requested ({delta:+.1f}%). "
            "curl paces in bursts — try fewer streams or a lower cap."
        )
    if len(rates) > 1:
        band = mbps * LIMIT_TOLERANCE
        in_band = sum(1 for r in rates if abs(r - mbps) <= band)
        print(
            f"stability: {in_band * 100 / len(rates):.0f}% of "
            f"{int(LIMIT_INTERVAL_S)}s intervals within "
            f"±{LIMIT_TOLERANCE * 100:.0f}% "
            f"(min {min(rates):.2f}, mean {statistics.fmean(rates):.2f}, "
            f"max {max(rates):.2f} Mbps)"
        )
    print(
        f"band guard: the pace was hard-limited to "
        f"{mbps * LIMIT_PACE_CEILING:g} Mbps "
        f"({LIMIT_PACE_CEILING:g}× your {mbps:g} target) for the entire run."
    )


# ── CLI ───────────────────────────────────────────────────────────────────────

# W15: duration bounds. Quick tests stay 5–30 s; long surveillance runs
# (user-requested) go up to 6 h. Both share one constant set.
DURATION_MIN_S = 5
DURATION_QUICK_MAX_S = 30
DURATION_MAX_S = 21_600  # 6 hours


def _checked(value: int, low: int, high: int, flag: str) -> int:
    if not low <= value <= high:
        raise NetMaxError(f"{flag} must be {low}..{high}, got {value}")
    return value


def _checked_duration(value: int) -> int:
    """Duration accepts the quick band OR the long-run band (5–30 or 5 s…6 h).

    A single range 5..21600 would also admit nonsense like 31..59 s gaps —
    harmless in practice, but keeping the two documented bands explicit makes
    the contract clear and matches the UI's unit picker."""
    if DURATION_MIN_S <= value <= DURATION_QUICK_MAX_S:
        return value
    if DURATION_MIN_S <= value <= DURATION_MAX_S:
        return value
    raise NetMaxError(
        f"--seconds must be {DURATION_MIN_S}..{DURATION_QUICK_MAX_S} (quick) "
        f"or up to {DURATION_MAX_S} (long run), got {value}"
    )


def _safe_fetch_out(out: str | None, url: str) -> str:
    """Derive a SAFE output path for the fetch mode.

    An explicit out argument is honoured as typed (the user chose it); the
    URL-derived default is sanitized — path separators, '.', '..' and empty
    names all fall back to download.bin so a URL ending '../' can never make
    the download land at '..' (pre-fix it did, verified).
    """
    if out and out.strip():
        return out
    raw = url.rstrip("/").split("/")[-1].strip() if "/" in url else ""
    raw = raw.replace("\\", "_").replace("/", "_")
    if raw in ("", ".", ".."):
        return "download.bin"
    return raw


# name -> (module, attribute, method). Kept as strings so importing the AI
# modules stays lazy: `netmax ai --list-analyses` and every non-ai mode must
# keep working even if an AI module is missing from a partial install.
AI_ANALYSES: dict[str, tuple[str, str, str]] = {
    # P1
    "root_cause": ("netmax_ai_p1", "RootCauseClassifier", "classify"),
    "chunk_size": ("netmax_ai_p1", "AdaptiveChunkSizer", "suggest_chunk_bytes"),
    "allocate_streams": ("netmax_ai_p1", "CrossStreamCoordinator", "allocate"),
    "optimize": ("netmax_ai_p1", "MultiObjectiveOptimizer", "optimize"),
    "isp_profile": ("netmax_ai_p1", "ISPBehaviorFingerprinter", "fingerprint"),
    "wifi_advice": ("netmax_ai_p1", "WiFiOptimizationAdvisor", "advise"),
    "dns_strategy": ("netmax_ai_p1", "DNSStrategyOptimizer", "advise"),
    "loss_pattern": ("netmax_ai_p1", "PacketLossPatternRecognizer", "classify"),
    "jitter_attribution": ("netmax_ai_p1", "JitterSourceAttributor", "attribute"),
    "nl_command": ("netmax_ai_p1", "NaturalLanguageCLI", "parse"),
    # P2
    "explain": ("netmax_ai_p2", "ResultExplainer", "explain"),
    "wizard": ("netmax_ai_p2", "TroubleshootingWizard", "start"),
    "wizard_next": ("netmax_ai_p2", "TroubleshootingWizard", "next_step"),
    "wizard_conclude": ("netmax_ai_p2", "TroubleshootingWizard", "conclude"),
    "narrate": ("netmax_ai_p2", "AccessibilityNarrator", "narrate"),
    "forecast": ("netmax_ai_p2", "TrendForecaster", "forecast"),
    "hardware_health": ("netmax_ai_p2", "HardwareHealthMonitor", "assess"),
    "throttle_signature": ("netmax_ai_p2", "ZeroDayThrottleDetector", "detect"),
    "cost_advice": ("netmax_ai_p2", "CostAdvisor", "advise"),
    "benchmark": ("netmax_ai_p2", "BenchmarkComparator", "compare"),
    "coach": ("netmax_ai_p2", "GamifiedCoach", "week_plan"),
    "metric_rule": ("netmax_ai_p2", "MetricRuleEngine", "evaluate"),
}

# Analysers that consume `record_sample` kwargs rather than one input dict.
AI_RECORDERS: dict[str, str] = {
    "forecast": "record_sample",
    "hardware_health": "record_sample",
    "throttle_signature": "record_sample",
    "coach": "record_sample",
    "isp_profile": "record_sample",
}

# How each recorder turns a history row into record_* kwargs.
AI_RECORD_FIELDS: dict[str, tuple[str, ...]] = {
    "forecast": ("mbps",),
    "hardware_health": ("bloat_grade", "idle_latency_ms", "loss_pct"),
    "throttle_signature": ("mbps", "streams"),
    # hour is optional in the row; record_sample falls back to wall clock.
    "isp_profile": ("mbps", "hour"),
    "coach": (),          # accepts arbitrary metrics
}


# analysis -> (bundle_key, {method_param: input_key}).
#
# The analyser signatures are not uniform — some take one bundle, some take
# a bundle plus scalar options, some take only scalars. Guessing that
# generically is how `explain(diagnostics, tone, plan_mbps)` ends up splatted
# as kwargs, so the contract is declared per analysis instead.
#
# bundle_key is the input key holding the first positional argument. When
# that key is absent from the payload the WHOLE payload is passed instead,
# which keeps flat JSON like --input '{"mbps":40}' working.
AI_SIGNATURES: dict[str, tuple[str | None, dict[str, str]]] = {
    # P1
    "root_cause": ("diagnostics", {}),
    "chunk_size": (None, {"rtt_ms": "rtt_ms", "jitter_ms": "jitter_ms",
                          "loss_pct": "loss_pct",
                          "throughput_mbps": "throughput_mbps"}),
    "allocate_streams": (None, {"streams": "streams",
                                "aggregate_bps": "aggregate_bps",
                                "per_stream_bps": "per_stream_bps"}),
    "optimize": ("options", {"weights": "weights"}),
    "isp_profile": (None, {}),
    "wifi_advice": ("wifi", {}),
    "dns_strategy": ("resolvers", {}),
    "loss_pattern": ("events", {}),
    "jitter_attribution": (None, {"gateway_ms": "gateway_ms",
                                  "internet_ms": "internet_ms",
                                  "endpoint_ms": "endpoint_ms"}),
    "nl_command": ("text", {}),
    # P2
    "explain": ("diagnostics", {"tone": "tone", "plan_mbps": "plan_mbps"}),
    "wizard": ("symptom", {}),
    "wizard_next": ("step_id", {"answer": "answer"}),
    "wizard_conclude": ("answers", {}),
    "narrate": ("diagnostics", {"include_caveats": "include_caveats"}),
    "forecast": (None, {"horizon_days": "horizon_days"}),
    "hardware_health": (None, {"config_changed_at": "config_changed_at"}),
    "throttle_signature": (None, {}),
    "cost_advice": (None, {"plan_mbps": "plan_mbps",
                           "monthly_cost": "monthly_cost",
                           "samples": "samples",
                           "history_limit": "history_limit"}),
    "benchmark": ("mbps", {"cohort_percentiles": "cohort_percentiles",
                           "cohort_label": "cohort_label"}),
    "coach": ("goal", {"history_limit": "history_limit"}),
    "metric_rule": ("rule", {"metrics": "metrics"}),
}


def _load_json_input(spec: str) -> dict[str, Any]:
    """Parse --input: inline JSON, or @path to a JSON file."""
    text = (spec or "{}").strip()
    if text.startswith("@"):
        path = Path(text[1:]).expanduser()
        text = path.read_text(encoding="utf-8")
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError as exc:
        raise NetMaxError(f"--input is not valid JSON: {exc}") from None
    if not isinstance(parsed, dict):
        raise NetMaxError("--input must be a JSON object")
    return parsed


def _load_history(path_spec: str) -> list[dict[str, Any]]:
    """Read a history JSONL file, tolerating the corrupt lines it warns about."""
    path = Path(path_spec).expanduser()
    rows: list[dict[str, Any]] = []
    if not path.exists():
        raise NetMaxError(f"history file not found: {path}")
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue          # same tolerance as the history writer
        if isinstance(row, dict):
            rows.append(row)
    return rows


def run_ai_analysis(name: str, input_data: dict[str, Any],
                    history: list[dict[str, Any]] | None = None) -> Any:
    """Dispatch to one analyser by name and return its result."""
    entry = AI_ANALYSES.get(name)
    if entry is None:
        raise NetMaxError(
            f"unknown analysis {name!r}; run 'netmax ai --list-analyses'"
        )
    module_name, class_name, method_name = entry

    try:
        module = importlib.import_module(module_name)
    except ImportError as exc:
        raise NetMaxError(
            f"{module_name} is unavailable ({exc}); the AI analyses are "
            "optional extras"
        ) from None
    cls = getattr(module, class_name, None)
    if cls is None:
        raise NetMaxError(f"{class_name} missing from {module_name}")

    analyser = cls()
    payload = dict(input_data)

    # Replay history into record_* when the analyser wants it.
    if history:
        recorder_name = AI_RECORDERS.get(name)
        if recorder_name:
            recorder = getattr(analyser, recorder_name, None)
            if callable(recorder):
                fields = AI_RECORD_FIELDS.get(name, ())
                for row in history:
                    if fields:
                        # A null metric means "not measured" — recording it
                        # as a real 0.0 would poison a trend or a percentile
                        # with a reading that never happened.
                        kwargs = {f: row[f] for f in fields
                                  if row.get(f) is not None}
                    else:
                        kwargs = {k: v for k, v in row.items()
                                  if isinstance(v, (int, float))}
                    if kwargs:
                        try:
                            recorder(**kwargs)
                        except TypeError:
                            continue
                # history supplied the series; do not also pass it as input
                payload.pop("history", None)

    method = getattr(analyser, method_name, None)
    if not callable(method):
        raise NetMaxError(f"{class_name}.{method_name} is not callable")

    bundle_key, option_map = AI_SIGNATURES.get(name, (None, {}))
    # Options come out of the payload first; whatever is left forms the bundle.
    # A None bundle_key means the method takes NO positional argument (the
    # zero-arg and all-scalar analysers) — passing the payload there would both
    # duplicate option keys as a positional and break a zero-arg signature.
    kwargs = {
        param: payload.pop(src)
        for param, src in option_map.items()
        if src in payload
    }

    if bundle_key is None:
        try:
            return method(**kwargs)
        except (OSError, ValueError, TypeError, KeyError) as exc:
            raise NetMaxError(f"{name} failed: {exc}") from None

    positional = payload.pop(bundle_key, None)
    if positional is None:
        positional = payload      # flat form: the whole remainder is the bundle

    try:
        return method(positional, **kwargs)
    except (OSError, ValueError, TypeError, KeyError) as exc:
        raise NetMaxError(f"{name} failed: {exc}") from None


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="netmax",
        description="Honest bandwidth maximizer — fills your plan, never promises beyond it.",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)
    # mode -> (runner, takes_streams?) — adding a mode is one entry here.
    RUNNERS: dict[str, tuple[object, bool]] = {
        "baseline": (run_baseline, False),
        "turbo": (run_turbo, True),
        "boost": (run_boost, True),
        "dns": (run_dns, False),
        "bloat": (run_bloat, True),
        "full": (run_full, True),
    }
    for mode, (_fn, takes_streams) in RUNNERS.items():
        sp = sub.add_parser(mode, help=MODE_HELP.get(mode, ""))
        if takes_streams:
            sp.add_argument("--streams", type=int, default=8)
        if mode != "dns":
            sp.add_argument("--seconds", type=int, default=10)
        sp.add_argument("--progress-out", default=None,
                        help="append JSONL progress heartbeat (tail -f for long runs)")

    # v0.4 modes — separate parsers: different flag shapes than the core set.
    sp_bloat = sub.add_parser("bloat-eco", help="eco bufferbloat estimate (~100 KB)")
    sp_up = sub.add_parser("upload", help="upload-speed probe (Mbps up)")
    sp_up.add_argument("--seconds", type=int, default=10)
    sp_up.add_argument("--progress-out", default=None,
                       help="append JSONL progress heartbeat (tail -f for long runs)")
    # Speed-cap mode: hold a fixed download rate for the whole window.
    sp_lim = sub.add_parser("limit", help="hold a fixed download rate (Mbps cap)")
    sp_lim.add_argument("--streams", type=int, default=1)
    sp_lim.add_argument("--seconds", type=int, default=10)
    sp_lim.add_argument("--progress-out", default=None,
                        help="append JSONL progress heartbeat (tail -f for long runs)")
    sp_lim.add_argument("--mbps", type=float, required=True,
                        help="target download rate in Mbps (0.5..10000)")
    sp_lim.add_argument("--strict", action="store_true",
                        help="system-wide kernel-enforced cap via dnctl+pf "
                             "(macOS, needs sudo) — shapes ALL traffic, "
                             "not just test downloads")
    sp_loss = sub.add_parser("loss", help="packet-loss percent")
    sp_loss.add_argument("--count", type=int, default=10)
    sp_jit = sub.add_parser("jitter", help="jitter (mean consecutive RTT delta)")
    sp_jit.add_argument("--count", type=int, default=10)
    sub.add_parser("wifi", help="WiFi RSSI/noise/channel")
    sp_exp = sub.add_parser("export", help="export newest run as CSV or JSON")
    sp_exp.add_argument("--fmt", choices=["csv", "json"], default="csv")
    sp_exp.add_argument("--out", required=True)

    # v0.5 modes
    sp_fetch = sub.add_parser("fetch", help="multi-stream download accelerator")
    sp_fetch.add_argument("url")
    sp_fetch.add_argument("out", nargs="?", help="output path (default: URL basename)")
    sp_fetch.add_argument("--streams", type=int, default=8)
    sp_fetch.add_argument("--adaptive", action="store_true", dest="adaptive",
                          help="auto-adjust stream count from latency/loss feedback")
    sp_bloat.add_argument("--eco", action="store_true", dest="eco",
                          help="small-probe estimate instead of full saturation")

    # AI analysis surface (P0–P2). One dispatcher so every analyser in
    # netmax_ai / netmax_ai_p1 / netmax_ai_p2 is reachable from the CLI,
    # the Tk GUI, the MCP server and the app bundle — otherwise a library
    # nobody can call is not a feature. Analysis only: never measures,
    # never mutates system state.
    sp_ai = sub.add_parser(
        "ai", help="AI-assisted diagnosis over supplied measurements")
    sp_ai.add_argument("--analysis", metavar="NAME",
                       help="analyser to run; --list-analyses shows them all")
    sp_ai.add_argument("--input", default="{}",
                       help="JSON object of measurements/history "
                            "(inline, or @path to a JSON file)")
    sp_ai.add_argument("--history", default="",
                       help="path to a history JSONL file to replay "
                            "(overrides --input history field)")
    sp_ai.add_argument("--pretty", action="store_true",
                       help="indent the JSON output")
    sp_ai.add_argument("--list-analyses", action="store_true",
                       help="print the available analysers and exit")

    # watch mode (v0.4 diagnostics; the dispatch branch at 'elif cmd == "watch"'
    # existed without this parser — register it so the mode actually runs).
    sp_watch = sub.add_parser("watch", help="continuous monitor (bloat+DNS per cycle)")
    sp_watch.add_argument("--interval", type=int, default=30,
                          help="seconds between cycles (default %(default)s)")
    sp_watch.add_argument("--cycles", type=int, default=10**9,
                          help="stop after N cycles (default: until Ctrl-C)")

    # W6-C2: load plugin modules (NETMAX_PLUGIN env) BEFORE parse so their
    # @plugin_mode decorators can add their own subparsers via
    # netmax.PLUGIN_MODES + this parser reference.
    _load_plugins()
    for pname, entry in PLUGIN_MODES.items():
        if pname not in {a.dest for a in parser._actions}:
            psp = sub.add_parser(pname, help=str(entry.get("help", "plugin mode")))
            extra_args = entry.get("arguments")
            if isinstance(extra_args, list):
                for pargs, pkwargs in extra_args:
                    psp.add_argument(*pargs, **pkwargs)

    args = parser.parse_args(argv)
    try:
        cmd = args.cmd
        _progress_begin(cmd, getattr(args, "progress_out", None))
        if cmd in PLUGIN_MODES:
            entry = PLUGIN_MODES[cmd]
            runner = entry.get("fn")
            if callable(runner):
                runner(args)
            else:
                print(f"netmax: plugin mode '{cmd}' has no callable fn", file=sys.stderr)
                sys.exit(1)
        elif cmd == "fetch":
            import netmax_fetch
            out_path = _safe_fetch_out(args.out, args.url)
            started = time.monotonic()

            def _show(done: int, total: int) -> None:
                pct = f"{done * 100 / total:.0f}%" if total else f"{done}B"
                print(f"\rfetching… {pct} ({done / 1e6:.1f} MB)", end="", flush=True)

            streams = _checked(args.streams, 1, 50, "--streams")
            if getattr(args, "adaptive", False):
                # Wire the dormant flag: one pre-download latency/loss probe;
                # AdaptiveController may step DOWN from the requested count
                # (never ramps mid-download — workers are fixed at start).
                try:
                    import netmax_throttle
                    ctrl = netmax_throttle.AdaptiveController(
                        min_streams=1, max_streams=streams,
                        initial_streams=streams,
                    )
                    latency_ms, loss_pct = netmax_throttle.measure_feedback()
                    streams = ctrl.feed(latency_ms, loss_pct)
                    print(f"\nadaptive: {streams} streams ({ctrl.reason})",
                          file=sys.stderr)
                except (NetMaxError, ValueError) as exc:
                    print(f"\nadaptive probe skipped ({exc}); "
                          f"using --streams {streams}", file=sys.stderr)

            stats = netmax_fetch.download(
                args.url, out_path,
                streams=streams,
                on_progress=_show,
            )
            elapsed = time.monotonic() - started
            print(f"\n✓ {out_path}: {stats['bytes'] / 1e6:.1f} MB in {elapsed:.1f}s "
                  f"({stats['mbps']:.1f} Mbps, {stats['streams_used']} streams)")
        elif cmd == "bloat-eco":
            import netmax_eco
            result = netmax_eco.eco_bloat()
            print(f"eco-bloat: +{result['delta_ms']:.1f} ms "
                  f"(estimated grade {result['grade_est']}, ~100 KB used)")
        elif cmd == "upload":
            import netmax_upload
            mbps, mb = netmax_upload.upload_probe(
                _checked_duration(args.seconds)
            )
            _hr("Upload probe")
            print(f"upload          {mbps:>7.1f} Mbps   ({mb:.1f} MB sent)")
        elif cmd == "limit":
            if getattr(args, "strict", False):
                import netmax_shape
                _mbps = _checked_mbps(args.mbps)
                _seconds = _checked_duration(args.seconds)
                try:
                    netmax_shape.require_root(_mbps)
                    _hr(f"Strict limit — system-wide ceiling at {_mbps:g} Mbps")
                    print("shaping ALL off-machine traffic via dnctl+pf "
                          "(loopback untouched); --streams is ignored in this mode.")
                    netmax_shape.hold(_mbps, _seconds)
                except netmax_shape.ShapeError as exc:
                    print(f"netmax: {exc}", file=sys.stderr)
                    sys.exit(1)
                print(f"cap window complete ({_seconds}s at {_mbps:g} Mbps ceiling); "
                      "pipe + anchor removed, pf restored.")
            else:
                run_limit(
                    _checked(args.streams, 1, 50, "--streams"),
                    _checked_duration(args.seconds),
                    _checked_mbps(args.mbps),
                    ai_governor=getattr(args, "ai_governor", False),
                )
        elif cmd == "loss":
            import netmetrics
            loss = netmetrics.packet_loss(count=_checked(args.count, 1, 100, "--count"))
            print(f"packet loss: {loss:.1f}%")
        elif cmd == "jitter":
            import netmetrics
            jit = netmetrics.jitter_ms(count=_checked(args.count, 1, 100, "--count"))
            print(f"jitter: {jit:.1f} ms")
        elif cmd == "wifi":
            import netmetrics
            info = netmetrics.wifi_info()
            for key, val in info.items():
                print(f"{key}: {val}")
        elif cmd == "export":
            import netmax_export
            netmax_export.export_results(args.fmt, args.out)
            print(f"exported ({args.fmt}) → {args.out}")
        elif cmd == "ai":
            if args.list_analyses:
                width = max(len(k) for k in AI_ANALYSES)
                for key, (mod, cls, method) in sorted(AI_ANALYSES.items()):
                    print(f"{key:<{width}}  {mod}.{cls}.{method}")
                return
            if not args.analysis:
                raise NetMaxError(
                    "ai needs --analysis NAME (or --list-analyses)")
            input_data = _load_json_input(args.input)
            history_rows = (_load_history(args.history)
                            if args.history else None)
            result = run_ai_analysis(args.analysis, input_data, history_rows)
            print(json.dumps(result, indent=2 if args.pretty else None,
                             default=str))
        elif cmd == "watch":
            import netmax_watch
            cycles = args.cycles if args.cycles > 0 else 10**9
            history = netmax_watch.watch_loop(
                interval_s=_checked(args.interval, 5, 3600, "--interval"),
                cycles=cycles,
            )
            summary = summarize_watch_history(history)
            _hr("Watch summary")
            for key, val in summary.items():
                print(f"{key}: {val}")
        else:
            runner_fn, takes_streams = RUNNERS[cmd]
            streams = _checked(args.streams, 1, 50, "--streams") if takes_streams else None
            seconds = (
                _checked_duration(args.seconds)
                if hasattr(args, "seconds")
                else None
            )
            if cmd == "dns":
                runner_fn()
            elif cmd == "baseline":
                runner_fn(seconds)
            else:
                runner_fn(streams, seconds)
    except KeyboardInterrupt:
        print("\ninterrupted — exiting.")
        sys.exit(130)
    except NetMaxError as exc:
        print(f"netmax: {exc}", file=sys.stderr)
        sys.exit(1)
    finally:
        _progress_end()


MODE_HELP = {
    "baseline": "single-stream throughput",
    "turbo": "N parallel streams — bigger share under load",
    "boost": "baseline + turbo + gain %%",
    "dns": "rank DNS resolvers",
    "bloat": "bufferbloat: latency under load grade",
    "full": "everything + verdict",
    "limit": "hold a fixed download rate (--mbps) for the window",
}


# ── watch mode helpers ────────────────────────────────────────────────────────

GRADE_ORDER = ["A+", "A", "B", "C", "D", "F"]


def format_watch_status(
    ts: str, cycle: int, delta_ms: float, grade: str,
    dns_name: str | None, dns_ms: float | None,
) -> str:
    """One-line status for a watch cycle — must never contain a newline."""
    dns_part = (
        f"fastest DNS {dns_name} @ {dns_ms:.1f}ms"
        if dns_name and dns_ms is not None
        else "no DNS answer"
    )
    return f"[{ts}] cycle {cycle}: bloat {delta_ms:+.1f}ms (grade {grade}), {dns_part}"


def summarize_watch_history(history: list[dict]) -> dict:
    """Aggregate a list of {delta_ms, grade, dns_ms} cycle records."""
    if not history:
        return {"cycles": 0}
    deltas = [h["delta_ms"] for h in history]
    dns_values = sorted(h["dns_ms"] for h in history if h.get("dns_ms") is not None)
    worst_idx = max(range(len(history)), key=lambda i: GRADE_ORDER.index(history[i]["grade"]))
    median_dns = (
        statistics.median(dns_values) if dns_values else None
    )
    return {
        "cycles": len(history),
        "worst_grade": history[worst_idx]["grade"],
        "max_delta_ms": max(deltas),
        "median_dns_ms": median_dns,
    }


if __name__ == "__main__":
    main()
