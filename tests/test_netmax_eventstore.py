"""Offline tests for netmax_eventstore — contract TC3 JSONL store."""

import json
from datetime import datetime, timezone
from pathlib import Path

import pytest

import netmax_eventstore as es


@pytest.fixture()
def store_path(tmp_path: Path) -> Path:
    return tmp_path / "wifi_events.jsonl"


def _event(kind="roam", ts=None, **details):
    e = {"kind": kind, "details": details or {"ssid": "x"}}
    if ts is not None:
        e["ts"] = ts
    return e


class TestAppend:
    def test_creates_file_with_timestamped_event(self, store_path):
        assert es.append_event(_event(), path=store_path) is True
        assert store_path.is_file()
        rows = es.load_events(path=store_path)
        assert len(rows) == 1
        assert rows[0]["kind"] == "roam"
        # stamped ISO8601 Z
        assert rows[0]["ts"].endswith("Z")
        datetime.strptime(rows[0]["ts"], "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )

    def test_preserves_explicit_ts_string(self, store_path):
        ts = "2026-08-24T12:34:56Z"
        assert es.append_event(_event(ts=ts), path=store_path)
        assert es.load_events(path=store_path)[0]["ts"] == ts

    def test_non_string_ts_gets_stamped(self, store_path):
        assert es.append_event(_event(ts=12345), path=store_path)
        row = es.load_events(path=store_path)[0]
        assert row["ts"].endswith("Z")
        assert row["ts"] != "12345"

    def test_file_mode_is_0600(self, store_path):
        es.append_event(_event(), path=store_path)
        mode = store_path.stat().st_mode & 0o777
        assert mode == 0o600


class TestLoad:
    def test_missing_file_returns_empty(self, tmp_path):
        assert es.load_events(path=tmp_path / "nope.jsonl") == []

    def test_skips_corrupt_and_non_object_lines(self, store_path):
        store_path.write_text(
            "not json\n"
            + json.dumps(["list", "not", "dict"]) + "\n"
            + json.dumps({"kind": "roam"}) + "\n"  # missing details/ts
            + json.dumps(_event(ts="2026-01-01T00:00:00Z")) + "\n",
            encoding="utf-8",
        )
        rows = es.load_events(path=store_path)
        assert len(rows) == 1
        assert rows[0]["kind"] == "roam"

    def test_since_until_half_open(self, store_path):
        for ts in (
            "2026-01-01T00:00:00Z",
            "2026-06-01T00:00:00Z",
            "2026-12-01T00:00:00Z",
        ):
            es.append_event(_event(ts=ts), path=store_path)
        mid = es.load_events(
            since="2026-06-01T00:00:00Z",
            until="2026-12-01T00:00:00Z",
            path=store_path,
        )
        # [since, until) → mid included, end excluded
        assert [r["ts"] for r in mid] == ["2026-06-01T00:00:00Z"]

    def test_timezone_less_treated_as_utc(self, store_path):
        es.append_event(_event(ts="2026-06-01T00:00:00"), path=store_path)
        rows = es.load_events(since=datetime(2026, 6, 1, tzinfo=timezone.utc),
                              path=store_path)
        assert len(rows) == 1

    def test_bad_bound_raises(self, store_path):
        with pytest.raises(ValueError, match="ISO8601"):
            es.load_events(since="not-a-date", path=store_path)


class TestClear:
    def test_clear_removes_file(self, store_path):
        es.append_event(_event(), path=store_path)
        es.clear(path=store_path)
        assert not store_path.exists()
        assert es.load_events(path=store_path) == []

    def test_clear_missing_is_noop(self, store_path):
        es.clear(path=store_path)  # must not raise
