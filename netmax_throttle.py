"""Adaptive stream controller (M3/F2) — mission-3-graph.md contract.

`AdaptiveController` backs off one stream-step when latency > 300 ms or
loss > 2%, ramps up one step after 3 consecutive quiet checks
(latency <= 150 ms and loss <= 0.5%), and clamps to [min_streams, max_streams].
`.reason` always holds a short human-readable description of the last decision.

`measure_feedback` shells out to ping once and reuses netmetrics' parsing
helpers (imported, never copied).
"""

from __future__ import annotations

import statistics

import netmetrics


class AdaptiveController:
    """Latency/loss-aware stream-count governor."""

    BACKOFF_LATENCY_MS = 300.0
    BACKOFF_LOSS_PCT = 2.0
    QUIET_LATENCY_MS = 150.0
    QUIET_LOSS_PCT = 0.5
    QUIET_STREAK_NEEDED = 3

    def __init__(self, min_streams: int = 2, max_streams: int = 16):
        if min_streams < 1:
            raise ValueError("min_streams must be >= 1")
        if max_streams < min_streams:
            raise ValueError("max_streams must be >= min_streams")
        self.min_streams = min_streams
        self.max_streams = max_streams
        self._streams = min_streams
        self._quiet_streak = 0
        self.reason = "init"

    def current(self) -> int:
        return self._streams

    def reset(self) -> None:
        self._streams = self.min_streams
        self._quiet_streak = 0
        self.reason = "reset"

    def feed(self, latency_ms: float, loss_pct: float) -> int:
        """Feed one probe result; update the stream count and .reason."""
        bad_latency = latency_ms > self.BACKOFF_LATENCY_MS
        bad_loss = loss_pct > self.BACKOFF_LOSS_PCT
        if bad_latency or bad_loss:
            self._quiet_streak = 0
            if self._streams > self.min_streams:
                self._streams -= 1
                why = []
                if bad_latency:
                    why.append(f"latency {latency_ms:.1f}ms > {self.BACKOFF_LATENCY_MS:.0f}ms")
                if bad_loss:
                    why.append(f"loss {loss_pct:.2f}% > {self.BACKOFF_LOSS_PCT:.1f}%")
                self.reason = "backoff: " + ", ".join(why)
            else:
                self.reason = (
                    f"backoff blocked at min ({self.min_streams}): "
                    + (f"latency {latency_ms:.1f}ms" if bad_latency else "")
                    + (" and " if bad_latency and bad_loss else "")
                    + (f"loss {loss_pct:.2f}%" if bad_loss else "")
                )
            return self._streams

        if latency_ms <= self.QUIET_LATENCY_MS and loss_pct <= self.QUIET_LOSS_PCT:
            self._quiet_streak += 1
            if self._quiet_streak >= self.QUIET_STREAK_NEEDED:
                if self._streams < self.max_streams:
                    self._streams += 1
                    self._quiet_streak = 0
                    self.reason = (
                        f"ramp up after {self.QUIET_STREAK_NEEDED} quiet checks "
                        f"(latency {latency_ms:.1f}ms, loss {loss_pct:.2f}%)"
                    )
                else:
                    self.reason = (
                        f"ramp blocked at max ({self.max_streams}); "
                        f"{self.QUIET_STREAK_NEEDED} quiet checks"
                    )
            else:
                self.reason = (
                    f"holding at {self._streams}; "
                    f"quiet streak {self._quiet_streak}/{self.QUIET_STREAK_NEEDED}"
                )
            return self._streams

        # Not bad enough to back off, not quiet enough to count toward ramp.
        self._quiet_streak = 0
        self.reason = (
            f"hold at {self._streams}: latency {latency_ms:.1f}ms, "
            f"loss {loss_pct:.2f}% (noisy)"
        )
        return self._streams


def measure_feedback(host: str = "1.1.1.1", count: int = 3) -> tuple[float, float]:
    """(median RTT in ms, packet-loss percent) from one ping run.

    Reuses netmetrics' command runner (`_run`) and parses the single ping
    output packet_loss-style (same summary/RTT line formats).
    """
    import re

    proc = netmetrics._run(["ping", "-c", str(count), host], timeout=count * 5 + 15)
    m = re.search(r"(\d+(?:\.\d+)?)% packet loss", proc.stdout)
    if not m:
        raise netmetrics.NetMaxError(
            f"ping to {host} produced no loss statistics: "
            f"{(proc.stderr or '').strip()[:120] or 'no output'}"
        )
    times = [float(t) for t in re.findall(r"time=(\d+(?:\.\d+)?)\s*ms", proc.stdout)]
    if not times:
        raise netmetrics.NetMaxError(f"no RTT samples from ping to {host}")
    return statistics.median(times), float(m.group(1))
