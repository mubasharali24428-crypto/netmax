"""F7 regression tests: SSID/BSSID minimization at rest.

Audit finding F7 (Medium/privacy): WiFi events persisted raw BSSID
(location-adjacent) and SSID. The fix hashes both (salted SHA-256,
"nm1:" prefix) at the capture boundary; detection semantics (roam via
inequality, RSSI thresholds, channel deltas) are unchanged.
"""

import json

import netmax_wifievents


# ── F7: SSID/BSSID minimization at rest ──────────────────────────────────────

def _profiler_json(ssid: str, bssid: str, rssi: str = "-55 dBm / -96 dBm",
                   channel: str = "149 (5GHz)") -> str:
    """system_profiler -json shape with a raw SSID/BSSID block."""
    return json.dumps({"SPAirPortDataType": [{"spairport_current_network_information":
        {ssid: {"spairport_mac_address": bssid,
                "spairport_signal_or_noise": rssi,
                "spairport_current_channel": channel}}}]})


class TestPrivacyMinimization:
    """F7: raw SSID/BSSID must never survive into any persisted shape."""

    def test_snapshot_hashes_identifiers(self):
        snap = netmax_wifievents.parse_snapshot(
            _profiler_json("HomeWiFi_5G", "aa:bb:cc:11:22:33"))
        assert snap["ssid"].startswith("nm1:")
        assert snap["bssid"].startswith("nm1:")
        assert "HomeWiFi_5G" not in json.dumps(snap)
        assert "aa:bb:cc" not in json.dumps(snap)

    def test_roam_event_details_carry_hashes_only(self):
        prev = netmax_wifievents.parse_snapshot(
            _profiler_json("HomeWiFi_5G", "aa:bb:cc:11:22:33"))
        curr = netmax_wifievents.parse_snapshot(
            _profiler_json("CoffeeShop", "aa:bb:cc:44:55:66"))
        events = netmax_wifievents.diff_snapshots(prev, curr)
        kinds = [e["kind"] for e in events]
        assert "roam" in kinds
        blob = json.dumps(events)
        assert "HomeWiFi_5G" not in blob and "CoffeeShop" not in blob
        assert "from_ssid_hash" in blob and "to_ssid_hash" in blob
        assert "aa:bb:cc" not in blob

    def test_same_network_no_roam_event(self):
        j = _profiler_json("HomeWiFi_5G", "aa:bb:cc:11:22:33")
        snap = netmax_wifievents.parse_snapshot(j)
        again = netmax_wifievents.parse_snapshot(j)
        assert netmax_wifievents.diff_snapshots(snap, again) == []

    def test_bssid_change_still_detects_roam(self):
        prev = netmax_wifievents.parse_snapshot(
            _profiler_json("SameSSID", "aa:bb:cc:11:22:33"))
        curr = netmax_wifievents.parse_snapshot(
            _profiler_json("SameSSID", "aa:bb:cc:99:88:77"))
        kinds = [e["kind"] for e in
                 netmax_wifievents.diff_snapshots(prev, curr)]
        assert "roam" in kinds

    def test_rssi_drop_still_fires_on_hashed_snapshots(self):
        prev = netmax_wifievents.parse_snapshot(
            _profiler_json("Net", "aa:bb:cc:11:22:33", rssi="-55 dBm / -96 dBm"))
        curr = netmax_wifievents.parse_snapshot(
            _profiler_json("Net", "aa:bb:cc:11:22:33", rssi="-75 dBm / -96 dBm"))
        kinds = [e["kind"] for e in
                 netmax_wifievents.diff_snapshots(prev, curr)]
        assert "rssi_drop" in kinds

    def test_hash_is_deterministic_for_same_value(self):
        a = netmax_wifievents.hash_identifier("X")
        b = netmax_wifievents.hash_identifier("X")
        assert a == b and a is not None

    def test_unassociated_snapshot_has_no_identifiers(self):
        snap = netmax_wifievents.parse_snapshot(
            json.dumps({"SPAirPortDataType": [{}]}))
        assert snap == {"associated": False}
        assert netmax_wifievents.hash_identifier(None) is None
