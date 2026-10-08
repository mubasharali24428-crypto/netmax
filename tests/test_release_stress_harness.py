import json
from unittest.mock import patch
import sys
import os

# We need to import main from scripts/release_stress.py
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '../scripts')))
from release_stress import main

def test_release_stress_harness(tmp_path):
    out_path = tmp_path / "result.json"
    
    with patch("sys.argv", [
        "release_stress.py", 
        "--iterations", "200", 
        "--profile", "release-smoke", 
        "--json-out", str(out_path)
    ]):
        main()
    
    assert out_path.exists()
    data = json.loads(out_path.read_text())
    assert data["total_runs"] == 200
    assert data["crashes"] == 0
