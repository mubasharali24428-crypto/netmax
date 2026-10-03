"""Tests for P3 items 35 (predictive scheduling) and 45 (power-aware).

Both are pure policy functions, so every case here runs offline. The
convergence logic for item 44 is tested in test_netmax_adaptive.py.
"""

from __future__ import annotations

import json

import pytest

import netmax
import netmax_schedule as sched


class TestPowerPolicy:
    def test_ac_power_changes_nothing(self):
        p = sched.power_policy(sched.PowerState(on_ac=True, source="ac"))
        assert p.run is True
        assert p.duration_scale == 1.0
        assert p.interval_scale == 1.0
        assert p.skip_modes == []

    def test_full_battery_changes_nothing(self):
        p = sched.power_policy(
            sched.PowerState(on_ac=False, source="battery", percent=95.0))
        assert p.duration_scale == 1.0
        assert p.run is True

    def test_low_battery_halves_duration_and_polls_less(self):
        p = sched.power_policy(
            sched.PowerState(on_ac=False, source="battery", percent=15.0))
        assert p.run is True
        assert p.duration_scale == 0.5
        assert p.interval_scale == 2.0

    def test_critical_battery_defers(self):
        p = sched.power_policy(
            sched.PowerState(on_ac=False, source="battery", percent=8.0))
        assert p.run is False
        assert "deferring" in p.reason

    def test_critical_battery_still_runs_when_forced(self):
        p = sched.power_policy(
            sched.PowerState(on_ac=False, source="battery", percent=8.0),
            forced=True)
        assert p.run is True
        # Forced does NOT mean "ignore the hardware" — duration still drops.
        assert p.duration_scale == 0.5

    def test_kernel_shaper_is_skipped_on_battery(self):
        """A pf/dnctl pipe is CPU work; it is the wrong cost on battery."""
        p = sched.power_policy(
            sched.PowerState(on_ac=False, source="battery", percent=15.0))
        assert "limit_strict" in p.skip_modes

    def test_low_power_mode_trims_but_does_not_defer(self):
        p = sched.power_policy(sched.PowerState(
            on_ac=False, source="battery", percent=60.0, low_power_mode=True))
        assert p.run is True
        assert p.duration_scale < 1.0

    def test_unknown_level_on_battery_is_conservative_not_blocking(self):
        p = sched.power_policy(sched.PowerState(on_ac=False, source="battery"))
        assert p.run is True
        assert p.interval_scale > 1.0
        assert "unknown" in p.reason

    def test_unknown_state_blocks_nothing(self):
        """An unreadable power state must not silently stop scheduled runs."""
        p = sched.power_policy(sched.PowerState())
        assert p.run is True


class TestApplyPolicy:
    def test_resolves_scaled_numbers(self):
        p = sched.power_policy(
            sched.PowerState(on_ac=False, source="battery", percent=15.0))
        out = sched.apply_policy(p, seconds=10, interval_s=30)
        assert out["seconds"] == 5
        assert out["interval_s"] == 60
        assert out["run"] is True

    def test_skips_a_flagged_mode(self):
        p = sched.power_policy(
            sched.PowerState(on_ac=False, source="battery", percent=15.0))
        out = sched.apply_policy(p, seconds=10, mode="limit_strict")
        assert out["skipped_mode"] is True
        assert out["run"] is False

    def test_scaling_never_reaches_zero_or_below_floor(self):
        p = sched.power_policy(
            sched.PowerState(on_ac=False, source="battery", percent=8.0))
        out = sched.apply_policy(p, seconds=1, interval_s=5)
        assert out["seconds"] >= 1
        assert out["interval_s"] >= 5


class TestPredictWindows:
    def _rows(self):
        return ([{"mbps": 95.0, "hour": h} for h in (2, 3, 4)] * 4
                + [{"mbps": 28.0, "hour": h} for h in (19, 20, 21)] * 4)

    def test_finds_the_quiet_hour(self):
        out = sched.predict_windows(self._rows())
        hours = [w["hour"] for w in out["windows"]]
        assert 2 in hours
        assert out["verdict"] == "recommendation"

    def test_finds_the_busy_hour_when_the_gap_matters(self):
        out = sched.predict_windows(self._rows())
        hours = [w["hour"] for w in out["windows"]]
        assert 19 in hours
        assert out["gap_pct"] > 100

    def test_refuses_on_thin_data(self):
        out = sched.predict_windows([{"mbps": 50.0, "hour": 3}])
        assert out["verdict"] == "insufficient_data"
        assert out["windows"] == []

    def test_no_gap_means_no_busy_window(self):
        rows = [{"mbps": 80.0 + h, "hour": h} for h in range(8) for _ in range(3)]
        out = sched.predict_windows(rows)
        assert out["verdict"] == "recommendation"
        assert len(out["windows"]) < 4
        assert any("does not matter" in n for n in out["notes"])

    def test_ignores_non_numeric_mbps(self):
        rows = [{"mbps": "fast", "hour": h} for h in range(6) for _ in range(3)]
        out = sched.predict_windows(rows)
        assert out["verdict"] == "insufficient_data"

    def test_ignores_booleans(self):
        # bool is an int subclass; True must not become 1.0 Mbps.
        rows = [{"mbps": True, "hour": h} for h in range(6) for _ in range(3)]
        assert sched.predict_windows(rows)["verdict"] == "insufficient_data"

    def test_falls_back_to_timestamp_for_the_hour(self):
        # Three distinct hours at >= MIN_SAMPLES_PER_HOUR each, since the
        # analyser refuses to speak from fewer.
        base = 1735689600  # 2025-01-01 00:00 UTC
        rows = []
        for offset_hours, mbps in ((0, 95.0), (6, 90.0), (18, 30.0)):
            rows += [{"mbps": mbps, "ts": base + offset_hours * 3600}
                     for _ in range(4)]
        out = sched.predict_windows(rows)
        assert out["verdict"] == "recommendation"
        assert len({w["hour"] for w in out["windows"]}) >= 2

    def test_windows_are_sorted(self):
        out = sched.predict_windows(self._rows())
        hours = [w["hour"] for w in out["windows"]]
        assert hours == sorted(hours)


class TestHistoryLoading:
    def test_tolerates_corrupt_lines(self, tmp_path):
        path = tmp_path / "h.jsonl"
        path.write_text('{"mbps":1}\nJUNK\n\n{"mbps":2}\n', encoding="utf-8")
        assert len(sched.load_history(str(path))) == 2

    def test_missing_file_raises(self):
        with pytest.raises(FileNotFoundError):
            sched.load_history("/nonexistent/h.jsonl")


class TestPlanSubcommand:
    def test_battery_percentage_is_accepted(self, capsys):
        netmax.main(["plan", "--battery", "15"])
        out = json.loads(capsys.readouterr().out)
        assert out["power"]["state"]["percent"] == 15.0
        assert out["power"]["policy"]["duration_scale"] == 0.5

    def test_ac_shortcut(self, capsys):
        netmax.main(["plan", "--battery", "ac"])
        out = json.loads(capsys.readouterr().out)
        assert out["power"]["state"]["source"] == "ac"
        assert out["power"]["resolved"]["run"] is True

    def test_bogus_battery_is_refused(self, capsys):
        # main() reports NetMaxError on stderr and exits 1.
        with pytest.raises(SystemExit) as exc:
            netmax.main(["plan", "--battery", "flat"])
        assert exc.value.code == 1
        assert "--battery" in capsys.readouterr().err

    def test_forced_overrides_deferral(self, capsys):
        netmax.main(["plan", "--battery", "5", "--forced"])
        out = json.loads(capsys.readouterr().out)
        assert out["power"]["resolved"]["run"] is True

    def test_without_history_says_so(self, capsys):
        netmax.main(["plan", "--battery", "ac"])
        out = json.loads(capsys.readouterr().out)
        assert out["schedule"]["verdict"] == "no_history"

    def test_history_drives_windows(self, capsys, tmp_path):
        path = tmp_path / "h.jsonl"
        rows = ([{"mbps": 95.0, "hour": h} for h in (2, 3, 4)] * 4
                + [{"mbps": 28.0, "hour": h} for h in (19, 20, 21)] * 4)
        path.write_text("\n".join(json.dumps(r) for r in rows), encoding="utf-8")
        netmax.main(["plan", "--battery", "ac", "--history", str(path)])
        out = json.loads(capsys.readouterr().out)
        assert out["schedule"]["verdict"] == "recommendation"

    def test_unreadable_history_is_reported_not_fatal(self, capsys):
        netmax.main(["plan", "--battery", "ac", "--history", "/nope/h.jsonl"])
        out = json.loads(capsys.readouterr().out)
        assert out["schedule"]["verdict"] == "history_unreadable"
        # The power half still answered.
        assert out["power"]["resolved"]["run"] is True
