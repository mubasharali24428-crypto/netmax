from netmax_local_regression import check_regression_alert

def test_regression_needs_20_samples():
    assert not check_regression_alert([100.0] * 19, 50.0)

def test_regression_3_consecutive_breaches():
    # 20 samples, last 3 are high latency (100 > 50)
    samples = [10.0] * 17 + [100.0, 100.0, 100.0]
    assert check_regression_alert(samples, threshold=50.0, is_latency=True)
    
def test_regression_no_alert_if_not_consecutive():
    samples = [10.0] * 16 + [100.0, 10.0, 100.0, 100.0]
    assert not check_regression_alert(samples, threshold=50.0, is_latency=True)
