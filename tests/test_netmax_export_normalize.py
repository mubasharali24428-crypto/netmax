"""Offline tests for netmax_export_normalize — canonical CSV rows."""

import json

import netmax_export_normalize as en


class TestToRecords:
    def test_flat_results_single_row(self):
        rows = en.to_records(
            [
                {
                    "timestamp": "2026-09-01T00:00:00Z",
                    "mode": "boost",
                    "baseline_mbps": 10.0,
                    "turbo8_mbps": 20.0,
                    "gain_pct": 100.0,
                }
            ]
        )
        assert len(rows) == 1
        assert rows[0]["mode"] == "boost"
        # cells are CSV-rendered (floats → str, .0 trimmed)
        assert rows[0]["gain_pct"] == "100"
        assert rows[0]["baseline_mbps"] == "10"
        assert rows[0]["dns_resolver"] == ""

    def test_history_jsonl_string_result_raw(self):
        raw = json.dumps({"baseline_mbps": 15.0, "mode": "boost"})
        rows = en.to_records(
            [
                {
                    "ts": "2026-09-01T00:00:00Z",
                    "mode": "boost",
                    "params": {"streams": 8, "seconds": 10},
                    "result_raw": raw,
                }
            ]
        )
        assert rows[0]["streams"] == "8"
        assert rows[0]["seconds"] == "10"
        assert rows[0]["baseline_mbps"] == "15"

    def test_params_win_over_result_raw_scalars(self):
        raw = json.dumps({"streams": 1})
        rows = en.to_records(
            [{"ts": "2026-09-01T00:00:00Z", "params": {"streams": 8},
              "result_raw": raw}]
        )
        assert rows[0]["streams"] == "8"

    def test_dns_pair_list_fans_out(self):
        rows = en.to_records(
            [
                {
                    "ts": "2026-09-01T00:00:00Z",
                    "mode": "dns",
                    "result_raw": json.dumps(
                        {"dns": [["1.1.1.1", 12.3], ["8.8.8.8", 20.0]]}
                    ),
                }
            ]
        )
        assert len(rows) == 2
        assert rows[0]["dns_resolver"] == "1.1.1.1"
        assert rows[0]["dns_ms"] == "12.3"
        assert rows[1]["dns_resolver"] == "8.8.8.8"
        assert rows[1]["baseline_mbps"] == rows[0]["baseline_mbps"]

    def test_dns_dict_mapping_sorted(self):
        rows = en.to_records(
            [
                {
                    "ts": "2026-09-01T00:00:00Z",
                    "result_raw": json.dumps(
                        {"dns": {"8.8.8.8": 20.0, "1.1.1.1": 12.0}}
                    ),
                }
            ]
        )
        assert [r["dns_resolver"] for r in rows] == ["1.1.1.1", "8.8.8.8"]
        assert rows[0]["dns_ms"] == "12"
        assert rows[1]["dns_ms"] == "20"

    def test_gain_computed_when_missing(self):
        rows = en.to_records(
            [
                {
                    "ts": "2026-09-01T00:00:00Z",
                    "baseline_mbps": 10.0,
                    "turbo8_mbps": 15.0,
                }
            ]
        )
        assert rows[0]["gain_pct"] == "50"

    def test_gain_empty_when_inputs_missing(self):
        rows = en.to_records([{"ts": "2026-09-01T00:00:00Z"}])
        assert rows[0]["gain_pct"] == ""


class TestToCsv:
    def test_stable_header_and_empty_cells(self):
        csv_text = en.to_csv(
            [
                {
                    "timestamp": "2026-09-01T00:00:00Z",
                    "mode": "dns",
                    "dns_resolver": "1.1.1.1",
                    "dns_ms": 12.0,
                },
                {"timestamp": "2026-09-01T01:00:00Z", "mode": "baseline"},
            ]
        )
        lines = csv_text.strip().splitlines()
        assert lines[0] == ",".join(en.COLUMNS)
        # second row: empty dns cells, no column shift
        header = lines[0].split(",")
        row2 = lines[2].split(",")
        assert len(row2) == len(header)
        assert row2[header.index("mode")] == "baseline"
        assert row2[header.index("dns_resolver")] == ""
        assert row2[header.index("dns_ms")] == ""

    def test_bools_lowercase(self):
        rows = en.to_records([{"timestamp": "t", "dropped": True}])
        assert rows[0]["dropped"] == "true"
        rows = en.to_records([{"timestamp": "t", "dropped": False}])
        assert rows[0]["dropped"] == "false"
