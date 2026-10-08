import json
import os

import pytest

from netmax_local_regression import (
    check_regression_alert,
    check_regression_from_history,
    dismiss_regression_alert,
    get_regression_state,
    load_metric_series,
    set_regression_disabled,
)


def test_regression_needs_20_samples():
    assert not check_regression_alert([100.0] * 19, 50.0)


def test_regression_3_consecutive_breaches():
    # 20 samples, last 3 are high latency (100 > 50)
    samples = [10.0] * 17 + [100.0, 100.0, 100.0]
    assert check_regression_alert(samples, threshold=50.0, is_latency=True)


def test_regression_no_alert_if_not_consecutive():
    samples = [10.0] * 16 + [100.0, 10.0, 100.0, 100.0]
    assert not check_regression_alert(samples, threshold=50.0, is_latency=True)


@pytest.fixture()
def history_file(tmp_path):
    # 20 baseline rows + 3 breaching rows (latency metric "jitter_ms").
    rows = [
        {"ts": 1700000000 + i, "result_raw": f"jitter 10.0 ms, Download: 95 Mbps"}
        for i in range(20)
    ]
    rows += [
        {"ts": 1700001000 + i, "result_raw": f"jitter 100.0 ms, Download: 95 Mbps"}
        for i in range(3)
    ]
    path = tmp_path / "history.jsonl"
    path.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
    return str(path)


@pytest.fixture()
def state_file(tmp_path, monkeypatch):
    path = str(tmp_path / "regression_state.json")
    monkeypatch.setenv("NETMAX_REGRESSION_STATE", path)
    return path


def test_load_metric_series_reads_history(history_file):
    series = load_metric_series("jitter_ms", history_path=history_file)
    assert len(series) == 20  # limit=20 keeps the most recent
    assert series[-3:] == [100.0, 100.0, 100.0]
    assert series[0] == 100.0 or series[0] == 10.0  # last 20 of 23 rows


def test_check_regression_from_history_fires(history_file, state_file):
    result = check_regression_from_history(
        "jitter_ms", threshold=50.0, is_latency=True, history_path=history_file
    )
    assert result["alert"] is True
    assert result["suppressed"] is False
    assert result["samples"] == 20


def test_check_regression_from_history_no_alert_without_breach(tmp_path, state_file):
    rows = [
        {"ts": 1700000000 + i, "result_raw": "jitter 10.0 ms"} for i in range(20)
    ]
    path = tmp_path / "clean.jsonl"
    path.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
    result = check_regression_from_history(
        "jitter_ms", threshold=50.0, is_latency=True, history_path=str(path)
    )
    assert result["alert"] is False
    assert result["reason"] == "no regression detected"


def test_dismiss_suppresses_alert(history_file, state_file):
    dismiss_regression_alert(hours=24)
    result = check_regression_from_history(
        "jitter_ms", threshold=50.0, is_latency=True, history_path=history_file
    )
    assert result["alert"] is False
    assert result["suppressed"] is True
    assert "dismissed until" in result["reason"]


def test_dismiss_requires_positive_window(state_file):
    with pytest.raises(ValueError):
        dismiss_regression_alert(hours=0)


def test_disable_suppresses_alert(history_file, state_file):
    set_regression_disabled(True)
    assert get_regression_state()["disabled"] is True
    result = check_regression_from_history(
        "jitter_ms", threshold=50.0, is_latency=True, history_path=history_file
    )
    assert result["alert"] is False
    assert result["suppressed"] is True
    assert result["reason"] == "regression alerting is disabled"
    set_regression_disabled(False)
    result = check_regression_from_history(
        "jitter_ms", threshold=50.0, is_latency=True, history_path=history_file
    )
    assert result["alert"] is True


def test_state_file_is_0600(state_file):
    set_regression_disabled(False)
    assert os.stat(state_file).st_mode & 0o777 == 0o600


def test_corrupt_state_is_treated_as_default(tmp_path, monkeypatch):
    path = tmp_path / "bad.json"
    path.write_text("not json{{")
    monkeypatch.setenv("NETMAX_REGRESSION_STATE", str(path))
    assert get_regression_state() == {"disabled": False, "dismissed_until": None}
