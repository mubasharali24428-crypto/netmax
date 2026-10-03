"""Offline tests for plugins/ — JSON validity, install.sh sandbox runs,
Raycast annotations. install.sh only touches $HOME (sandboxed via env)."""

from __future__ import annotations

import json
import os
import stat
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
PLUGINS = REPO / "plugins"

_REAL_RUN = subprocess.run  # captured before conftest arms its tripwire


@pytest.fixture(autouse=True)
def allow_local_processes(monkeypatch):
    """These tests INTENTIONALLY run real bash/python3 on tmp files.

    The global tripwire blocks subprocess.run everywhere; these tests opt
    back into the real call because their whole point is executing the
    shipped scripts end-to-end. Socket tripwires stay armed (no network
    can be reached: everything runs against $HOME-in-tmp or exits early).
    """
    monkeypatch.setattr(subprocess, "run", _REAL_RUN)


def test_plugin_json_valid_and_version_synced():
    raw = (PLUGINS / "claude-code" / ".claude-plugin" / "plugin.json").read_text()
    manifest = json.loads(raw)
    for key in ("name", "description", "version"):
        assert manifest.get(key), f"plugin.json missing {key}"
    pkg = json.loads((REPO / "desktop" / "package.json").read_text())
    assert manifest["version"] == pkg["version"], (
        "plugin version drifted from the MCP server version")


def test_vscode_manifest_valid_and_version_synced():
    manifest = json.loads((PLUGINS / "vscode" / "package.json").read_text())
    assert manifest["engines"]["vscode"].startswith("^1.")
    cmds = [c["command"] for c in manifest["contributes"]["commands"]]
    assert "netmax.showTrends" in cmds
    assert manifest["main"] == "./extension.js"
    pkg = json.loads((REPO / "desktop" / "package.json").read_text())
    assert manifest["version"] == pkg["version"], (
        "vscode extension drifted from the MCP server version")


def test_commands_have_frontmatter_descriptions():
    cmds = sorted((PLUGINS / "claude-code" / "commands").glob("*.md"))
    assert len(cmds) >= 2, "expected at least diagnose/speed commands"
    for path in cmds:
        text = path.read_text()
        assert text.startswith("---\n"), f"{path.name}: missing frontmatter"
        head = text.split("---\n", 2)[1]
        assert "description:" in head, f"{path.name}: no description"


def _run_install(home, *args):
    env = dict(os.environ, HOME=str(home))
    return subprocess.run(
        ["bash", str(PLUGINS / "install.sh"), *args],
        capture_output=True, text=True, timeout=60, env=env)


def test_install_writes_three_configs_idempotently(tmp_path):
    first = _run_install(tmp_path)
    assert first.returncode == 0, first.stderr
    targets = [
        tmp_path / ".cursor" / "mcp.json",
        tmp_path / ".lmstudio" / "mcp.json",
        tmp_path / "Library" / "Application Support" / "Claude"
        / "claude_desktop_config.json",
    ]
    for path in targets:
        data = json.loads(path.read_text())
        entry = data["mcpServers"]["netmax"]
        assert entry["command"] == "npx"
        assert entry["args"] == ["-y", "@netmax/mcp-server"]
    second = _run_install(tmp_path)
    assert second.returncode == 0
    for path in targets:  # still exactly one netmax entry each
        data = json.loads(path.read_text())
        assert list(data["mcpServers"]).count("netmax") == 1


def test_install_preserves_existing_servers_and_backs_up(tmp_path):
    cursor = tmp_path / ".cursor" / "mcp.json"
    cursor.parent.mkdir(parents=True)
    cursor.write_text(json.dumps({"mcpServers": {"other": {"command": "x"}}}))
    assert _run_install(tmp_path).returncode == 0
    data = json.loads(cursor.read_text())
    assert set(data["mcpServers"]) == {"other", "netmax"}
    assert len(list(cursor.parent.glob("mcp.json.netmax-bak-*"))) == 1


def test_install_survives_corrupt_json(tmp_path):
    bad = tmp_path / ".cursor" / "mcp.json"
    bad.parent.mkdir(parents=True)
    bad.write_text("<<not json>>")
    assert _run_install(tmp_path).returncode == 0
    assert "netmax" in json.loads(
        (tmp_path / ".lmstudio" / "mcp.json").read_text())["mcpServers"]


def test_raycast_scripts_annotated_and_executable():
    for path in sorted((PLUGINS / "raycast").glob("*.sh")):
        text = path.read_text()
        for marker in ("@raycast.schemaVersion", "@raycast.title",
                       "@raycast.mode", "@raycast.packageName"):
            assert marker in text, f"{path.name}: missing {marker}"
        assert os.access(path, os.X_OK), f"{path.name}: not executable"
        assert stat.S_IMODE(os.stat(path).st_mode) & 0o111


def test_raycast_quick_check_fails_clean_without_engine(tmp_path, monkeypatch):
    """Missing engine => plain message + exit 1 (never a traceback)."""
    env = dict(os.environ, HOME=str(tmp_path), NETMAX_ROOT=str(tmp_path))
    proc = subprocess.run(
        ["bash", str(PLUGINS / "raycast" / "netmax-quick-check.sh")],
        capture_output=True, text=True, timeout=30, env=env)
    assert proc.returncode == 1
    assert "NETMAX_ROOT" in proc.stdout
