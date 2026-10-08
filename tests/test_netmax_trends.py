"""Unit tests for netmax_trends.py (history record trend analysis)."""
from __future__ import annotations

import json
from datetime import datetime, timezone
import pytest

import netmax_trends as nt


def test_supported_metrics():
    assert "mbps" in nt.SUPPORTED_METRICS
    assert "loss" in nt.SUPPORTED_METRICS
    assert "jitter" in nt.SUPPORTED_METRICS
    assert "loaded_increase" in nt.SUPPORTED_METRICS


def test_extract_series_invalid_metric():
    with pytest.raises(ValueError, match="unknown metric"):
        nt.extract_series([], "unsupported_metric")


def test_extract_series_json_payloads():
    records = [
        {"ts": "2026-10-01T10:00:00Z", "result_raw": json.dumps({"mbps": 105.5})},
        {"ts": "2026-10-01T10:05:00Z", "result_raw": {"down_mbps": "98.2"}},
        {"ts": 1700000000, "result_raw": {"bandwidth_mbps": 120}},
        {"ts": "2026-10-01T10:15:00Z", "resultRaw": {"speed_mbps": 110.0}},
        {"ts": "bad-record", "result_raw": None},
        "not a valid json string {",
        {"ts": "2026-10-01T10:20:00Z", "result_raw": {"loss_pct": 0.5}},
    ]
    series = nt.extract_series(records, "mbps")
    assert len(series) == 4
    assert series[0][1] == 105.5
    assert series[1][1] == 98.2
    assert series[2][1] == 120.0
    assert series[3][1] == 110.0


def test_extract_series_tagged_text():
    records = [
        {"ts": "2026-10-01T10:00:00Z", "result_raw": "download: 45.2 Mbps"},
        {"ts": "2026-10-01T10:01:00Z", "result_raw": "12.5% packet loss"},
        {"ts": "2026-10-01T10:02:00Z", "result_raw": "jitter: 7.5 ms"},
        {"ts": "2026-10-01T10:03:00Z", "result_raw": "loaded increase: +58.2 ms"},
        {"ts": "2026-10-01T10:04:00Z", "result_raw": "3.2 ms jitter"},
        {"ts": "2026-10-01T10:05:00Z", "result_raw": "mdev = 4.810 ms"},
        {"ts": "2026-10-01T10:06:00Z", "result_raw": "latency increased by 42 ms"},
        {"ts": "2026-10-01T10:07:00Z", "result_raw": '{"delta_ms": 15.4}'},
    ]
    assert nt.extract_series(records, "mbps")[0][1] == 45.2
    assert nt.extract_series(records, "loss")[0][1] == 12.5
    jitters = nt.extract_series(records, "jitter")
    assert [v for _, v in jitters] == [7.5, 3.2, 4.810]
    bloats = nt.extract_series(records, "loaded_increase")
    assert [v for _, v in bloats] == [58.2, 42.0, 15.4]


def test_embedded_and_nested_json():
    nested = [
        {"ts": "2026-10-01T10:00:00Z", "result_raw": {"nested": [{"speed_mbps": 50.0}]}},
        {"ts": "2026-10-01T10:01:00Z", "result_raw": {"envelope": {"raw": "jitter = 2.1ms"}}},
        {"ts": "2026-10-01T10:02:00Z", "result_raw": 42.0},
    ]
    assert nt.extract_series(nested, "mbps")[0][1] == 50.0
    assert nt.extract_series(nested, "jitter")[0][1] == 2.1
    assert nt.extract_series(nested, "mbps")[1][1] == 42.0


def test_parse_ts_variations():
    dt = datetime(2026, 10, 1, 12, 0, 0, tzinfo=timezone.utc)
    assert nt._parse_ts(dt) == dt
    assert isinstance(nt._parse_ts(1700000000), datetime)
    assert nt._parse_ts(1e25) == 1e25  # overflow fallback
    parsed_iso = nt._parse_ts("2026-10-01T12:00:00Z")
    assert isinstance(parsed_iso, datetime)
    parsed_lower_z = nt._parse_ts("2026-10-01T12:00:00z")
    assert isinstance(parsed_lower_z, datetime)
    assert nt._parse_ts("not-a-date") == "not-a-date"
    assert nt._parse_ts(None) is None


def test_coerce_number():
    assert nt._coerce_number(True) is None
    assert nt._coerce_number(False) is None
    assert nt._coerce_number(42) == 42.0
    assert nt._coerce_number(3.14) == 3.14
    assert nt._coerce_number(" 99.5 ") == 99.5
    assert nt._coerce_number("abc") is None
    assert nt._coerce_number(object()) is None


def test_rolling_median():
    with pytest.raises(ValueError, match="window must be an int >= 1"):
        nt.rolling_median([], 0)
    with pytest.raises(ValueError, match="window must be an int >= 1"):
        nt.rolling_median([], -2)
    with pytest.raises(ValueError, match="window must be an int >= 1"):
        nt.rolling_median([], True)
    with pytest.raises(ValueError, match="window must be an int >= 1"):
        nt.rolling_median([], 1.5)  # type: ignore

    pts = [("t1", 10.0), ("t2", 20.0), ("t3", 30.0), ("t4", 100.0)]
    unchanged = nt.rolling_median(pts, 1)
    assert [v for _, v in unchanged] == [10.0, 20.0, 30.0, 100.0]

    rolled = nt.rolling_median(pts, 3)
    # i=0: [10] -> 10
    # i=1: [10, 20] -> 15
    # i=2: [10, 20, 30] -> 20
    # i=3: [20, 30, 100] -> 30
    assert [v for _, v in rolled] == [10.0, 15.0, 20.0, 30.0]


def test_deltas():
    assert nt.deltas([]) == []
    assert nt.deltas([("t1", 10.0)]) == []
    pts = [("t1", 10.0), ("t2", 15.5), ("t3", 12.0)]
    d = nt.deltas(pts)
    assert d == [("t2", 5.5), ("t3", -3.5)]


def test_anomalies():
    assert nt.anomalies([]) == []

    # Series with continuous drift and one outlier spike (mad > 0)
    pts = [
        ("t0", 1.0),
        ("t1", 2.0),
        ("t2", 3.0),
        ("t3", 4.0),
        ("t4", 5.0),
        ("t5", 100.0),  # anomaly
        ("t6", 6.0),
        ("t7", 7.0),
        ("t8", 8.0),
    ]
    flags = nt.anomalies(pts, k=3.0, window=3)
    assert flags == [(5, "t5", 100.0)]

    # Flat series where MAD == 0
    flat_pts = [("t1", 10.0), ("t2", 10.0), ("t3", 10.0), ("t4", 50.0), ("t5", 10.0)]
    flat_flags = nt.anomalies(flat_pts, k=3.0, window=3)
    assert any(idx == 3 and val == 50.0 for idx, _, val in flat_flags)


def test_edge_cases_depth_and_types():
    # depth < 0 in _find_json_value
    assert nt._find_json_value({"mbps": 10}, ("mbps",), depth=-1) is None
    # depth < 0 in _find_embedded_text
    assert nt._find_embedded_text({"raw": "10 ms"}, "jitter", depth=-1) is None
    # non-dict in _payload_of
    assert nt._payload_of(12345) == (None, None)
    # embedded list in _find_embedded_text
    assert nt._find_embedded_text([{"k": "mdev = 3.5 ms"}], "jitter") == 3.5
