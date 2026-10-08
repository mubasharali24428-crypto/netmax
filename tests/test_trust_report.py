import pytest
from netmax_trust_report import (
    TRUST_REPORT_SAMPLES,
    generate_trust_report,
    report_id,
    report_to_json,
)


def test_trust_report_qualified():
    # 10 samples with very low variance (mean 100, std ~0)
    samples = [100.0] * 10
    report = generate_trust_report(samples, endpoint="test-server", setup="macOS-ethernet")
    assert report["samples"] == 10
    assert report["median"] == 100.0
    assert report["p95"] == 100.0
    assert report["cv"] == 0.0
    assert report["units"] == "Mbps"
    assert report["qualified"] is True


def test_trust_report_unqualified_high_variance():
    # Mean ~100, but high variance
    # cv = std / mean
    # [100, 100, 100, 100, 100, 100, 100, 100, 100, 120] -> mean=102, std=~6.32
    # cv = 6.32 / 102 = ~0.06 > 0.05 -> unqualified
    samples = [100.0] * 9 + [120.0]
    report = generate_trust_report(samples, endpoint="test-server", setup="macOS-ethernet")
    assert report["cv"] > 0.05
    assert report["qualified"] is False


def test_trust_report_median_and_p95():
    samples = [float(i) for i in range(1, 11)]  # 1 to 10
    report = generate_trust_report(samples, endpoint="test-server", setup="macOS-wifi")
    assert report["median"] == 5.5
    assert report["p95"] == 10.0


def test_trust_report_empty():
    with pytest.raises(ValueError):
        generate_trust_report([], endpoint="", setup="")


def test_trust_report_rejects_fewer_than_10():
    with pytest.raises(ValueError, match="exactly 10 samples"):
        generate_trust_report([100.0] * 9, endpoint="e", setup="s")


def test_trust_report_rejects_more_than_10():
    with pytest.raises(ValueError, match="exactly 10 samples"):
        generate_trust_report([100.0] * 11, endpoint="e", setup="s")


def test_trust_report_sample_rule_constant():
    assert TRUST_REPORT_SAMPLES == 10


def test_trust_report_json_is_byte_identical():
    samples = [98.0, 101.5, 99.2, 100.1, 97.8, 102.3, 99.9, 100.0, 98.7, 101.1]
    r1 = generate_trust_report(samples, endpoint="e", setup="s")
    r2 = generate_trust_report(list(samples), endpoint="e", setup="s")
    assert report_to_json(r1) == report_to_json(r2)
    # Key insertion order must not change the bytes.
    shuffled = dict(reversed(list(r1.items())))
    assert report_to_json(shuffled) == report_to_json(r1)
    # Canonical form: no whitespace, sorted keys.
    raw = report_to_json(r1)
    assert ": " not in raw and ", " not in raw
    assert raw.index('"cv"') < raw.index('"endpoint"')


def test_trust_report_id_stable():
    samples = [100.0] * 10
    r1 = generate_trust_report(samples, endpoint="e", setup="s")
    r2 = generate_trust_report(samples, endpoint="e", setup="s")
    assert r1["report_id"] == r2["report_id"] == report_id(r1)
    assert len(r1["report_id"]) == 64
