"""Endpoint registry + health probes for netmax speed/DNS targets.

Conventions follow netmax.py: ENDPOINTS is a list of (name, url-template)
pairs where ``{cb}`` marks a cache-buster substitution, and every network seam
is importable/patchable at module boundary so tests stay fully offline (see
tests/test_netmax_fetch.py).

Summaries degrade gracefully: malformed payloads collapse to zeroed counters
instead of raising (cf. netmax_watch.watch_loop's F-grade degradation).
"""

from __future__ import annotations

import json
import random
import urllib.request
from urllib.request import urlopen

# Mirrors netmax.ENDPOINTS: OVH leads (Cloudflare's bot layer adaptively 403s
# repeated hits), CF is the fallback. {cb} = cache-buster placeholder.
ENDPOINTS: list[tuple[str, str]] = [
    ("OVH", "https://proof.ovh.net/files/100Mb.dat"),
    ("Cloudflare", "https://speed.cloudflare.com/__down?bytes=50000000&cb={cb}"),
]

# Mirrors netmax.RESOLVERS: probe targets for DNS health checks.
DNS_SERVERS = {
    "Cloudflare 1.1.1.1": "1.1.1.1",
    "Google 8.8.8.8": "8.8.8.8",
    "Quad9 9.9.9.9": "9.9.9.9",
}


def health_check(endpoint, timeout=3.0) -> bool:
    """Probe one (name, url-template) endpoint; True iff HTTP reachable.

    Any failure — timeout, DNS, HTTP error, unparseable response — degrades
    to False rather than raising, so a broken endpoint never crashes a sweep.
    """
    _name, template = endpoint
    url = template.format(cb=random.getrandbits(64))
    req = urllib.request.Request(url)
    try:
        with urlopen(req, timeout=timeout):
            return True
    except Exception:
        return False


def summarize(results):
    """Aggregate probe results into an availability summary.

    Accepts a list of {"healthy": bool, ...} dicts, or a JSON str/bytes /
    {"results": [...]} wrapper thereof. Tolerant of malformed summaries per
    repo degradation convention: anything unparseable degrades to zeroed
    counters instead of raising (cf. netmax_watch.watch_loop's F-grade).
    """
    if isinstance(results, (str, bytes, bytearray)):
        results = _try_json_or_none(results)
    elif isinstance(results, dict):
        results = next(
            (v for v in results.values() if isinstance(v, list)), None)
    if not isinstance(results, list):
        results = []
    clean = [r for r in results if isinstance(r, dict)]
    total = len(clean)
    ok = sum(1 for r in clean if r.get("healthy"))
    return {"total": total, "ok": ok,
            "ratio": (ok / total) if total else 0.0}


def _try_json_or_none(data):
    try:
        parsed = json.loads(data)
    except Exception:
        return None
    return parsed if isinstance(parsed, list) else None
