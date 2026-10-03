"""Tests for the `netmax ai` dispatcher (P0–P2 reachability).

An analyser library that nothing can call is not a feature. These tests pin
the one surface every other consumer goes through: the `ai` subcommand. The
argument-mapping table is asserted in full, because a signature typo there
fails at runtime on one analysis only.
"""

from __future__ import annotations

import json

import pytest

import netmax


class TestAiSubcommand:
    def test_list_analyses_works_without_a_name(self, capsys):
        netmax.main(["ai", "--list-analyses"])
        out = capsys.readouterr().out
        assert "root_cause" in out
        assert "netmax_ai_p2.ResultExplainer.explain" in out

    def test_missing_analysis_name_is_refused(self, capsys):
        with pytest.raises(SystemExit):
            netmax.main(["ai"])

    def test_unknown_analysis_names_the_fix(self, capsys):
        with pytest.raises(netmax.NetMaxError, match="list-analyses"):
            netmax.run_ai_analysis("nope", {})


class TestSignatureTable:
    def test_every_dispatch_target_declares_a_signature(self):
        assert set(netmax.AI_ANALYSES) == set(netmax.AI_SIGNATURES)

    def test_every_recorder_declares_its_fields(self):
        assert set(netmax.AI_RECORDERS) <= set(netmax.AI_RECORD_FIELDS)

    def test_all_analysers_resolve_to_a_real_class(self):
        import importlib
        for name, (module_name, class_name, method) in netmax.AI_ANALYSES.items():
            module = importlib.import_module(module_name)
            cls = getattr(module, class_name, None)
            assert cls is not None, f"{name}: {class_name} missing"
            assert callable(getattr(cls, method, None)), \
                f"{name}: {class_name}.{method} not callable"


class TestInputHandling:
    def test_inline_json_is_accepted(self):
        assert netmax._load_json_input('{"mbps": 40}') == {"mbps": 40}

    def test_at_prefix_reads_a_file(self, tmp_path):
        path = tmp_path / "in.json"
        path.write_text(json.dumps({"mbps": 12}), encoding="utf-8")
        assert netmax._load_json_input(f"@{path}") == {"mbps": 12}

    def test_bad_json_is_reported_clearly(self):
        with pytest.raises(netmax.NetMaxError, match="not valid JSON"):
            netmax._load_json_input("{nope}")

    def test_non_object_json_is_refused(self):
        with pytest.raises(netmax.NetMaxError, match="must be a JSON object"):
            netmax._load_json_input("[1,2,3]")

    def test_empty_input_defaults_to_empty_object(self):
        assert netmax._load_json_input("") == {}

    def test_missing_history_file_is_reported(self):
        with pytest.raises(netmax.NetMaxError, match="not found"):
            netmax._load_history("/nonexistent/nope.jsonl")

    def test_history_tolerates_corrupt_lines(self, tmp_path):
        path = tmp_path / "h.jsonl"
        path.write_text('{"mbps":10}\nGARBAGE\n\n{"mbps":20}\n', encoding="utf-8")
        assert netmax._load_history(str(path)) == [{"mbps": 10}, {"mbps": 20}]


class TestDispatch:
    """One case per signature shape — the three ways input can arrive."""

    def test_nested_bundle_key(self):
        out = netmax.run_ai_analysis(
            "explain", {"diagnostics": {"mbps": 40}, "plan_mbps": 100})
        assert "you say you pay for" in " ".join(out["statements"])

    def test_flat_form_becomes_the_bundle(self):
        out = netmax.run_ai_analysis("explain", {"mbps": 40})
        assert out["statements"]

    def test_scalar_only_signature_takes_no_positional(self):
        out = netmax.run_ai_analysis("chunk_size", {"rtt_ms": 100, "jitter_ms": 1})
        assert out["chunk_bytes"] > 0

    def test_zero_arg_signature(self):
        out = netmax.run_ai_analysis("throttle_signature", {})
        assert "throttle_detected" in out

    def test_options_are_not_duplicated_as_bundle_keys(self):
        # streams exists both as a scalar option and would be the payload —
        # passing it twice is the bug this shape originally had.
        out = netmax.run_ai_analysis(
            "allocate_streams",
            {"streams": 4, "aggregate_bps": 1_000_000,
             "per_stream_bps": [9e7, 1e7, 5e6, 1e6]})
        assert sum(out["shares_bps"]) == pytest.approx(1_000_000)

    def test_unknown_input_keys_are_ignored_not_fatal(self):
        out = netmax.run_ai_analysis(
            "explain", {"mbps": 40, "totally_unknown": "ignored"})
        assert out["statements"]

    def test_bad_input_surfaces_as_netmax_error(self):
        with pytest.raises(netmax.NetMaxError):
            netmax.run_ai_analysis("metric_rule", {"rule": "__import__('os')"})


class TestHistoryReplay:
    def _history(self, tmp_path, rows):
        path = tmp_path / "hist.jsonl"
        path.write_text("\n".join(json.dumps(r) for r in rows), encoding="utf-8")
        return netmax._load_history(str(path))

    def test_forecast_replays_a_series(self, tmp_path):
        rows = [{"mbps": 90 - i} for i in range(20)]
        out = netmax.run_ai_analysis("forecast", {}, self._history(tmp_path, rows))
        assert out["samples"] == 20
        assert out["trend"] == "declining"

    def test_hardware_health_replays_grades(self, tmp_path):
        rows = ([{"bloat_grade": "A+", "idle_latency_ms": 10}] * 6
                + [{"bloat_grade": "D", "idle_latency_ms": 12}] * 6)
        out = netmax.run_ai_analysis(
            "hardware_health", {}, self._history(tmp_path, rows))
        assert out["verdict"] == "degrading"

    def test_isp_profile_replays_hours(self, tmp_path):
        rows = ([{"mbps": 95.0, "hour": h} for h in (2, 3, 4)] * 3
                + [{"mbps": 28.0, "hour": h} for h in (19, 20, 21)] * 3)
        out = netmax.run_ai_analysis("isp_profile", {}, self._history(tmp_path, rows))
        assert out["shaping_detected"] is True
        assert 19 in out["peak_hours"]

    def test_throttle_signature_replays_stream_counts(self, tmp_path):
        rows = [{"mbps": m, "streams": s} for s, m in
                [(1, 20), (2, 39), (4, 42), (8, 30), (16, 12)]]
        out = netmax.run_ai_analysis(
            "throttle_signature", {}, self._history(tmp_path, rows))
        assert out["throttle_detected"] is True

    def test_rows_missing_fields_are_skipped_not_fatal(self, tmp_path):
        rows = [{"unrelated": 1}, {"mbps": 50}, {"mbps": None}]
        out = netmax.run_ai_analysis("forecast", {}, self._history(tmp_path, rows))
        assert out["samples"] == 1
