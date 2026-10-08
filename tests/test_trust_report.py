import pytest
from netmax_trust_report import generate_trust_report

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
    samples = [float(i) for i in range(1, 101)] # 1 to 100
    report = generate_trust_report(samples, endpoint="test-server", setup="macOS-wifi")
    assert report["median"] == 50.5
    assert report["p95"] == 95.0
    
def test_trust_report_empty():
    with pytest.raises(ValueError):
        generate_trust_report([], endpoint="", setup="")
