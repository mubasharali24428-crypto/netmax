"""History retention pruner (wave-2 BRAVO-B2-05) — trims the P2 history.jsonl.

The desktop app appends every run to a JSON Lines file (contract P2 record:
`{"ts": iso8601, "mode": str, "params": {...}, "result_raw": str}`). Left
alone that file grows forever, so this tool keeps the last `--days N`
(default 90) days of records and ALWAYS pins each mode's most recent record
(the current "verdict summary") regardless of age — every engine mode keeps
at least one reference point even if the machine sat idle for months.

Safety rules:
- rewrite is atomic: write a sibling tmp file, fsync, then `os.replace`;
- `--dry-run` only PRINTS the would-delete counts, touching nothing;
- files with fewer than MIN_LINES records are refused unless `--force`
  (a tiny file is usually a mispointed path, not real history);
- lines that fail to parse (or lack `ts`) are never classified as deletable —
  a pruner must not destroy bytes it cannot understand.

Stdlib only. CLI:
    python3 netmax_retention.py PATH [--days N] [--dry-run] [--force]
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

DEFAULT_DAYS = 90
MIN_LINES = 10


class RetentionError(Exception):
    """Fatal, user-facing retention problem (bad path, refused file, …)."""


def parse_ts(raw: object) -> datetime | None:
    """Parse an ISO8601 `ts` value to an aware UTC datetime, else None.

    Tolerates a trailing `Z` (pre-3.11 `fromisoformat` rejects it) and
    treats timezone-less stamps as UTC, matching HistoryStore's ISO8601
    encoder output (`2026-08-23T15:24:23Z`).
    """
    if not isinstance(raw, str) or not raw.strip():
        return None
    text = raw.strip()
    if text.endswith(("Z", "z")):
        text = text[:-1] + "+00:00"
    try:
        stamp = datetime.fromisoformat(text)
    except ValueError:
        return None
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=timezone.utc)
    return stamp.astimezone(timezone.utc)


@dataclass
class PrunePlan:
    """Which line indexes survive a prune, and why the rest go."""

    cutoff: datetime
    keep: list[int] = field(default_factory=list)
    drop: list[int] = field(default_factory=list)
    drop_modes: Counter = field(default_factory=Counter)
    unparsed_kept: int = 0
    pinned_modes: set[str] = field(default_factory=set)


def plan_prune(
    lines: list[str], *, days: int, now: datetime | None = None
) -> PrunePlan:
    """Classify every line as keep or drop without touching disk.

    A line survives if it is (a) unparseable — never destroy what we cannot
    judge, (b) inside the `days` window, or (c) its mode's NEWEST record
    (ties all pinned). Everything older than the window goes.
    """
    moment = now if now is not None else datetime.now(timezone.utc)
    cutoff = moment - timedelta(days=days)

    parsed: list[tuple[datetime | None, str | None]] = []
    for line in lines:
        try:
            record = json.loads(line)
        except ValueError:
            record = None
        if isinstance(record, dict):
            mode = record.get("mode")
            parsed.append(
                (parse_ts(record.get("ts")), mode if isinstance(mode, str) else None)
            )
        else:
            parsed.append((None, None))

    # Newest stamp per mode → the pinned "current verdict" per mode.
    newest: dict[str, datetime] = {}
    for stamp, mode in parsed:
        if stamp is None or mode is None:
            continue
        if mode not in newest or stamp > newest[mode]:
            newest[mode] = stamp

    plan = PrunePlan(cutoff=cutoff)
    for idx, (stamp, mode) in enumerate(parsed):
        if stamp is None:
            plan.keep.append(idx)
            plan.unparsed_kept += 1
        elif stamp >= cutoff:
            plan.keep.append(idx)
        elif mode is not None and newest.get(mode) == stamp:
            plan.keep.append(idx)
            plan.pinned_modes.add(mode)
        else:
            plan.drop.append(idx)
            plan.drop_modes[mode or "?"] += 1
    return plan


def load_lines(path: Path) -> list[str]:
    """Read the jsonl file into non-blank lines, preserving file order."""
    if not path.is_file():
        raise RetentionError(f"history file not found: {path}")
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise RetentionError(f"cannot read {path}: {exc}") from exc
    return [line for line in text.splitlines() if line.strip()]


def atomic_rewrite(path: Path, lines: list[str]) -> None:
    """Replace `path` with `lines` via tmp-file + fsync + os.replace.

    Same-directory tmp guarantees `os.replace` is atomic on POSIX; a crash
    mid-write leaves either the old file or the new one, never a half file.
    """
    parent = path.parent
    try:
        fd, tmp_name = tempfile.mkstemp(
            dir=str(parent), prefix=f".{path.name}.", suffix=".tmp"
        )
    except OSError as exc:
        raise RetentionError(f"cannot create tmp file in {parent}: {exc}") from exc
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            for line in lines:
                fh.write(line + "\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise


def _fmt_cutoff(plan: PrunePlan) -> str:
    return plan.cutoff.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def main(argv: list[str] | None = None) -> int:
    """CLI entry: returns the process exit code (0 ok, 2 refused/error)."""
    parser = argparse.ArgumentParser(
        prog="netmax_retention.py",
        description=(
            "Prune the P2 history.jsonl: keep the last --days days of records "
            "plus each mode's newest verdict summary, rewritten atomically."
        ),
    )
    parser.add_argument("history_file", help="path to history.jsonl")
    parser.add_argument(
        "--days",
        type=int,
        default=DEFAULT_DAYS,
        metavar="N",
        help=f"keep records newer than N days (default {DEFAULT_DAYS})",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="print would-delete counts only; never write",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="allow pruning files with fewer than MIN_LINES records",
    )
    args = parser.parse_args(argv)

    if args.days < 0:
        parser.error("--days must be >= 0")

    path = Path(args.history_file).expanduser()
    try:
        lines = load_lines(path)
    except RetentionError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    plan = plan_prune(lines, days=args.days)

    print(f"NetMax history retention — {path}")
    print(
        f"records: {len(lines)} | window: {args.days}d "
        f"(drop anything before {_fmt_cutoff(plan)})"
    )

    # Small-file guard: a near-empty file is usually a wrong path, not
    # history worth pruning. Dry-run is read-only, so it stays allowed;
    # the guard blocks only real rewrites.
    if len(lines) < MIN_LINES and not (args.dry_run or args.force):
        print(
            f"refusing to act: {len(lines)} records < {MIN_LINES} minimum "
            f"(pass --force to override)",
            file=sys.stderr,
        )
        return 2

    if plan.pinned_modes:
        print(
            f"pinned newest verdict per mode (kept regardless of age): "
            f"{', '.join(sorted(plan.pinned_modes))}"
        )
    if plan.unparsed_kept:
        print(f"kept {plan.unparsed_kept} unparseable/clockless line(s) untouched")

    drop_summary = ", ".join(
        f"{mode}={count}" for mode, count in sorted(plan.drop_modes.items())
    ) or "none"

    if args.dry_run:
        print(
            f"would delete {len(plan.drop)} old record(s): {drop_summary}"
        )
        print(f"dry run: kept {len(plan.keep)} / {len(lines)}; no file modified")
        return 0

    kept_lines = [lines[idx] for idx in sorted(plan.keep)]
    try:
        atomic_rewrite(path, kept_lines)
    except OSError as exc:
        print(f"error: atomic rewrite failed ({exc}); original left intact",
              file=sys.stderr)
        return 2
    print(f"deleted {len(plan.drop)} old record(s): {drop_summary}")
    print(f"kept {len(plan.keep)} / {len(lines)} records")
    print(f"atomically rewrote {path} (tmp + rename)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
