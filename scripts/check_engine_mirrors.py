#!/usr/bin/env python3
"""Engine mirror parity check (roadmap task C-08).

Root Python modules are canonical; desktop/engine/ holds byte-identical
mirrors that ship inside the macOS app bundle. Exits 0 when every
counterpart pair matches, and 1 with the exact module names on a
missing, extra, or byte-different counterpart.
"""
from __future__ import annotations

import sys
from pathlib import Path

# Canonical modules with a shipped mirror (roadmap C-08 write set).
MIRROR_MODULES = (
    "netmax.py",
    "netmax_ai.py",
    "netmax_ai_p1.py",
    "netmax_ai_p2.py",
    "netmax_ai_p4.py",
    "netmax_ai_provider.py",
    "netmax_audit.py",
    "netmax_eco.py",
    "netmax_endpoints.py",
    "netmax_export.py",
    "netmax_fetch.py",
    "netmax_history.py",
    "netmax_profiles.py",
    "netmax_retry.py",
    "netmax_schedule.py",
    "netmax_shape.py",
    "netmax_stats.py",
    "netmax_upload.py",
    "netmax_watch.py",
    "netmetrics.py",
)

ENGINE_DIR = ("desktop", "engine")


def check_mirrors(repo: Path) -> list[str]:
    """Return failure messages; an empty list means full parity."""
    failures: list[str] = []
    engine_dir = repo.joinpath(*ENGINE_DIR)
    for name in MIRROR_MODULES:
        canonical = repo / name
        mirror = engine_dir / name
        if not canonical.is_file():
            failures.append(f"missing canonical module: {name}")
        elif not mirror.is_file():
            failures.append(f"missing mirror module: desktop/engine/{name}")
        elif canonical.read_bytes() != mirror.read_bytes():
            failures.append(f"byte-different mirror: {name}")
    if engine_dir.is_dir():
        shipped = {p.name for p in engine_dir.glob("*.py")}
        for extra in sorted(shipped - set(MIRROR_MODULES)):
            failures.append(f"extra engine module without canonical pair: desktop/engine/{extra}")
    return failures


def main() -> int:
    repo = Path(__file__).resolve().parent.parent
    failures = check_mirrors(repo)
    if failures:
        print("engine mirror parity: FAIL", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1
    print(f"engine mirror parity: OK ({len(MIRROR_MODULES)} byte-identical pairs)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())