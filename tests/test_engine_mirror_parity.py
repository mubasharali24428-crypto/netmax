"""Tests for scripts/check_engine_mirrors.py (roadmap task C-08)."""
import importlib.util
from pathlib import Path

_scripts = Path(__file__).resolve().parent.parent / "scripts" / "check_engine_mirrors.py"
_spec = importlib.util.spec_from_file_location("check_engine_mirrors", _scripts)
_mod = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(_mod)
check_mirrors = _mod.check_mirrors
MIRROR_MODULES = _mod.MIRROR_MODULES


def _make_tree(root: Path, modules: dict[str, bytes], engine_extra: list[str] | None = None):
    for name, content in modules.items():
        (root / name).write_bytes(content)
    engine = root / "desktop" / "engine"
    engine.mkdir(parents=True)
    for name, content in modules.items():
        (engine / name).write_bytes(content)
    for name in engine_extra or []:
        (engine / name).write_bytes(b"extra\n")


def test_equal_pairs_pass(tmp_path: Path):
    modules = {name: b"print('x')\n" for name in MIRROR_MODULES}
    _make_tree(tmp_path, modules)
    assert check_mirrors(tmp_path) == []


def test_byte_different_mirror_fails(tmp_path: Path):
    modules = {name: b"same\n" for name in MIRROR_MODULES}
    _make_tree(tmp_path, modules)
    (tmp_path / "desktop" / "engine" / "netmax_fetch.py").write_bytes(b"different\n")
    failures = check_mirrors(tmp_path)
    assert any("netmax_fetch.py" in f and "byte-different" in f for f in failures)


def test_missing_mirror_fails(tmp_path: Path):
    modules = {name: b"same\n" for name in MIRROR_MODULES}
    _make_tree(tmp_path, modules)
    (tmp_path / "desktop" / "engine" / "netmax_shape.py").unlink()
    failures = check_mirrors(tmp_path)
    assert any("missing mirror" in f and "netmax_shape.py" in f for f in failures)


def test_missing_canonical_fails(tmp_path: Path):
    modules = {name: b"same\n" for name in MIRROR_MODULES}
    _make_tree(tmp_path, modules)
    (tmp_path / "netmax_eco.py").unlink()
    failures = check_mirrors(tmp_path)
    assert any("missing canonical" in f and "netmax_eco.py" in f for f in failures)


def test_extra_engine_module_fails(tmp_path: Path):
    modules = {name: b"same\n" for name in MIRROR_MODULES}
    _make_tree(tmp_path, modules, engine_extra=["netmax_gui.py"])
    failures = check_mirrors(tmp_path)
    assert any("extra" in f and "netmax_gui.py" in f for f in failures)