def check_regression_alert(samples: list[float], threshold: float, is_latency: bool = True) -> bool:
    """
    Evaluates at least 20 local samples.
    Triggers an alert ONLY if 3 consecutive threshold breaches occur.
    """
    if len(samples) < 20:
        return False
        
    consecutive_breaches = 0
    for sample in samples:
        # If latency, higher is worse (breach). If throughput, lower is worse (breach).
        breach = (sample > threshold) if is_latency else (sample < threshold)
        if breach:
            consecutive_breaches += 1
            if consecutive_breaches >= 3:
                return True
        else:
            consecutive_breaches = 0
            
    return False
