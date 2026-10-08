"""Measurement Trust Report (Gate G-01).

A trust report is a 10-sample statistical report (median, p95, coefficient of
variation). The accepted rules:

1. EXACTLY 10 samples — fewer or more is rejected, not silently averaged.
2. Byte-identical JSON — identical inputs always serialize to identical bytes,
   via canonical JSON (sorted keys, fixed separators).
3. Every report carries a sha256 report_id over its canonical JSON.
"""

import hashlib
import json
import math
from typing import Any, Dict, Sequence

TRUST_REPORT_SAMPLES = 10
TRUST_REPORT_MAX_CV = 0.05


def generate_trust_report(
    samples: Sequence[float], endpoint: str, setup: str, units: str = "Mbps"
) -> Dict[str, Any]:
    """Generate a statistical trust report over exactly 10 measurement samples."""
    values = [float(s) for s in samples]
    if len(values) != TRUST_REPORT_SAMPLES:
        raise ValueError(
            f"Trust report requires exactly {TRUST_REPORT_SAMPLES} samples, "
            f"got {len(values)}"
        )

    n = len(values)
    ordered = sorted(values)
    median = (ordered[n // 2 - 1] + ordered[n // 2]) / 2.0

    # p95: nearest-rank method
    p95 = ordered[max(0, math.ceil(0.95 * n) - 1)]

    mean = sum(values) / n
    variance = sum((x - mean) ** 2 for x in values) / (n - 1)
    std = math.sqrt(variance)
    cv = (std / mean) if mean > 0 else 0.0

    report: Dict[str, Any] = {
        "samples": n,
        "median": median,
        "p95": p95,
        "cv": cv,
        "units": units,
        "endpoint": endpoint,
        "setup": setup,
        "qualified": cv <= TRUST_REPORT_MAX_CV,
    }
    report["report_id"] = report_id(report)
    return report


def report_to_json(report: Dict[str, Any]) -> str:
    """Serialize a trust report to canonical JSON.

    Sorted keys and fixed separators guarantee byte-identical output for
    identical reports, regardless of dict insertion order.
    """
    return json.dumps(report, sort_keys=True, separators=(",", ":"))


def report_id(report: Dict[str, Any]) -> str:
    """sha256 hex digest of the report canonical JSON (excludes report_id itself)."""
    payload = {k: v for k, v in report.items() if k != "report_id"}
    return hashlib.sha256(report_to_json(payload).encode("utf-8")).hexdigest()
