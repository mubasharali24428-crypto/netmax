"""Jittered exponential-backoff retry helper.

retry(fn, attempts=3, base=0.5, cap=8.0) calls fn until it succeeds or the
attempt budget is spent, sleeping between attempts. Delay before the n-th
retry is base * 2^(n-1) capped at `cap`, with full jitter drawn from
[0, raw] to avoid synchronized thundering herds.

`sleep` is injectable for tests (pass e.g. ``sleep=delays.append``); `rng`
is injectable for deterministic delay assertions.
"""

from __future__ import annotations

import random
import time


def backoff(attempt: int, base: float = 0.5, cap: float = 8.0,
            rng=random.uniform) -> float:
    """Sleep duration before the `attempt`-th retry (1-indexed)."""
    raw = min(cap, base * 2 ** (attempt - 1))
    return rng(0, raw)


def retry(fn, attempts=3, base=0.5, cap=8.0, *, sleep=time.sleep,
          rng=random.uniform):
    """Call fn(), retrying with jittered exponential backoff on failure.

    Returns fn()'s first successful result; re-raises the last exception
    once the attempt budget is exhausted. attempts < 1 is rejected up front
    with ValueError.
    """
    if attempts < 1:
        raise ValueError("attempts must be >= 1")
    for attempt in range(1, attempts + 1):
        try:
            return fn()
        except Exception:
            if attempt == attempts:
                raise
            sleep(backoff(attempt, base, cap, rng))
