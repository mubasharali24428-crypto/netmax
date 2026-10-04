"""Tests for the history normaliser.

Every fixture string below was CAPTURED FROM A LIVE RUN, not written from
memory. That is the point of this file: the bug it guards against was found
only by running the real engine, and synthetic fixtures had certified the
analysers as working while they read zero samples from production data.
"""

from __future__ import annotations

import json

import pytest

import netmax
import netmax_history as hist

# ── verbatim real output ─────────────────────────────────────────────────────
REAL = {
    "baseline": "single-stream   1 stream(s)     14.1 Mbps   (16 MB in 10s)",
    "loss": "packet loss: 0.0%",
    "jitter": "jitter: 64.3 ms",
    "bloat_eco": "eco-bloat: +0.0 ms (estimated grade A+, ~100 KB used)",
    "wifi": "rssi_dbm: -23\nnoise_dbm: -95\nchannel: 13",
    "dns": "1. Google 8.8.8.8          193.5 ms  ← fastest",
}


class TestRealFormatsExtract:
    @pytest.mark.parametrize("mode,text,field,expected", [
        ("baseline", REAL["baseline"], "mbps", 14.1),
        ("baseline", REAL["baseline"], "seconds", 10.0),
        ("loss", REAL["loss"], "loss_pct", 0.0),
        ("jitter", REAL["jitter"], "jitter_ms", 64.3),
        ("bloat_eco", REAL["bloat_eco"], "bloat_delta_ms", 0.0),
        ("bloat_eco", REAL["bloat_eco"], "bloat_grade", "A+"),
        ("wifi", REAL["wifi"], "rssi", -23.0),
        ("wifi", REAL["wifi"], "noise", -95.0),
        ("dns", REAL["dns"], "dns_ms", 193.5),
    ])
    def test_metric_is_found(self, mode, text, field, expected):
        assert hist.extract_metrics(text, mode).get(field) == expected

    def test_zero_loss_is_distinguished_from_absent(self):
        """0.0% is a real measurement, not a missing one."""
        assert hist.extract_metrics(REAL["loss"]).get("loss_pct") == 0.0

    def test_absent_metric_is_omitted_not_zeroed(self):
        out = hist.extract_metrics(REAL["baseline"])
        assert "loss_pct" not in out
        assert "jitter_ms" not in out

    def test_a_plus_grade_keeps_its_plus(self):
        """A trailing \\b would backtrack to bare "A" and lose the best grade."""
        assert hist.extract_metrics(REAL["bloat_eco"])["bloat_grade"] == "A+"

    def test_other_grades_still_match(self):
        for grade in ("A", "B", "C", "D", "E", "F"):
            assert hist.extract_metrics(f"grade {grade} x")["bloat_grade"] == grade

    def test_upload_never_becomes_download_throughput(self):
        """An upload rate read as `mbps` is a WRONG number, not a missing one."""
        out = hist.extract_metrics("upload: 6.2 Mbps", mode="baseline")
        assert "upload_mbps" not in out
        assert "mbps" not in out

    def test_upload_rate_is_found_in_an_upload_run(self):
        out = hist.extract_metrics("upload: 6.2 Mbps", mode="upload")
        assert out["upload_mbps"] == 6.2

    def test_garbage_text_yields_nothing(self):
        out = hist.extract_metrics("connection dropped mid-measurement", "baseline")
        assert not any(k in out for k in ("mbps", "loss_pct", "jitter_ms"))


class TestTimestamps:
    def test_iso8601_with_z(self):
        seconds, hour = hist.parse_timestamp("2026-10-04T07:50:12Z")
        assert seconds and hour == 7

    def test_iso8601_with_offset(self):
        seconds, hour = hist.parse_timestamp("2026-10-04T07:50:12+0000")
        assert seconds and hour == 7

    def test_unix_seconds(self):
        seconds, hour = hist.parse_timestamp(1_760_000_000)
        assert seconds and hour is not None

    def test_plain_date_string_is_not_an_epoch(self):
        """20261004 is a date, not a unix timestamp — do not guess."""
        assert hist.parse_timestamp("20261004") == (None, None)

    def test_absurd_number_is_not_an_epoch(self):
        assert hist.parse_timestamp(5) == (None, None)

    def test_none_and_empty(self):
        assert hist.parse_timestamp(None) == (None, None)
        assert hist.parse_timestamp("") == (None, None)

    def test_boolean_is_not_a_timestamp(self):
        assert hist.parse_timestamp(True) == (None, None)


class TestNormalize:
    def _record(self, mode, text, ts="2026-10-04T07:50:12Z", **params):
        return {"ts": ts, "mode": mode, "params": params,
                "result_raw": text}

    def test_real_record_becomes_a_flat_row(self):
        row = hist.normalize(self._record("baseline", REAL["baseline"]))
        assert row["mbps"] == 14.1
        assert row["mode"] == "baseline"
        assert row["hour"] == 7

    def test_streams_come_from_params(self):
        row = hist.normalize(
            self._record("turbo", REAL["baseline"], streams=8))
        assert row["streams"] == 8

    def test_already_flat_rows_pass_through(self):
        """Synthetic fixtures and hand-written history keep working."""
        row = hist.normalize({"mbps": 42.0, "loss_pct": 1.0})
        assert row["mbps"] == 42.0 and row["loss_pct"] == 1.0

    def test_boolean_values_are_not_coerced_to_numbers(self):
        row = hist.normalize({"mbps": True, "streams": 4})
        assert "mbps" not in row
        assert row["streams"] == 4

    def test_nan_is_dropped(self):
        row = hist.normalize({"mbps": float("nan")})
        assert "mbps" not in row

    def test_non_dict_is_ignored(self):
        assert hist.normalize("nope") == {}       # type: ignore[arg-type]


class TestCoherent:
    def test_merges_metrics_within_the_window(self):
        rows = hist.normalize_all([
            {"ts": 1_760_000_000, "mode": "baseline", "mbps": 14.1},
            {"ts": 1_760_000_030, "mode": "loss", "loss_pct": 0.0},
        ])
        merged = hist.build_coherent(rows)
        assert merged and merged[0]["mbps"] == 14.1
        assert merged[0]["loss_pct"] == 0.0

    def test_anchor_values_win_over_neighbours(self):
        rows = hist.normalize_all([
            {"ts": 1_760_000_000, "mbps": 14.1},
            {"ts": 1_760_000_010, "mbps": 99.0},
        ])
        merged = hist.build_coherent(rows)
        assert merged[0]["mbps"] == 14.1

    def test_distant_rows_do_not_merge(self):
        rows = hist.normalize_all([
            {"ts": 1_760_000_000, "mbps": 14.1},
            {"ts": 1_760_100_000, "mbps": 20.0},   # a day later
        ])
        merged = hist.build_coherent(rows)
        assert len(merged) == 2

    def test_rows_without_a_timestamp_are_dropped(self):
        assert hist.build_coherent([{"mbps": 10.0}]) == []

    def test_empty_input(self):
        assert hist.build_coherent([]) == []


class TestEndToEnd:
    """The bug this file exists for: analysers reading ZERO real samples."""

    def _history_file(self, tmp_path):
        records = [
            {"ts": f"2026-10-04T07:{m:02d}:00Z", "mode": mode,
             "params": {"streams": 4},
             "result_raw": REAL[mode]}
            for m, mode in enumerate(("baseline", "loss", "jitter",
                                      "bloat_eco", "wifi", "dns"), start=10)
        ]
        path = tmp_path / "real.jsonl"
        path.write_text("\n".join(json.dumps(r) for r in records),
                        encoding="utf-8")
        return str(path)

    def test_real_file_yields_flat_rows(self, tmp_path):
        rows = netmax._load_history(self._history_file(tmp_path))
        assert len(rows) == 6
        assert any(r.get("mbps") for r in rows)
        assert all("hour" in r for r in rows)

    def test_analyser_now_reads_real_samples(self, tmp_path, capsys):
        """Before the normaliser this returned samples: 0.

        Six real runs, but only the baseline measured throughput, so one
        sample is the correct answer. What matters is that it is one
        rather than zero — i.e. the normaliser found the real figure at all.
        """
        netmax.main(["ai", "--analysis", "forecast",
                     "--history", self._history_file(tmp_path)])
        out = json.loads(capsys.readouterr().out)
        assert out["samples"] == 1
        assert "insufficient_data" in out["trend"]      # honest: 1 < 8

    def test_time_series_rows_are_not_coalesced_away(self, tmp_path, capsys):
        """Coalescing for a trend analyser would collapse 6 rows into 1."""
        rows = netmax._load_history(self._history_file(tmp_path))
        assert len(rows) == 6                      # every run survives
        assert len({r["ts"] for r in rows}) == 6   # as distinct observations

    def test_root_cause_sees_a_real_jitter_finding(self, tmp_path, capsys):
        netmax.main(["ai", "--analysis", "root_cause",
                     "--history", self._history_file(tmp_path),
                     "--input", json.dumps({"diagnostics": {
                         "mbps": 14.1, "jitter_ms": 64.3, "loss_pct": 0.0}})])
        out = json.loads(capsys.readouterr().out)
        assert any(c["cause"] == "high_jitter" for c in out["causes"])

    def test_corrupt_lines_are_tolerated(self, tmp_path):
        path = tmp_path / "h.jsonl"
        path.write_text('{"mbps":1}\nJUNK\n\n{"mbps":2}\n', encoding="utf-8")
        assert len(netmax._load_history(str(path))) == 2

    def test_missing_file_is_reported(self):
        with pytest.raises(netmax.NetMaxError, match="not found"):
            netmax._load_history("/nonexistent/h.jsonl")
