"""Offline tests for netmax_ai_p1 (P1 AI diagnostics).

Every class must work with NO api key — heuristics are the default path and
the offline contract. Model paths are exercised through a fake urlopen, and
the guard rails (clamping, allow-lists, refusal to invent measurements) are
pinned as hard requirements rather than nice-to-haves.
"""

from __future__ import annotations

import json

import pytest

from netmax_ai_p1 import (
    AdaptiveChunkSizer,
    CrossStreamCoordinator,
    DNSStrategyOptimizer,
    ISPBehaviorFingerprinter,
    JitterSourceAttributor,
    MultiObjectiveOptimizer,
    NaturalLanguageCLI,
    ObjectiveWeights,
    PacketLossPatternRecognizer,
    RootCauseClassifier,
    WiFiOptimizationAdvisor,
)


def _reply(content):
    """urlopen stand-in returning one JSON-mode chat completion."""
    class Resp:
        status = 200

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def read(self):
            return json.dumps({
                "choices": [{"message": {"content": json.dumps(content)}}]
            }).encode("utf-8")

    return lambda req, timeout=None: Resp()


def _boom(req, timeout=None):
    raise OSError("network down")


# ── 3. MultiObjectiveOptimizer ────────────────────────────────────────────────

def test_optimizer_empty_returns_none():
    assert MultiObjectiveOptimizer().optimize([]) is None


def test_optimizer_prefers_throughput_when_it_is_all_that_matters():
    opts = [
        {"streams": 1, "throughput_mbps": 20, "latency_ms": 20, "jitter_ms": 2},
        {"streams": 8, "throughput_mbps": 90, "latency_ms": 90, "jitter_ms": 25},
    ]
    w = ObjectiveWeights(throughput=10, latency=0.1, jitter=0.0, fairness=0.0)
    out = MultiObjectiveOptimizer().optimize(opts, w)
    assert out["streams"] == 8
    assert out["source"] == "local"


def test_optimizer_prefers_latency_for_interactive_traffic():
    """A video call cares about latency more than aggregate throughput."""
    opts = [
        {"streams": 1, "throughput_mbps": 20, "latency_ms": 15, "jitter_ms": 2},
        {"streams": 8, "throughput_mbps": 90, "latency_ms": 120, "jitter_ms": 40},
    ]
    w = ObjectiveWeights(throughput=0.5, latency=10, jitter=5, fairness=1)
    out = MultiObjectiveOptimizer().optimize(opts, w)
    assert out["streams"] == 1


def test_optimizer_model_cannot_invent_a_stream_count(monkeypatch):
    opts = [
        {"streams": 1, "throughput_mbps": 20, "latency_ms": 20},
        {"streams": 4, "throughput_mbps": 60, "latency_ms": 40},
    ]
    opt = MultiObjectiveOptimizer(api_key="k")
    monkeypatch.setattr("netmax_ai_provider.urlopen", _reply(
        {"pick_streams": 999, "reasoning": "many!", "confidence": "high"}))
    out = opt.optimize(opts)
    assert out["streams"] in {1, 4}          # 999 refused


def test_optimizer_model_pick_is_honoured_when_legal(monkeypatch):
    opts = [
        {"streams": 1, "throughput_mbps": 20, "latency_ms": 20},
        {"streams": 4, "throughput_mbps": 60, "latency_ms": 40},
    ]
    opt = MultiObjectiveOptimizer(api_key="k")
    monkeypatch.setattr("netmax_ai_provider.urlopen", _reply(
        {"pick_streams": 1, "reasoning": "latency matters", "confidence": "high"}))
    out = opt.optimize(opts)
    assert out["streams"] == 1
    assert out["source"] == "ai"


# ── 5. AdaptiveChunkSizer ─────────────────────────────────────────────────────

def test_chunk_shrinks_when_the_link_is_unstable():
    sz = AdaptiveChunkSizer()
    # 100ms RTT on a 100 Mbps pipe gives a BDP of ~1.25 MB, comfortably
    # above the 256 KB floor, so the instability response is observable.
    # (At a 20ms RTT the BDP is below the floor and both clamp — correct,
    # but it hides the effect.)
    steady = sz.suggest_chunk_bytes(rtt_ms=100, jitter_ms=1, loss_pct=0.0)
    awful = sz.suggest_chunk_bytes(rtt_ms=100, jitter_ms=40, loss_pct=3.0)
    assert awful["chunk_bytes"] < steady["chunk_bytes"]


def test_chunk_scales_with_throughput():
    """BDP grows with pipe rate, so a faster link gets bigger chunks."""
    sz = AdaptiveChunkSizer()
    slow = sz.suggest_chunk_bytes(rtt_ms=100, throughput_mbps=50)
    fast = sz.suggest_chunk_bytes(rtt_ms=100, throughput_mbps=500)
    assert fast["chunk_bytes"] > slow["chunk_bytes"]


def test_chunk_respects_hard_bounds():
    sz = AdaptiveChunkSizer()
    for rtt in (1, 20, 200, 5000):
        out = sz.suggest_chunk_bytes(rtt_ms=rtt, jitter_ms=0, loss_pct=0)
        assert sz.min_bytes <= out["chunk_bytes"] <= sz.max_bytes


def test_chunk_model_value_is_clamped(monkeypatch):
    sz = AdaptiveChunkSizer(api_key="k")
    monkeypatch.setattr("netmax_ai_provider.urlopen", _reply(
        {"chunk_bytes": 999_999_999, "reasoning": "huge"}))
    out = sz.suggest_chunk_bytes(rtt_ms=50)
    assert out["chunk_bytes"] == sz.max_bytes
    assert out["source"] == "ai"


def test_chunk_model_failure_keeps_local_answer(monkeypatch):
    sz = AdaptiveChunkSizer(api_key="k")
    monkeypatch.setattr("netmax_ai_provider.urlopen", _boom)
    out = sz.suggest_chunk_bytes(rtt_ms=50)
    assert sz.min_bytes <= out["chunk_bytes"] <= sz.max_bytes
    assert out["source"] == "local"


# ── 6. CrossStreamCoordinator ─────────────────────────────────────────────────

def test_allocation_pins_the_sum_to_the_aggregate():
    alloc = CrossStreamCoordinator()
    out = alloc.allocate(4, 1_000_000, per_stream_bps=[50e6, 10e6, 5e6, 1e6])
    assert sum(out["shares_bps"]) == pytest.approx(1_000_000)


def test_allocation_is_even_without_per_stream_data():
    alloc = CrossStreamCoordinator()
    out = alloc.allocate(4, 1_000_000)
    assert out["shares_bps"] == pytest.approx([250_000.0] * 4)


def test_faster_streams_get_a_bigger_share():
    alloc = CrossStreamCoordinator()
    out = alloc.allocate(2, 1_000_000, per_stream_bps=[90e6, 10e6])
    assert out["shares_bps"][0] > out["shares_bps"][1]


def test_a_dead_stream_is_not_starved_to_zero():
    """A stream that delivered nothing still gets a trickle to make progress."""
    alloc = CrossStreamCoordinator()
    out = alloc.allocate(2, 1_000_000, per_stream_bps=[0.0, 90e6])
    assert all(s > 0 for s in out["shares_bps"])
    assert sum(out["shares_bps"]) == pytest.approx(1_000_000)


def test_allocation_rejects_nonsense():
    alloc = CrossStreamCoordinator()
    assert alloc.allocate(0, 1_000_000) is None
    assert alloc.allocate(4, 0) is None


def test_allocation_handles_all_dead_streams():
    alloc = CrossStreamCoordinator()
    out = alloc.allocate(2, 1_000_000, per_stream_bps=[0.0, 0.0])
    assert out["shares_bps"] == pytest.approx([500_000.0] * 2)


# ── 8. RootCauseClassifier ────────────────────────────────────────────────────

def test_classifier_finds_bufferbloat():
    rc = RootCauseClassifier()
    out = rc.classify({"bloat_grade": "D", "bloat_delta_ms": 180,
                       "mbps": 40.0, "loss_pct": 0.2})
    causes = [c["cause"] for c in out["causes"]]
    assert "bufferbloat" in causes
    assert out["source"] == "local"


def test_classifier_puts_a_dead_link_first():
    rc = RootCauseClassifier()
    out = rc.classify({"mbps": 0.1, "loss_pct": 90.0})
    assert out["causes"][0]["cause"] == "dead_link"
    assert out["causes"][0]["severity"] == "critical"


def test_classifier_reports_nothing_on_a_clean_link():
    rc = RootCauseClassifier()
    out = rc.classify({"mbps": 120.0, "loss_pct": 0.0, "jitter_ms": 2.0,
                       "bloat_grade": "A+", "rssi": -45, "target_mbps": 100.0})
    assert out["causes"] == []


def test_classifier_always_attaches_a_fix():
    rc = RootCauseClassifier()
    out = rc.classify({"bloat_grade": "F"})
    assert all(c["fixes"] for c in out["causes"])


def test_classifier_drops_hallucinated_causes(monkeypatch):
    rc = RootCauseClassifier(api_key="k")
    monkeypatch.setattr("netmax_ai_provider.urlopen", _reply({
        "summary": "quantum flux",
        "causes": [
            {"cause": "bufferbloat", "severity": "high",
             "evidence": ["grade D"], "fixes": ["enable SQM"], "confidence": "high"},
            {"cause": "wifi_alignment_with_mars", "severity": "critical",
             "evidence": ["planets aligned"], "fixes": ["realign dish"],
             "confidence": "high"},
        ],
    }))
    out = rc.classify({"bloat_grade": "D", "mbps": 40.0})
    assert [c["cause"] for c in out["causes"]] == ["bufferbloat"]


def test_classifier_model_failure_keeps_local_ranking(monkeypatch):
    rc = RootCauseClassifier(api_key="k")
    monkeypatch.setattr("netmax_ai_provider.urlopen", _boom)
    out = rc.classify({"bloat_grade": "D", "mbps": 40.0})
    assert out["source"] == "local"
    assert out["causes"]


# ── 9. ISPBehaviorFingerprinter ───────────────────────────────────────────────

def test_fingerprint_without_history_says_so():
    out = ISPBehaviorFingerprinter().fingerprint()
    assert out["confidence"] == "none"
    assert out["shaping_detected"] is False


def test_fingerprint_flags_a_time_of_day_gap():
    fp = ISPBehaviorFingerprinter()
    for hour in (2, 3, 4):
        for _ in range(4):
            fp.record_sample(95.0, hour=hour)
    for hour in (19, 20, 21):
        for _ in range(4):
            fp.record_sample(30.0, hour=hour)
    out = fp.fingerprint()
    assert out["shaping_detected"] is True
    assert 19 in out["peak_hours"] or 20 in out["peak_hours"]


def test_fingerprint_is_provisional_on_thin_evidence():
    fp = ISPBehaviorFingerprinter()
    fp.record_sample(90.0, hour=2)
    fp.record_sample(20.0, hour=20)
    out = fp.fingerprint()
    assert "provisional" in " ".join(out["notes"])


def test_fingerprint_flat_history_is_not_shaping():
    fp = ISPBehaviorFingerprinter()
    for hour in range(24):
        for _ in range(3):
            fp.record_sample(80.0 + (hour % 3), hour=hour)
    assert fp.fingerprint()["shaping_detected"] is False


# ── 11. WiFiOptimizationAdvisor ──────────────────────────────────────────────

def test_wifi_flags_a_crowded_24ghz_channel():
    adv = WiFiOptimizationAdvisor()
    out = adv.advise({"rssi": -55, "noise": -95, "channel": 9})
    assert any("1, 6 or 11" in a for a in out["advice"])


def test_wifi_praises_a_clean_channel():
    adv = WiFiOptimizationAdvisor()
    out = adv.advise({"rssi": -50, "noise": -92, "channel": 6})
    assert any("clean" in a for a in out["advice"])


def test_wifi_weak_signal_gets_advice():
    adv = WiFiOptimizationAdvisor()
    out = adv.advise({"rssi": -85, "noise": -90, "channel": 6})
    assert out["advice"]


def test_wifi_160mhz_is_discouraged():
    adv = WiFiOptimizationAdvisor()
    out = adv.advise({"rssi": -50, "noise": -95, "channel": 36,
                      "bandwidth_mhz": 160})
    assert any("160MHz" in a for a in out["advice"])


def test_wifi_snr_is_reported():
    adv = WiFiOptimizationAdvisor()
    out = adv.advise({"rssi": -60, "noise": -90, "channel": 6})
    assert out["snr_db"] == pytest.approx(30.0)


# ── 12. DNSStrategyOptimizer ──────────────────────────────────────────────────

def test_dns_ranks_by_latency():
    dns = DNSStrategyOptimizer()
    out = dns.advise([
        {"name": "Google 8.8.8.8", "latency_ms": 60},
        {"name": "Cloudflare 1.1.1.1", "latency_ms": 12},
    ])
    assert out["recommended"] == "Cloudflare 1.1.1.1"
    assert out["ranking"][0]["latency_ms"] == 12


def test_dns_ignores_resolvers_without_a_measurement():
    assert DNSStrategyOptimizer().advise([{"name": "x"}]) is None
    assert DNSStrategyOptimizer().advise([]) is None


def test_dns_notes_when_switching_is_pointless():
    dns = DNSStrategyOptimizer()
    out = dns.advise([
        {"name": "A", "latency_ms": 12.0},
        {"name": "B", "latency_ms": 15.0},
    ])
    assert any("small" in n for n in out["notes"])


def test_dns_refuses_an_unmeasured_resolver(monkeypatch):
    dns = DNSStrategyOptimizer(api_key="k")
    monkeypatch.setattr("netmax_ai_provider.urlopen", _reply(
        {"recommended": "SomeRandomResolver", "notes": ["trust me"],
         "confidence": "high"}))
    out = dns.advise([{"name": "Google 8.8.8.8", "latency_ms": 60}])
    assert out["recommended"] == "Google 8.8.8.8"


# ── 13. PacketLossPatternRecognizer ───────────────────────────────────────────

def test_loss_none_when_nothing_was_lost():
    pl = PacketLossPatternRecognizer()
    out = pl.classify([{"lost": False} for _ in range(20)])
    assert out["pattern"] == "none"
    assert out["loss_pct"] == 0.0


def test_loss_scattered_is_random():
    pl = PacketLossPatternRecognizer()
    events = [{"lost": i in {2, 7, 13, 18}} for i in range(20)]
    assert pl.classify(events)["pattern"] == "random"


def test_loss_in_a_run_is_burst():
    pl = PacketLossPatternRecognizer()
    events = [{"lost": 5 <= i <= 11} for i in range(30)]
    out = pl.classify(events)
    assert out["pattern"] == "burst"
    assert out["confidence"] == "high"


def test_loss_on_a_timer_is_periodic():
    pl = PacketLossPatternRecognizer()
    # exactly one loss every 5 seconds, perfectly regular
    events = [{"lost": i % 5 == 0, "ts": 1000.0 + i} for i in range(40)]
    assert pl.classify(events)["pattern"] == "periodic"


def test_loss_attaches_a_pattern_specific_fix():
    pl = PacketLossPatternRecognizer()
    events = [{"lost": 5 <= i <= 11} for i in range(30)]
    fixes = " ".join(pl.classify(events)["fixes"]).lower()
    assert "bufferbloat" in fixes or "queue" in fixes


def test_loss_empty_events_are_unknown():
    out = PacketLossPatternRecognizer().classify([])
    assert out["pattern"] == "unknown"
    assert out["confidence"] == "none"


# ── 14. JitterSourceAttributor ────────────────────────────────────────────────

def test_jitter_blames_the_wifi_hop_when_it_dominates():
    j = JitterSourceAttributor()
    out = j.attribute(gateway_ms=45, internet_ms=50, endpoint_ms=52)
    assert out["dominant"] == "local_wifi"
    assert out["hops"][0]["share"] > 0.5


def test_jitter_blames_the_isp_when_it_dominates():
    j = JitterSourceAttributor()
    out = j.attribute(gateway_ms=5, internet_ms=120, endpoint_ms=125)
    assert out["dominant"] == "isp_path"


def test_jitter_shares_sum_to_one():
    j = JitterSourceAttributor()
    out = j.attribute(gateway_ms=10, internet_ms=60, endpoint_ms=62)
    # shares are rounded to 3dp for display, so allow that drift
    assert sum(h["share"] for h in out["hops"]) == pytest.approx(1.0, abs=0.01)


def test_jitter_with_no_data_is_unknown():
    out = JitterSourceAttributor().attribute(None, None)
    assert out["dominant"] == "unknown"
    assert out["confidence"] == "none"


def test_jitter_refuses_a_hop_that_was_not_measured(monkeypatch):
    j = JitterSourceAttributor(api_key="k")
    monkeypatch.setattr("netmax_ai_provider.urlopen", _reply(
        {"dominant": "quantum_link", "advice": "x", "confidence": "high"}))
    out = j.attribute(gateway_ms=45, internet_ms=50)
    assert out["dominant"] in {"local_wifi", "isp_path"}


# ── 15. NaturalLanguageCLI ────────────────────────────────────────────────────

@pytest.mark.parametrize("text,expected", [
    ("keep my download at 5 Mbps", ["limit", "--mbps", "5"]),
    ("limit the speed to 2.5 mbps for 10 minutes",
     ["limit", "--mbps", "2.5", "--seconds", "600"]),
    ("cap bandwidth at 1 gbps", ["limit", "--mbps", "1000"]),
    ("run a bufferbloat test", ["bloat"]),
    ("check my dns", ["dns"]),
    ("how is my wifi signal", ["wifi"]),
    ("measure jitter", ["jitter"]),
    ("check packet loss", ["loss"]),
    ("what is my upload speed", ["upload"]),
    ("run the full diagnostics", ["full"]),
    ("test my throughput for 30 seconds", ["baseline", "--seconds", "30"]),
])
def test_nl_parses_common_phrasings_offline(text, expected):
    out = NaturalLanguageCLI(api_key="").parse(text)
    assert out["argv"] == expected
    assert out["source"] == "local"


def test_nl_rejects_out_of_band_mbps_offline():
    """Offline, an out-of-range cap must be refused rather than emitted."""
    out = NaturalLanguageCLI(api_key="").parse("limit to 999999 mbps")
    assert "error" in out
    assert "argv" not in out


def test_nl_empty_request_errors():
    assert "error" in NaturalLanguageCLI().parse("   ")


def test_nl_unparseable_offline_says_so():
    # no command keyword anywhere in the sentence
    out = NaturalLanguageCLI(api_key="").parse("please do the needful")
    assert "error" in out


def test_nl_refuses_a_command_outside_the_allowlist(monkeypatch):
    cli = NaturalLanguageCLI(api_key="k")
    monkeypatch.setattr("netmax_ai_provider.urlopen", _reply(
        {"command": "rm", "mbps": 5, "reasoning": "x", "confidence": "high"}))
    out = cli.parse("please do the needful")
    assert "error" in out
    assert "rm" not in out.get("argv", [])


def test_nl_model_translation_is_range_checked(monkeypatch):
    cli = NaturalLanguageCLI(api_key="k")
    monkeypatch.setattr("netmax_ai_provider.urlopen", _reply(
        {"command": "limit", "mbps": 100_000, "seconds": 999_999,
         "streams": 900, "reasoning": "go fast", "confidence": "high"}))
    out = cli.parse("hold my line steady somehow")
    assert out["argv"][:2] == ["limit", "--mbps"]
    assert float(out["argv"][2]) <= 10_000
    assert int(out["argv"][out["argv"].index("--streams") + 1]) <= 50
    assert int(out["argv"][out["argv"].index("--seconds") + 1]) <= 21_600


def test_nl_model_failure_reports_an_error(monkeypatch):
    cli = NaturalLanguageCLI(api_key="k")
    monkeypatch.setattr("netmax_ai_provider.urlopen", _boom)
    assert "error" in cli.parse("please do the needful")


def test_nl_limit_without_mbps_is_refused(monkeypatch):
    cli = NaturalLanguageCLI(api_key="k")
    monkeypatch.setattr("netmax_ai_provider.urlopen", _reply(
        {"command": "limit", "reasoning": "no number given", "confidence": "low"}))
    out = cli.parse("please hold my bandwidth steady somehow")
    assert "error" in out
