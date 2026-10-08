"""MCP history access is fixed-root, no-follow, and resource-bounded."""

import shutil
from pathlib import Path

import pytest

import netmax
import netmax_history
from netmax import NetMaxError


def _make_history(monkeypatch, tmp_path, payload=b'{"mbps":12}\n'):
    home = tmp_path / "home"
    path = home / "Library" / "Application Support" / "NetMaxDesktop" / "history.jsonl"
    path.parent.mkdir(parents=True, mode=0o700)
    home.mkdir(exist_ok=True, mode=0o700)
    monkeypatch.setenv("HOME", str(home))
    path.write_bytes(payload)
    path.chmod(0o600)
    return home, path


def test_canonical_app_history_loads_and_normalizes(monkeypatch, tmp_path):
    _home, path = _make_history(monkeypatch, tmp_path)

    rows = netmax_history.load_mcp_history(str(path))

    assert rows == [{"mbps": 12}]


def test_mcp_history_rejects_outside_path(monkeypatch, tmp_path):
    _home, _path = _make_history(monkeypatch, tmp_path)
    outside = tmp_path / "outside.jsonl"
    outside.write_text('{"mbps":99}\n', encoding="utf-8")

    with pytest.raises(ValueError, match="canonical"):
        netmax_history.load_mcp_history(str(outside))


@pytest.mark.parametrize("component", ["Library", "Application Support", "NetMaxDesktop"])
def test_mcp_history_rejects_symlinked_parent(monkeypatch, tmp_path, component):
    home, _path = _make_history(monkeypatch, tmp_path)
    parent = home
    for part in ("Library", "Application Support", "NetMaxDesktop"):
        current = parent / part
        if part == component:
            target = tmp_path / f"external-{component.replace(' ', '-')}"
            target.mkdir(mode=0o700)
            shutil.rmtree(current)
            current.symlink_to(target, target_is_directory=True)
            break
        parent = current

    with pytest.raises(ValueError, match="safely open|directory"):
        netmax_history.load_mcp_history(str(_path))


def test_mcp_history_rejects_symlinked_final_file(monkeypatch, tmp_path):
    _home, path = _make_history(monkeypatch, tmp_path)
    target = tmp_path / "other.jsonl"
    target.write_text('{"mbps":99}\n', encoding="utf-8")
    path.unlink()
    path.symlink_to(target)

    with pytest.raises(ValueError, match="safely open"):
        netmax_history.load_mcp_history(str(path))


def test_mcp_history_rejects_directory_target(monkeypatch, tmp_path):
    _home, path = _make_history(monkeypatch, tmp_path)
    path.unlink()
    path.mkdir()

    with pytest.raises(ValueError, match="regular file"):
        netmax_history.load_mcp_history(str(path))


def test_mcp_history_rejects_file_over_10_mib(monkeypatch, tmp_path):
    _home, path = _make_history(monkeypatch, tmp_path, b"")
    with path.open("wb") as stream:
        stream.truncate(10 * 1024 * 1024 + 1)

    with pytest.raises(ValueError, match="10 MiB"):
        netmax_history.load_mcp_history(str(path))


def test_mcp_history_rejects_more_than_100000_nonempty_rows(monkeypatch, tmp_path):
    _home, path = _make_history(monkeypatch, tmp_path, b"{}\n" * 100_001)

    with pytest.raises(ValueError, match="100,000-row"):
        netmax_history.load_mcp_history(str(path))


def test_mcp_input_at_path_is_rejected_before_read(monkeypatch, tmp_path):
    secret = tmp_path / "private.json"
    secret.write_text('{"mbps":99}', encoding="utf-8")

    def forbidden_read(_self, *_args, **_kwargs):
        pytest.fail("MCP @path input was read")

    monkeypatch.setattr(Path, "read_text", forbidden_read)
    with pytest.raises(NetMaxError, match="not allowed for MCP"):
        netmax._load_json_input(f"@{secret}", allow_file=False)


def test_mcp_history_path_failure_stops_before_analysis_dispatch(
        monkeypatch, tmp_path, capsys):
    _home, _path = _make_history(monkeypatch, tmp_path)
    outside = tmp_path / "outside.jsonl"
    outside.write_text('{"mbps":99}\n', encoding="utf-8")
    dispatched = []
    monkeypatch.setattr(netmax, "run_ai_analysis", lambda *args: dispatched.append(args))

    with pytest.raises(SystemExit) as exc:
        netmax.main(["ai", "--analysis", "forecast", "--mcp-request",
                     "--history", str(outside)])

    assert exc.value.code == 1
    assert dispatched == []
    assert "canonical" in capsys.readouterr().err


def test_non_mcp_cli_history_import_remains_user_selected(monkeypatch, tmp_path):
    _home, _path = _make_history(monkeypatch, tmp_path)
    selected = tmp_path / "selected.jsonl"
    selected.write_text('{"mbps":25}\n', encoding="utf-8")

    assert netmax._load_history(str(selected)) == [{"mbps": 25}]
