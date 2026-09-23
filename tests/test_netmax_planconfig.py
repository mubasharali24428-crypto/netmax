"""Offline tests for netmax_planconfig — ~/.netmaxrc [plan] loader."""

from pathlib import Path

import netmax_planconfig as pc


def _write(tmp_path: Path, body: str) -> Path:
    p = tmp_path / "rc"
    p.write_text(body, encoding="utf-8")
    return p


class TestMissingFile:
    def test_defaults_no_warnings(self, tmp_path):
        cfg = pc.load_config(tmp_path / "does-not-exist")
        assert cfg["down_mbps"] == pc.DEFAULTS["down_mbps"]
        assert cfg["up_mbps"] is None
        assert cfg["warnings"] == []


class TestValidConfig:
    def test_reads_down_and_up(self, tmp_path):
        p = _write(tmp_path, "[plan]\ndown_mbps = 940\nup_mbps = 35\n")
        cfg = pc.load_config(p)
        assert cfg["down_mbps"] == 940.0
        assert cfg["up_mbps"] == 35.0
        assert cfg["warnings"] == []

    def test_up_optional(self, tmp_path):
        p = _write(tmp_path, "[plan]\ndown_mbps = 100\n")
        cfg = pc.load_config(p)
        assert cfg["down_mbps"] == 100.0
        assert cfg["up_mbps"] is None

    def test_unknown_sections_ignored(self, tmp_path):
        p = _write(tmp_path, "[other]\nfoo = 1\n[plan]\ndown_mbps = 50\n")
        cfg = pc.load_config(p)
        assert cfg["down_mbps"] == 50.0
        assert cfg["warnings"] == []


class TestInvalidValues:
    def test_non_numeric_falls_back_with_warning(self, tmp_path):
        p = _write(tmp_path, "[plan]\ndown_mbps = fast\n")
        cfg = pc.load_config(p)
        assert cfg["down_mbps"] == pc.DEFAULTS["down_mbps"]
        assert any("not a number" in w for w in cfg["warnings"])

    def test_zero_rejected(self, tmp_path):
        p = _write(tmp_path, "[plan]\ndown_mbps = 0\n")
        cfg = pc.load_config(p)
        assert cfg["down_mbps"] == pc.DEFAULTS["down_mbps"]
        assert cfg["warnings"]

    def test_over_max_rejected(self, tmp_path):
        p = _write(tmp_path, f"[plan]\ndown_mbps = {pc.MAX_MBPS + 1}\n")
        cfg = pc.load_config(p)
        assert cfg["down_mbps"] == pc.DEFAULTS["down_mbps"]
        assert cfg["warnings"]

    def test_boundary_max_accepted(self, tmp_path):
        p = _write(tmp_path, f"[plan]\ndown_mbps = {pc.MAX_MBPS:g}\n")
        cfg = pc.load_config(p)
        assert cfg["down_mbps"] == pc.MAX_MBPS


class TestBrokenFile:
    def test_no_plan_section_defaults_silent(self, tmp_path):
        p = _write(tmp_path, "[database]\nhost=x\n")
        cfg = pc.load_config(p)
        assert cfg["down_mbps"] == pc.DEFAULTS["down_mbps"]
        assert cfg["warnings"] == []

    def test_unreadable_garbage_does_not_raise(self, tmp_path):
        p = tmp_path / "rc"
        p.write_bytes(b"\xff\xfe\x00\x01 not ini")
        cfg = pc.load_config(p)
        assert cfg["down_mbps"] == pc.DEFAULTS["down_mbps"]
        # either silent default or a warning — must not raise
        assert isinstance(cfg["warnings"], list)
