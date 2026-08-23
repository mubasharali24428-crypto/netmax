"""Offline tests for netmax_export (M2/E1). Pure filesystem via tmp_path."""

from __future__ import annotations

import csv
import json
from pathlib import Path

import pytest

import netmax
import netmax_export


def make_run(base: Path, ts: str, data: dict | None = None) -> Path:
    d = base / ts
    d.mkdir(parents=True)
    payload = data if data is not None else {
        "seconds": 5,
        "baseline_mbps": 120.5,
        "turbo8_mbps": 340.2,
        "baseline_mb": 75.3,
        "turbo8_mb": 212.6,
        "dropped": False,
        "dns": [["1.1.1.1", 12.3], ["8.8.8.8", 30.7]],
    }
    (d / "results.json").write_text(json.dumps(payload), encoding="utf-8")
    return d


@pytest.fixture
def results_base(tmp_path):
    base = tmp_path / "results"
    base.mkdir()
    return base


def test_newest_run_dir_picks_newest_with_results_json(results_base):
    make_run(results_base, "20260820_100000")
    newest = make_run(results_base, "20260821_120000")
    empty = results_base / "20260822_010000"
    empty.mkdir()  # newer but no results.json — must be skipped

    assert netmax_export.newest_run_dir(base_dir=results_base) == newest


def test_newest_run_dir_missing_dir_raises(tmp_path):
    with pytest.raises(netmax.NetMaxError):
        netmax_export.newest_run_dir(base_dir=tmp_path / "nope")


def test_newest_run_dir_no_runs_raises(tmp_path):
    (tmp_path / "results").mkdir()
    with pytest.raises(netmax.NetMaxError):
        netmax_export.newest_run_dir(base_dir=tmp_path / "results")


def test_export_csv_fixed_schema(results_base, tmp_path):
    make_run(results_base, "20260821_000000")
    out = tmp_path / "out.csv"
    netmax_export.export_results("csv", str(out), base_dir=results_base)

    rows = list(csv.reader(out.read_text(encoding="utf-8").splitlines()))
    assert rows[0] == netmax_export.CSV_COLUMNS
    assert len(rows) == 3  # header + one row per DNS resolver
    assert rows[1][-2:] == ["1.1.1.1", "12.3"]
    assert rows[2][-2:] == ["8.8.8.8", "30.7"]
    # scalar columns repeat per resolver row
    assert rows[1][2] == rows[2][2] == "120.5"


def test_export_csv_without_dns_writes_single_row(results_base, tmp_path):
    make_run(results_base, "20260821_000000", data={"seconds": 5})
    out = tmp_path / "out.csv"
    netmax_export.export_results("csv", str(out), base_dir=results_base)
    rows = list(csv.reader(out.read_text(encoding="utf-8").splitlines()))
    assert len(rows) == 2


def test_export_json_is_pretty_and_round_trips(results_base, tmp_path):
    data_dict = {"seconds": 5, "baseline_mbps": 99.9, "dns": []}
    make_run(results_base, "20260821_000000", data=data_dict)
    out = tmp_path / "out.json"
    netmax_export.export_results("json", str(out), base_dir=results_base)

    text = out.read_text(encoding="utf-8")
    assert "\n  " in text  # indented => pretty
    assert json.loads(text) == data_dict


def test_export_bad_format_raises(results_base, tmp_path):
    make_run(results_base, "20260821_000000")
    with pytest.raises(netmax.NetMaxError, match="unsupported format"):
        netmax_export.export_results("xml", str(tmp_path / "x.xml"), base_dir=results_base)


def test_export_corrupt_json_raises(results_base, tmp_path):
    bad = results_base / "20260821_000000"
    bad.mkdir()
    (bad / "results.json").write_text("{not json", encoding="utf-8")
    with pytest.raises(netmax.NetMaxError, match="corrupt"):
        netmax_export.export_results("csv", str(tmp_path / "x.csv"), base_dir=results_base)
