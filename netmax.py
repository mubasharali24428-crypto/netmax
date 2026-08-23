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
import random
import re
import socket
import statistics
import string
import struct
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

CF_DOWN = "https://speed.cloudflare.com/__down"
# Primary/backup sources. Cloudflare's bot layer adaptively 403-blocks
# repeated hits from one client (returns a 1-byte body that reads as ~0 Mbps),
# so OVH's static test file leads and CF is the fallback. {cb} = cache-buster.
ENDPOINTS: list[tuple[str, str]] = [
    ("OVH", "https://proof.ovh.net/files/100Mb.dat"),
    ("Cloudflare", f"{CF_DOWN}?bytes=50000000&cb={{cb}}"),
]
RESOLVERS = {
    "Cloudflare 1.1.1.1": "1.1.1.1",
    "Google 8.8.8.8": "8.8.8.8",
    "Quad9 9.9.9.9": "9.9.9.9",
}


class NetMaxError(RuntimeError):
    """A measurement could not be completed."""


# ── throughput ────────────────────────────────────────────────────────────────

def _pull(seconds: float) -> int:
    """Download via curl until the time cap; return bytes received.

    Tries each endpoint in order until one delivers data; raises NetMaxError
    with per-endpoint diagnostics if none do. Exit code 28 (curl timeout) is
    expected here — every file is far larger than the window by design.
    """
    problems: list[str] = []
    for name, template in ENDPOINTS:
        url = template.format(cb=random.getrandbits(64))
        proc = subprocess.run(
            ["curl", "-sS", "-o", "/dev/null", "-w", "%{size_download}",
             "--max-time", str(seconds), url],
            capture_output=True, text=True,
        )
        try:
            received = int(proc.stdout.strip())
        except ValueError:
            received = 0
            body_hint = proc.stdout.strip()[:120]
        else:
            body_hint = None
        # curl exit 28 = our own time cap (expected); 0 = clean finish.
        # Anything else (TLS reset, HTTP error, DNS fail) invalidates even a
        # partial byte count — counting it would fabricate throughput.
        if received > 0 and proc.returncode in (0, 28):
            return received
        detail = proc.stderr.strip() or (
            f"curl exit {proc.returncode} after {received}B"
            if proc.returncode not in (0, 28)
            else f"unparseable body: {body_hint!r}" if body_hint
            else f"http body {received}B"
        )
        problems.append(f"{name}: {detail}")
    raise NetMaxError("all speed endpoints failed — " + "; ".join(problems))


def throughput(streams: int, seconds: float) -> tuple[float, float]:
    """Open `streams` parallel pulls; return (aggregate Mbps, total MB moved)."""
    started = time.monotonic()
    with ThreadPoolExecutor(max_workers=streams) as pool:
        futures = [pool.submit(_pull, seconds) for _ in range(streams)]
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
    except socket.timeout as exc:
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


def dns_ranking() -> list[tuple[str, float]]:
    """Rank resolvers by median RTT; unfit resolvers are skipped, not fatal."""
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
    return sorted(rows, key=lambda row: row[1])


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
        print("connection dropped mid-measurement — rerun once the link is stable.")
        return
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
    """Median RTT via system ping; raises NetMaxError if ping fails."""
    proc = subprocess.run(
        ["ping", "-c", str(count), host], capture_output=True, text=True
    )
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


# ── CLI ───────────────────────────────────────────────────────────────────────

def _checked(value: int, low: int, high: int, flag: str) -> int:
    if not low <= value <= high:
        raise NetMaxError(f"{flag} must be {low}..{high}, got {value}")
    return value


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

    args = parser.parse_args(argv)
    try:
        runner_fn, takes_streams = RUNNERS[args.cmd]
        streams = _checked(args.streams, 1, 32, "--streams") if takes_streams else None
        seconds = (
            _checked(args.seconds, 5, 30, "--seconds")
            if hasattr(args, "seconds")
            else None
        )
        if args.cmd == "dns":
            runner_fn()
        elif args.cmd == "baseline":
            runner_fn(seconds)
        else:
            runner_fn(streams, seconds)
    except NetMaxError as exc:
        print(f"netmax: {exc}", file=sys.stderr)
        sys.exit(1)


MODE_HELP = {
    "baseline": "single-stream throughput",
    "turbo": "N parallel streams — bigger share under load",
    "boost": "baseline + turbo + gain %%",
    "dns": "rank DNS resolvers",
    "bloat": "bufferbloat: latency under load grade",
    "full": "everything + verdict",
}


if __name__ == "__main__":
    main()
