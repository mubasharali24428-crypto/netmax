"""Tests for P3 items 46 (network profiles) and 43 (context resolution).

The composition rule that matters: every input may only make a run GENTLER.
A mis-detected context or a stale profile may cost accuracy, but must never
produce a saturating run nobody asked for. Several tests below exist purely
to hold that direction.
"""

from __future__ import annotations

import json

import pytest

import netmax
import netmax_profiles as prof
import netmax_schedule as sched
import netmax_wifievents as we


def _snap(rssi=None, channel=None, band=None, ssid="nm1:x", associated=True):
    return {"associated": associated, "ssid": ssid, "rssi_dbm": rssi,
            "channel": channel, "band": band}


class TestClassification:
    def test_strong_5ghz(self):
        assert prof.classify_snapshot(_snap(-45, "36", "5")) == "strong"

    def test_fair_5ghz(self):
        assert prof.classify_snapshot(_snap(-62, "149", "5")) == "fair"

    def test_poor_signal(self):
        assert prof.classify_snapshot(_snap(-80, "36", "5")) == "poor"

    def test_24ghz_is_poor_even_with_a_good_signal(self):
        """2.4 GHz contention, not signal strength, is the limit here."""
        assert prof.classify_snapshot(_snap(-45, "11", "2.4")) == "poor"

    def test_24ghz_detected_by_channel_number(self):
        assert prof.classify_snapshot(_snap(-45, "6", None)) == "poor"

    def test_wired_has_no_ssid_or_channel(self):
        assert prof.classify_snapshot(
            {"associated": True, "ssid": None, "channel": None,
             "rssi_dbm": None}) == "wired"

    def test_disassociated_is_unknown(self):
        assert prof.classify_snapshot(_snap(associated=False)) == "unknown"

    def test_missing_snapshot_is_unknown(self):
        assert prof.classify_snapshot(None) == "unknown"


class TestPrivacy:
    def test_profile_key_matches_the_detectors_hash(self):
        """A profile must key on the same hash wifievents emits (F7)."""
        assert prof.ProfileStore.key_for("CoffeeShop") == we.hash_identifier("CoffeeShop")

    def test_store_saves_no_plaintext_ssid(self, tmp_path):
        store = prof.ProfileStore()
        store.set_for_ssid("MyHomeNetwork", prof.RunProfile(
            name="custom", streams=2, seconds=20))
        path = tmp_path / "p.json"
        store.save(str(path))
        raw = path.read_text(encoding="utf-8")
        assert "MyHomeNetwork" not in raw
        assert "nm1:" in raw            # the hash is what got stored

    def test_store_round_trips(self, tmp_path):
        store = prof.ProfileStore()
        key = store.set_for_ssid("Cafe", prof.RunProfile(
            name="cafe", streams=1, seconds=15, bloat_eco_only=True))
        path = tmp_path / "p.json"
        store.save(str(path))
        loaded = prof.ProfileStore.load(str(path))
        got = loaded.get({"ssid": key})
        assert got is not None
        assert got.streams == 1 and got.bloat_eco_only is True

    def test_missing_store_file_is_empty_not_fatal(self, tmp_path):
        assert prof.ProfileStore.load(str(tmp_path / "nope.json")).by_hash == {}

    def test_corrupt_store_file_is_empty_not_fatal(self, tmp_path):
        path = tmp_path / "p.json"
        path.write_text("{not json", encoding="utf-8")
        assert prof.ProfileStore.load(str(path)).by_hash == {}


class TestCompositionIsMonotonic:
    """Every input may only tighten. These pin that direction."""

    def test_configured_profile_cannot_exceed_the_measured_link(self):
        """A stale profile asking for 8 streams on a poor link gets refused."""
        store = prof.ProfileStore()
        key = store.set_for_ssid("Cafe", prof.RunProfile(
            name="stale", streams=8, seconds=10))
        out = prof.resolve_settings(
            _snap(-80, "6", "2.4", ssid=key), store=store)
        assert out["streams"] == 1          # inferred poor wins
        assert any("supports" in n for n in out["notes"])

    def test_configured_profile_cannot_force_a_saturating_bloat_grade(self):
        store = prof.ProfileStore()
        key = store.set_for_ssid("Cafe", prof.RunProfile(
            name="stale", streams=4, seconds=10, bloat_eco_only=False))
        out = prof.resolve_settings(
            _snap(-80, "6", "2.4", ssid=key), store=store)
        assert out["bloat_eco_only"] is True

    def test_interactive_context_reduces_streams(self):
        out = prof.resolve_settings(_snap(-45, "36", "5"),
                                    context=prof.RunContext(interactive=True))
        assert out["streams"] == 2
        assert out["reserve_for_interactive"] is True

    def test_interactive_context_does_not_raise_streams(self):
        out = prof.resolve_settings(_snap(-80, "6", "2.4"),
                                    context=prof.RunContext(interactive=True))
        assert out["streams"] <= 1

    def test_budget_shortens_the_run(self):
        out = prof.resolve_settings(_snap(-45, "36", "5"),
                                    context=prof.RunContext(budget_seconds=7))
        assert out["seconds"] == 7

    def test_a_generous_budget_does_not_extend_the_profile(self):
        out = prof.resolve_settings(_snap(-45, "36", "5"),
                                    context=prof.RunContext(budget_seconds=3600))
        assert out["seconds"] == 10          # profile still decides

    def test_power_cannot_lengthen_the_run(self):
        full = sched.power_policy(sched.PowerState(on_ac=True, source="ac"))
        half = sched.power_policy(
            sched.PowerState(on_ac=False, source="battery", percent=15.0))
        strong = _snap(-45, "36", "5")
        assert prof.resolve_settings(strong, policy=full)["seconds"] >= \
            prof.resolve_settings(strong, policy=half)["seconds"]


class TestDeferral:
    def test_critical_battery_defers(self):
        crit = sched.power_policy(
            sched.PowerState(on_ac=False, source="battery", percent=8.0))
        out = prof.resolve_settings(_snap(-45, "36", "5"), policy=crit)
        assert out["run"] is False

    def test_time_sensitive_overrides_the_deferral(self):
        crit = sched.power_policy(
            sched.PowerState(on_ac=False, source="battery", percent=8.0))
        out = prof.resolve_settings(
            _snap(-45, "36", "5"), policy=crit,
            context=prof.RunContext(time_sensitive=True))
        assert out["run"] is True

    def test_forced_policy_overrides_the_deferral(self):
        crit = sched.power_policy(
            sched.PowerState(on_ac=False, source="battery", percent=8.0),
            forced=True)
        out = prof.resolve_settings(_snap(-45, "36", "5"), policy=crit)
        assert out["run"] is True


class TestResolveSubcommand:
    def test_accepts_a_snapshot(self, capsys):
        netmax.main(["resolve", "--wifi-json", json.dumps(_snap(-45, "36", "5")),
                     "--battery", "ac"])
        out = json.loads(capsys.readouterr().out)
        assert out["profile"] == "strong"
        assert out["run"] is True

    def test_reports_the_power_reason(self, capsys):
        netmax.main(["resolve", "--wifi-json", json.dumps(_snap(-45, "36", "5")),
                     "--battery", "12"])
        out = json.loads(capsys.readouterr().out)
        assert "12%" in out["power"]["reason"]

    def test_reports_whether_context_was_known(self, capsys):
        netmax.main(["resolve", "--wifi-json", json.dumps(_snap(-45, "36", "5")),
                     "--battery", "ac"])
        assert json.loads(capsys.readouterr().out)["context"]["known"] is False

    def test_interactive_flag_marks_context_known(self, capsys):
        netmax.main(["resolve", "--wifi-json", json.dumps(_snap(-45, "36", "5")),
                     "--battery", "ac", "--interactive"])
        out = json.loads(capsys.readouterr().out)
        assert out["context"]["known"] is True
        assert out["streams"] == 2

    def test_bad_json_is_reported(self, capsys):
        # main() reports NetMaxError on stderr and exits 1.
        with pytest.raises(SystemExit) as exc:
            netmax.main(["resolve", "--wifi-json", "{oops", "--battery", "ac"])
        assert exc.value.code == 1
        assert "not valid JSON" in capsys.readouterr().err

    def test_bogus_battery_is_reported(self, capsys):
        with pytest.raises(SystemExit):
            netmax.main(["resolve", "--battery", "flat"])
        assert "--battery" in capsys.readouterr().err
