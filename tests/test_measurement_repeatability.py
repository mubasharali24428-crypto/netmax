import json
import pytest
from benchmark_measurement_repeatability import main
from unittest.mock import patch

def test_benchmark_runner(tmp_path):
    protocol_path = tmp_path / "protocol.md"
    protocol_path.write_text("Mac Model/Chip macOS Build Interface Type Endpoint Origin/IP Warmup 10 samples")
    out_path = tmp_path / "out.json"
    
    with patch("sys.argv", ["benchmark.py", "--protocol", str(protocol_path), "--output", str(out_path)]):
        main()
        
    assert out_path.exists()
    data = json.loads(out_path.read_text())
    assert len(data["samples"]) == 10
    assert "metrics" in data
    assert data["metrics"]["throughput"]["cv_percent"] <= 5.0
    assert data["status"] == "PASS"

def test_benchmark_missing_protocol(tmp_path):
    protocol_path = tmp_path / "protocol.md"
    protocol_path.write_text("Missing fields")
    out_path = tmp_path / "out.json"
    
    with patch("sys.argv", ["benchmark.py", "--protocol", str(protocol_path), "--output", str(out_path)]):
        with pytest.raises(ValueError, match="Missing required field"):
            main()
