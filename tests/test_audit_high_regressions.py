"""Offline regressions for HIGH fixes from audit commit 995063a.

Covers (tests/ only, no network, no real subprocess):
- wifievents rejects --interval < 1 before any polling starts
- engine_store stamps PRAGMA user_version with SCHEMA_VERSION
- bridge passes encoding="utf-8" in the runner kwargs
"""
import json
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
for _p in (REPO_ROOT / "desktop" / "bridge", REPO_ROOT / "desktop" / "engine_store"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

import engine_bridge as eb
import netmax_wifievents
import store as st


def test_wifievents_interval_below_one_rejected(capsys):
    with pytest.raises(SystemExit) as exc:
        netmax_wifievents.main(["-i", "0"])
    assert exc.value.code == 2
    assert "--interval must be >= 1" in capsys.readouterr().err


def test_wifievents_negative_interval_rejected():
    with pytest.raises(SystemExit) as exc:
        netmax_wifievents.main(["--interval", "-1"])
    assert exc.value.code == 2


def test_store_user_version_stamped(tmp_path):
    conn = st.init_db(tmp_path / "db.sqlite3")
    try:
        version = conn.execute("PRAGMA user_version").fetchone()[0]
        assert version == st.SCHEMA_VERSION
    finally:
        conn.close()


def test_bridge_runner_receives_utf8_encoding(tmp_path):
    seen = {}

    def runner(cmd, **kw):
        seen.update(kw)
        return SimpleNamespace(returncode=0, stdout=json.dumps({"ok": True}), stderr="")

    out = tmp_path / "env.json"
    code = eb.run_engine("dns", None, None, None, str(out), runner=runner)
    assert code == 0
    assert seen.get("encoding") == "utf-8"
    env = json.loads(out.read_text(encoding="utf-8"))
    assert env["success"] is True
