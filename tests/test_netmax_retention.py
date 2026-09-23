"""Offline tests for netmax_retention — history.jsonl pruner."""

import json
from datetime import datetime, timedelta, timezone

import pytest

import netmax_retention as ret


def _line(ts: datetime, mode="baseline", **params):
    return json.dumps(
        {
            "ts": ts.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "mode": mode,
            "params": params,
            "result_raw": "{}",
        }
    )


NOW = datetime(2026, 9, 23, tzinfo=timezone.utc)


class TestParseTs:
    def test_z_suffix(self):
        dt = ret.parse_ts("2026-08-24T12:34:56Z")
        assert dt == datetime(2026, 8, 24, 12, 34, 56, tzinfo=timezone.utc)

    def test_timezone_less_is_utc(self):
        dt = ret.parse_ts("2026-08-24T12:34:56")
        assert dt.tzinfo is not None
        assert dt.utcoffset() == timedelta(0)

    @pytest.mark.parametrize("bad", [None, "", "  ", 42, "not-a-date"])
    def test_invalid_returns_none(self, bad):
        assert ret.parse_ts(bad) is None


class TestPlanPrune:
    def test_old_dropped_recent_kept(self):
        old = _line(NOW - timedelta(days=200), mode="dns")
        mid = _line(NOW - timedelta(days=10), mode="dns")
        plan = ret.plan_prune([old, mid], days=90, now=NOW)
        assert plan.drop == [0]
        assert plan.keep == [1]

    def test_unparseable_never_dropped(self):
        junk = "not json"
        plan = ret.plan_prune([junk], days=90, now=NOW)
        assert plan.keep == [0]
        assert plan.unparsed_kept == 1

    def test_each_mode_pins_most_recent_even_if_old(self):
        # only record for mode is ancient → still pinned
        ancient = _line(NOW - timedelta(days=400), mode="wifi")
        plan = ret.plan_prune([ancient], days=90, now=NOW)
        assert plan.keep == [0]
        assert "wifi" in plan.pinned_modes

    def test_old_non_pinned_dropped_when_newer_same_mode_exists(self):
        old = _line(NOW - timedelta(days=400), mode="baseline")
        new = _line(NOW - timedelta(days=1), mode="baseline")
        plan = ret.plan_prune([old, new], days=90, now=NOW)
        assert plan.keep == [1]
        assert plan.drop == [0]
