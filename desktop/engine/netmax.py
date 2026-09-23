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
import os
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

    UX-FIX (P0): the write-out now carries %{http_code} and the sample is
    accepted only when the server answered 2xx. Before this, a rate-limited
    429 with a tiny error body (curl exit 0, size_download=162) counted as
    "downloaded data" and fabricated throughput — a default 8-stream boost
    reported a bogus -56% headroom on a link with zero real headroom.
    """
    problems: list[str] = []
    for name, template in ENDPOINTS:
        url = template.format(cb=random.getrandbits(64))
        try:
            proc = subprocess.run(
                ["curl", "-sS", "-o", "/dev/null", "-w", "%{http_code} %{size_download}",
                 "--max-time", str(seconds), url],
                capture_output=True, text=True,
                timeout=seconds + 15,
            )
        except FileNotFoundError:
            raise NetMaxError("curl not found on PATH — install curl to measure") from None
        except subprocess.TimeoutExpired:
            problems.append(f"{name}: curl hung past subprocess timeout")
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
            continue
        # HTTP status must be 2xx — a 4xx/5xx body (rate-limit page, block
        # page, error JSON) is never throughput, whatever its size.
        if http_code is None or not 200 <= http_code < 300:
            problems.append(
                f"{name}: HTTP {http_code if http_code is not None else 'unparseable'} "
                f"({received}B body — not counted as data)"
            )
            continue
        if received > 0:
            return received
        problems.append(f"{name}: 2xx but empty body ({proc.stdout.strip()[:60]!r})")
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

    # v0.4 modes — separate parsers: different flag shapes than the core set.
    sp_bloat = sub.add_parser("bloat-eco", help="eco bufferbloat estimate (~100 KB)")
    sp_up = sub.add_parser("upload", help="upload-speed probe (Mbps up)")
    sp_up.add_argument("--seconds", type=int, default=10)
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


MODE_HELP = {
    "baseline": "single-stream throughput",
    "turbo": "N parallel streams — bigger share under load",
    "boost": "baseline + turbo + gain %%",
    "dns": "rank DNS resolvers",
    "bloat": "bufferbloat: latency under load grade",
    "full": "everything + verdict",
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
