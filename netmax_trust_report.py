import math
from typing import Sequence, Dict, Any

def generate_trust_report(samples: Sequence[float], endpoint: str, setup: str, units: str = "Mbps") -> Dict[str, Any]:
    """Generates a statistical report over a set of measurement samples."""
    if not samples:
        raise ValueError("Cannot generate report from empty samples")
    
    n = len(samples)
    sorted_samples = sorted(samples)
    
    if n % 2 == 1:
        median = sorted_samples[n // 2]
    else:
        median = (sorted_samples[n // 2 - 1] + sorted_samples[n // 2]) / 2.0
        
    # p95 logic: simple nearest rank
    p95_index = max(0, math.ceil(0.95 * n) - 1)
    p95 = sorted_samples[p95_index]
    
    mean = sum(samples) / n
    variance = sum((x - mean) ** 2 for x in samples) / max(1, n - 1) if n > 1 else 0.0
    std = math.sqrt(variance)
    
    cv = (std / mean) if mean > 0 else 0.0
    qualified = cv <= 0.05
    
    return {
        "samples": n,
        "median": median,
        "p95": p95,
        "cv": cv,
        "units": units,
        "endpoint": endpoint,
        "setup": setup,
        "qualified": qualified
    }
