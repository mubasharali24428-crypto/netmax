"""Export a measurement run's results.json to CSV or pretty JSON (M2/E1)."""

from __future__ import annotations

import csv
import json
from pathlib import Path

import netmax

RESULTS_BASE = Path(__file__).resolve().parent / "results"

# Fixed column schema per spec: one row per DNS resolver, scalar fields repeated.
CSV_COLUMNS = [
    "timestamp",
    "seconds",
    "baseline_mbps",
    "turbo8_mbps",
    "baseline_mb",
    "turbo8_mb",
    "dropped",
    "dns_resolver",
    "dns_ms",
]


def newest_run_dir(base_dir: Path | None = None) -> Path:
    """Return the newest results/<ts>/ directory containing results.json.

    Raises netmax.NetMaxError if the base dir is missing or no run has a
    results.json.
    """
    base = RESULTS_BASE if base_dir is None else Path(base_dir)
    if not base.is_dir():
        raise netmax.NetMaxError(f"results directory not found: {base}")
    candidates = sorted(
        (d for d in base.iterdir() if d.is_dir()),
        key=lambda d: d.name,
    )
    for d in reversed(candidates):
        if (d / "results.json").is_file():
            return d
    raise netmax.NetMaxError(f"no runs with results.json under {base}")


def export_results(fmt: str, out_path: str, base_dir: Path | None = None) -> None:
    """Export the newest run's results.json as 'csv' or 'json' to out_path."""
    run_dir = newest_run_dir(base_dir=base_dir)
    try:
        data = json.loads((run_dir / "results.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise netmax.NetMaxError(
            f"corrupt results.json in {run_dir}: {exc}"
        ) from exc

    fmt = fmt.lower().strip().lstrip(".")
    if fmt == "csv":
        _write_csv(data, Path(out_path))
    elif fmt in ("json", "pretty", "pretty-json"):
        Path(out_path).write_text(
            json.dumps(data, indent=2) + "\n", encoding="utf-8"
        )
    else:
        raise netmax.NetMaxError(f"unsupported format {fmt!r}: use csv or json")


def _write_csv(data: dict, out_path: Path) -> None:
    scalars = {
        col: data.get(col, "") for col in CSV_COLUMNS if col not in ("dns_resolver", "dns_ms")
    }
    dns = data.get("dns") or [("", "")]
    with open(out_path, "w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(CSV_COLUMNS)
        for name, ms in dns:
            row = dict(scalars)
            row["dns_resolver"] = name
            row["dns_ms"] = ms
            writer.writerow([row[col] for col in CSV_COLUMNS])
