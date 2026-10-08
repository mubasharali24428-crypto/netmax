"""Unit tests for netmax_retention CLI and atomic I/O routines."""
from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock
import pytest

import netmax_retention as ret


def _make_line(ts: datetime, mode: str = "baseline") -> str:
    return json.dumps({
        "ts": ts.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "mode": mode,
        "params": {},
        "result_raw": "{}",
    })


def test_load_lines_missing(tmp_path):
    missing = tmp_path / "missing.jsonl"
    with pytest.raises(ret.RetentionError, match="not found"):
        ret.load_lines(missing)


def test_load_lines_oserror(tmp_path):
    target = tmp_path / "hist.jsonl"
    target.write_text("line1\n", encoding="utf-8")
    with mock.patch.object(Path, "read_text", side_effect=OSError("disk error")):
        with pytest.raises(ret.RetentionError, match="cannot read"):
            ret.load_lines(target)


def test_load_lines_success(tmp_path):
    target = tmp_path / "hist.jsonl"
    target.write_text("line1\n\nline2  \n", encoding="utf-8")
    lines = ret.load_lines(target)
    assert lines == ["line1", "line2  "]


def test_atomic_rewrite_success(tmp_path):
    target = tmp_path / "hist.jsonl"
    target.write_text("old content\n", encoding="utf-8")
    ret.atomic_rewrite(target, ["new content 1", "new content 2"])
    assert target.read_text(encoding="utf-8") == "new content 1\nnew content 2\n"


def test_atomic_rewrite_mkstemp_failure(tmp_path):
    target = tmp_path / "hist.jsonl"
    with mock.patch("tempfile.mkstemp", side_effect=OSError("permission denied")):
        with pytest.raises(ret.RetentionError, match="cannot create tmp file"):
            ret.atomic_rewrite(target, ["line"])


def test_atomic_rewrite_replace_failure(tmp_path):
    target = tmp_path / "hist.jsonl"
    with mock.patch("os.replace", side_effect=OSError("cross-device link")):
        with pytest.raises(OSError, match="cross-device link"):
            ret.atomic_rewrite(target, ["line"])


def test_main_negative_days(tmp_path):
    target = tmp_path / "hist.jsonl"
    target.write_text("line\n", encoding="utf-8")
    with pytest.raises(SystemExit):
        ret.main([str(target), "--days", "-1"])


def test_main_missing_file(tmp_path):
    missing = tmp_path / "missing.jsonl"
    assert ret.main([str(missing)]) == 2


def test_main_small_file_refusal(tmp_path):
    target = tmp_path / "hist.jsonl"
    target.write_text("line1\n", encoding="utf-8")
    assert ret.main([str(target)]) == 2


def test_main_small_file_dry_run_allowed(tmp_path):
    target = tmp_path / "hist.jsonl"
    target.write_text("line1\n", encoding="utf-8")
    assert ret.main([str(target), "--dry-run"]) == 0


def test_main_small_file_with_force(tmp_path):
    target = tmp_path / "hist.jsonl"
    target.write_text("line1\n", encoding="utf-8")
    assert ret.main([str(target), "--force"]) == 0


def test_main_pruning_flow(tmp_path):
    target = tmp_path / "hist.jsonl"
    now = datetime.now(timezone.utc)
    old = _make_line(now - timedelta(days=200), mode="dns")
    recent = _make_line(now - timedelta(days=5), mode="dns")
    pinned = _make_line(now - timedelta(days=150), mode="wifi")
    # Generate 15 lines so len >= MIN_LINES (10)
    lines = [old] * 10 + [recent, pinned] + ["not json"] * 3
    target.write_text("\n".join(lines) + "\n", encoding="utf-8")

    assert ret.main([str(target), "--days", "30", "--dry-run"]) == 0
    assert ret.main([str(target), "--days", "30"]) == 0

    reloaded = ret.load_lines(target)
    assert len(reloaded) < len(lines)


def test_main_atomic_rewrite_oserror(tmp_path):
    target = tmp_path / "hist.jsonl"
    target.write_text("line\n" * 15, encoding="utf-8")
    with mock.patch("netmax_retention.atomic_rewrite", side_effect=OSError("write fail")):
        assert ret.main([str(target)]) == 2
