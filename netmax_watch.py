"""Watch mode: periodic bufferbloat + DNS checks with graceful degradation."""

import signal
import sys
import time

import netmax
from netmax import format_watch_status

MAX_CONSECUTIVE_FAILURES = 5


def watch_loop(
    interval_s: int,
    cycles: int,
    history: list[dict] | None = None,
    *,
    on_interrupt=None,
) -> list[dict]:
    """Run bloat_grade + dns_ranking every interval_s for up to cycles cycles.

    Appends {delta_ms, grade, dns_ms} per cycle to history (created if None)
    and returns it. SIGINT sets a flag for a clean exit and invokes
    on_interrupt (e.g. a daemon shutdown flag) when given. Stops early after
    MAX_CONSECUTIVE_FAILURES consecutive failed cycles.
    """
    if not isinstance(interval_s, int) or interval_s < 5:
        raise ValueError("interval_s must be an int >= 5")
    if not isinstance(cycles, int) or cycles < 1:
        raise ValueError("cycles must be an int >= 1")

    if history is None:
        history = []

    interrupted = False

    def _on_sigint(signum, frame):
        nonlocal interrupted
        interrupted = True
        if on_interrupt is not None:
            on_interrupt()

    prev_handler = signal.signal(signal.SIGINT, _on_sigint)

    consecutive_failures = 0
    try:
        for cycle in range(1, cycles + 1):
            try:
                _idle_ms, delta_ms, grade = netmax.bloat_grade(streams=4, seconds=6)
                dns_ms = None
                dns_name = None
                try:
                    ranking = netmax.dns_ranking()
                    if ranking:
                        dns_name, dns_ms = ranking[0]
                except netmax.NetMaxError:
                    pass
            except netmax.NetMaxError:
                delta_ms = 999.0
                grade = "F"
                dns_ms = None
                dns_name = None
                consecutive_failures += 1
            else:
                consecutive_failures = 0

            history.append({"delta_ms": delta_ms, "grade": grade, "dns_ms": dns_ms})
            print(format_watch_status(
                time.strftime("%H:%M:%S"), cycle, delta_ms, grade, dns_name, dns_ms,
            ), flush=True)

            if interrupted or consecutive_failures >= MAX_CONSECUTIVE_FAILURES:
                break
            if cycle < cycles:
                # Interruptible sleep: plain time.sleep resumes after SIGINT
                # under PEP 475, so Ctrl-C during a long interval could delay
                # exit up to interval_s (max 3600s). Poll the flag instead.
                slept = 0.0
                while slept < interval_s and not interrupted:
                    time.sleep(min(0.5, interval_s - slept))
                    slept += 0.5
                if interrupted:
                    break
    finally:
        signal.signal(signal.SIGINT, prev_handler)

    return history


if __name__ == "__main__":
    from netmax import summarize_watch_history

    hist = watch_loop(int(sys.argv[1]) if len(sys.argv) > 1 else 5,
                      int(sys.argv[2]) if len(sys.argv) > 2 else 10)
    print(summarize_watch_history(hist))
