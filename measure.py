#!/usr/bin/env python3
"""Measure live throughput + DNS, save results.json and render results.png."""

from __future__ import annotations

import json
import statistics
import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import netmax  # noqa: E402

try:
    import matplotlib  # noqa: E402

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt  # noqa: E402
    HAVE_MPL = True
except ImportError:  # optional chart extra (pyproject [project.optional-dependencies] charts)
    plt = None
    HAVE_MPL = False

HEADER, ACCENT, MUTED, CARD = "#1F2635", "#7C5A9B", "#8A93A6", "#FFFFFF"
SECONDS = 8
RESULTS_DIR = Path(__file__).resolve().parent / "results"
HISTORY_FILE = RESULTS_DIR / "history.json"


def append_history(mode: str, summary: dict, *, timestamp: str | None = None,
                   history_file: Path = HISTORY_FILE) -> dict:
    """Append one run's {timestamp, mode, results} entry to history.json.

    Creates the file (and its parent dir) if missing; prior entries are kept.
    """
    if timestamp is None:
        timestamp = datetime.now().isoformat(timespec="seconds")
    entry = {"timestamp": timestamp, "mode": mode, "results": summary}
    history_file.parent.mkdir(parents=True, exist_ok=True)
    try:
        with open(history_file, encoding="utf-8") as fh:
            history = json.load(fh)
        if not isinstance(history, list):
            history = []
    except (FileNotFoundError, json.JSONDecodeError):
        history = []
    history.append(entry)
    with open(history_file, "w", encoding="utf-8") as fh:
        json.dump(history, fh, indent=2)
    return entry


def main() -> None:
    out_dir = RESULTS_DIR / datetime.now().strftime("%Y%m%dT%H%M%S")
    out_dir.mkdir(parents=True, exist_ok=True)
    rounds = 3
    base_samples, turbo_samples = [], []
    base_mb_total, turbo_mb_total = 0.0, 0.0
    for i in range(rounds):
        # alternate order each round so link drift cancels out (proper A/B)
        if i % 2 == 0:
            mbps, mb = netmax.throughput(1, SECONDS)
            base_samples.append(mbps); base_mb_total += mb
            mbps, mb = netmax.throughput(8, SECONDS)
            turbo_samples.append(mbps); turbo_mb_total += mb
        else:
            mbps, mb = netmax.throughput(8, SECONDS)
            turbo_samples.append(mbps); turbo_mb_total += mb
            mbps, mb = netmax.throughput(1, SECONDS)
            base_samples.append(mbps); base_mb_total += mb

    base_mbps = statistics.median(base_samples)
    turbo_mbps = statistics.median(turbo_samples)
    dns = netmax.dns_ranking()

    dropped = base_mbps <= 0.5 or turbo_mbps <= 0.5
    data = {
        "seconds": SECONDS,
        "baseline_mbps": round(base_mbps, 2),
        "turbo8_mbps": round(turbo_mbps, 2),
        "baseline_mb": round(base_mb_total, 1),
        "turbo8_mb": round(turbo_mb_total, 1),
        "dropped": dropped,
        "dns": [(name, round(ms, 1)) for name, ms in dns],
    }
    with open(out_dir / "results.json", "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)

    if not HAVE_MPL:
        # No chart extra installed — the measurement itself is complete;
        # results.json + history carry everything. Skip the PNG honestly.
        append_history("full", data)
        print(json.dumps(data, indent=2))
        print("note: matplotlib unavailable — skipped results.png "
              "(pip install netmax[charts] to render)", file=sys.stderr)
        return

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(11, 4.2), dpi=130)
    fig.patch.set_facecolor(CARD)

    labels = ["Baseline\n1 stream", "Turbo\n8 streams"]
    values = [base_mbps, turbo_mbps]
    colors = [MUTED, ACCENT]
    bars = ax1.bar(labels, values, color=colors, width=0.55, zorder=3)
    ax1.set_ylim(0, max(values, default=1) * 1.30)   # reserve top strip for annotation
    ax1.set_title(
        f"Throughput — live WiFi (median of {rounds} alternating rounds × {SECONDS}s)",
        color=HEADER, fontsize=12, fontweight="bold",
    )
    ax1.set_ylabel("Mbps", color=HEADER)
    ax1.grid(axis="y", color="#E3E6EB", zorder=0)
    for spine in ("top", "right"):
        ax1.spines[spine].set_visible(False)
    ax1.tick_params(colors=HEADER)
    for bar, val in zip(bars, values):
        ax1.annotate(
            f"{val:.1f}", xy=(bar.get_x() + bar.get_width() / 2, val),
            xytext=(0, 4), textcoords="offset points",
            ha="center", color=HEADER, fontsize=11, fontweight="bold",
        )
    if not dropped and base_mbps > 0:
        gain = (turbo_mbps / base_mbps - 1) * 100
        ax1.text(0.5, 0.98, f"headroom unlocked: {gain:+.0f}%",
                 transform=ax1.transAxes, ha="center", va="top",
                 color=ACCENT, fontsize=11, fontweight="bold")
    elif dropped:
        ax1.text(0.5, 0.5, "link dropped mid-run —\nrerun when stable",
                 transform=ax1.transAxes, ha="center", va="center",
                 color=MUTED, fontsize=11, style="italic")

    names = [name for name, _ in dns][::-1]
    latencies = [ms for _, ms in dns][::-1]
    bar_colors = [ACCENT if n == min(dns, key=lambda d: d[1])[0] else MUTED for n in names]
    ax2.barh(names, latencies, color=bar_colors, height=0.55, zorder=3)
    ax2.set_title("DNS resolver latency (median)", color=HEADER,
                  fontsize=12, fontweight="bold")
    ax2.set_xlabel("ms", color=HEADER)
    ax2.grid(axis="x", color="#E3E6EB", zorder=0)
    for spine in ("top", "right"):
        ax2.spines[spine].set_visible(False)
    ax2.tick_params(colors=HEADER)

    fig.tight_layout()
    fig.savefig(out_dir / "results.png", facecolor=CARD, bbox_inches="tight")
    append_history("full", data)
    print(json.dumps(data, indent=2))


if __name__ == "__main__":
    main()
