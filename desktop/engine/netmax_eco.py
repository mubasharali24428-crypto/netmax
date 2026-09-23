#!/usr/bin/env python3
"""netmax_eco — data-frugal diagnostics (Mission 3 / E2).

Same verdicts as the full probes, ~99% less data.

Data budget per call
--------------------
eco_bloat(host, probe_kb):
    ping traffic:   negligible (<1 KB, ICMP only)
    download:       exactly `probe_kb` KiB = probe_kb * 1024 bytes
                    (default 100 KB; the full bloat test moves tens of MB)
    TOTAL ≈ probe_kb KB + <1 KB.  With defaults: ~101 KB per call.
eco_dns():
    one UDP query per resolver (4 resolvers incl. system path),
    each packet well under 100 B → <0.5 KB per call.
"""

from __future__ import annotations

import subprocess
from concurrent.futures import ThreadPoolExecutor

import netmax


def _grade_est(delta_ms: float) -> str:
    """Estimate a bloat grade from a latency delta using netmax's rubric."""
    for limit, grade in netmax.BLOAT_GRADES:
        if delta_ms < limit:
            return grade
    return "F"


def eco_bloat(host: str = "1.1.1.1", probe_kb: int = 100) -> dict:
    """Bufferbloat estimate with a tiny probe instead of full saturation.

    Measures idle median ping latency, downloads only `probe_kb` KiB from
    Cloudflare's speed endpoint via curl (a short burst — NOT saturation),
    pings again during that burst, and returns:

        {"delta_ms": <float>, "grade_est": <str>}

    Raises netmax.NetMaxError if curl is missing or the download fails.

    Data budget: ~probe_kb KB downloaded (+<1 KB of ping traffic).
    """
    idle_ms = netmax._ping_median_ms(host)

    url = f"{netmax.CF_DOWN}?bytes={probe_kb * 1024}"

    def _pull_probe() -> None:
        try:
            proc = subprocess.run(
                ["curl", "-sS", "-o", "/dev/null", "-f",
                 "--max-time", "10", url],
                capture_output=True, text=True,
            )
        except FileNotFoundError as exc:
            raise netmax.NetMaxError(
                "curl not found — cannot run eco probe"
            ) from exc
        if proc.returncode != 0:
            raise netmax.NetMaxError(
                f"eco probe download failed (exit {proc.returncode}): "
                f"{proc.stderr.strip()[:120]}"
            )

    # Ping DURING the short download burst (not full saturation, but enough
    # to excite any shallow queue).
    with ThreadPoolExecutor(max_workers=1) as pool:
        future = pool.submit(_pull_probe)
        try:
            loaded_ms = netmax._ping_median_ms(host, count=3)
        finally:
            future.result()
    delta_ms = max(loaded_ms - idle_ms, 0.0)
    return {"delta_ms": delta_ms, "grade_est": _grade_est(delta_ms)}


def eco_dns() -> list[tuple[str, float]]:
    """Rank DNS resolvers with ONE attempt each (data-frugal).

    Light re-implementation of netmax.dns_ranking: dns_ranking() is not
    parameterizable, so this calls netmax._median_rtt_ms directly with
    attempts=1. Unfit resolvers are skipped, not fatal. Returns
    [(name, rtt_ms), ...] sorted fastest-first.
    """
    rows: list[tuple[str, float]] = []
    try:
        rows.append(("System default", netmax._median_rtt_ms(None, attempts=1)))
    except netmax.NetMaxError:
        pass
    for label, ip in netmax.RESOLVERS.items():
        try:
            rows.append((label, netmax._median_rtt_ms(ip, attempts=1)))
        except netmax.NetMaxError as exc:
            print(f"   ({label} skipped — {exc})")
    if not rows:
        raise netmax.NetMaxError("no DNS resolver reachable")
    return sorted(rows, key=lambda row: row[1])
