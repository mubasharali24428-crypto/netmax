"""Security boundary tests for MCP-managed downloads."""

import os
import stat

import pytest

import netmax
import netmax_fetch
from netmax import NetMaxError


def _set_home(monkeypatch, tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    monkeypatch.setenv("HOME", str(home))
    return home


def _write_private(path, body=b"payload"):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(body)


def _stub_download(url, out_path, streams=8, on_progress=None):
    _write_private(out_path)
    return {"bytes": 7, "mbps": 1.0, "streams_used": 1}


@pytest.mark.parametrize("name", [
    "", ".", "..", "../outside", "/tmp/out", "a/b", "a\\b",
    "bad\x00name", "bad\nname", "x" * 181, "é" * 91,
])
def test_output_name_rejects_paths_controls_and_oversize(name):
    with pytest.raises(NetMaxError):
        netmax_fetch.validate_mcp_output_name(name)


def test_output_name_accepts_exact_utf8_byte_limit():
    name = "é" * 90
    assert len(name.encode("utf-8")) == 180
    assert netmax_fetch.validate_mcp_output_name(name) == name


def test_valid_download_is_private_and_published_inside_fixed_root(
        monkeypatch, tmp_path):
    home = _set_home(monkeypatch, tmp_path)
    monkeypatch.setattr(netmax_fetch, "download", _stub_download)

    output, result = netmax_fetch.download_mcp("https://example.test/a", "capture.bin")

    root = home / "Downloads" / "NetMax"
    assert output == root / "capture.bin"
    assert output.read_bytes() == b"payload"
    assert stat.S_IMODE(output.stat().st_mode) == 0o600
    assert stat.S_IMODE(root.stat().st_mode) == 0o700
    assert stat.S_IMODE(root.parent.stat().st_mode) == 0o700
    assert list(root.glob(".netmax-*")) == []
    assert result["bytes"] == 7


def test_download_parent_symlink_is_rejected_without_touching_target(
        monkeypatch, tmp_path):
    home = _set_home(monkeypatch, tmp_path)
    target = tmp_path / "attacker-target"
    target.mkdir()
    (target / "sentinel").write_text("preserve")
    (home / "Downloads").symlink_to(target, target_is_directory=True)
    monkeypatch.setattr(netmax_fetch, "download", _stub_download)

    with pytest.raises(NetMaxError, match="Downloads"):
        netmax_fetch.download_mcp("https://example.test/a", "capture.bin")

    assert (target / "sentinel").read_text() == "preserve"
    assert not (target / "NetMax").exists()


def test_group_or_world_writable_downloads_parent_is_rejected(
        monkeypatch, tmp_path):
    home = _set_home(monkeypatch, tmp_path)
    downloads = home / "Downloads"
    downloads.mkdir(mode=0o700)
    downloads.chmod(0o777)
    monkeypatch.setattr(netmax_fetch, "download", _stub_download)

    with pytest.raises(NetMaxError, match="group/world-writable"):
        netmax_fetch.download_mcp("https://example.test/a", "capture.bin")


def test_non_private_existing_download_root_is_rejected(monkeypatch, tmp_path):
    home = _set_home(monkeypatch, tmp_path)
    root = home / "Downloads" / "NetMax"
    root.mkdir(parents=True, mode=0o700)
    root.chmod(0o750)
    monkeypatch.setattr(netmax_fetch, "download", _stub_download)

    with pytest.raises(NetMaxError, match="mode 0700"):
        netmax_fetch.download_mcp("https://example.test/a", "capture.bin")


def test_download_root_symlink_is_rejected(monkeypatch, tmp_path):
    home = _set_home(monkeypatch, tmp_path)
    downloads = home / "Downloads"
    downloads.mkdir(mode=0o700)
    target = tmp_path / "outside"
    target.mkdir()
    (downloads / "NetMax").symlink_to(target, target_is_directory=True)
    monkeypatch.setattr(netmax_fetch, "download", _stub_download)

    with pytest.raises(NetMaxError, match="download directory"):
        netmax_fetch.download_mcp("https://example.test/a", "capture.bin")

    assert list(target.iterdir()) == []


@pytest.mark.parametrize("target_kind", ["file", "symlink", "directory"])
def test_existing_destination_is_never_replaced(
        monkeypatch, tmp_path, target_kind):
    home = _set_home(monkeypatch, tmp_path)
    root = home / "Downloads" / "NetMax"
    root.mkdir(parents=True, mode=0o700)
    sentinel = tmp_path / "sentinel"
    sentinel.write_bytes(b"untouched")
    existing = root / "capture.bin"
    if target_kind == "file":
        existing.write_bytes(b"original")
    elif target_kind == "symlink":
        existing.symlink_to(sentinel)
    else:
        existing.mkdir()
    called = []
    monkeypatch.setattr(netmax_fetch, "download", lambda *a, **k: called.append(True))

    with pytest.raises(NetMaxError, match="already exists"):
        netmax_fetch.download_mcp("https://example.test/a", "capture.bin")

    assert called == []
    if target_kind == "file":
        assert existing.read_bytes() == b"original"
    elif target_kind == "symlink":
        assert existing.is_symlink()
        assert sentinel.read_bytes() == b"untouched"
    else:
        assert existing.is_dir()


def test_existing_destination_race_is_no_replace(monkeypatch, tmp_path):
    home = _set_home(monkeypatch, tmp_path)
    root = home / "Downloads" / "NetMax"

    def race_download(_url, out_path, **_kwargs):
        _write_private(out_path)
        (root / "capture.bin").write_bytes(b"racer")
        return {"bytes": 7, "mbps": 1.0, "streams_used": 1}

    monkeypatch.setattr(netmax_fetch, "download", race_download)
    with pytest.raises(NetMaxError, match="already exists"):
        netmax_fetch.download_mcp("https://example.test/a", "capture.bin")

    assert (root / "capture.bin").read_bytes() == b"racer"
    assert list(root.glob(".netmax-*")) == []


def test_failed_download_cleans_only_its_private_temporary_files(
        monkeypatch, tmp_path):
    home = _set_home(monkeypatch, tmp_path)
    root = home / "Downloads" / "NetMax"
    (root.parent).mkdir(mode=0o700)

    def fail_after_partial(_url, out_path, **_kwargs):
        _write_private(out_path, b"partial")
        raise NetMaxError("simulated transfer failure")

    monkeypatch.setattr(netmax_fetch, "download", fail_after_partial)
    with pytest.raises(NetMaxError, match="simulated transfer failure"):
        netmax_fetch.download_mcp("https://example.test/a", "capture.bin")

    assert not (root / "capture.bin").exists()
    assert list(root.glob(".netmax-*")) == []


def test_cli_rejects_mcp_name_with_positional_output_before_download(
        monkeypatch, capsys):
    called = []
    monkeypatch.setattr(netmax_fetch, "download_mcp", lambda *a, **k: called.append(True))

    with pytest.raises(SystemExit) as exc:
        netmax.main(["fetch", "https://example.test/a", "manual.bin",
                     "--mcp-output-name", "capture.bin"])

    assert exc.value.code == 2
    assert called == []
    assert "cannot be combined" in capsys.readouterr().err


def test_cli_mcp_mode_passes_only_name_and_keeps_flag_hidden(
        monkeypatch, capsys, tmp_path):
    _set_home(monkeypatch, tmp_path)
    seen = []

    def fake_download(url, output_name, **kwargs):
        seen.append((url, output_name, kwargs["streams"]))
        return tmp_path / "published.bin", {
            "bytes": 7, "mbps": 1.0, "streams_used": 1,
        }

    monkeypatch.setattr(netmax_fetch, "download_mcp", fake_download)
    netmax.main(["fetch", "https://example.test/a", "--mcp-output-name",
                 "capture.bin", "--streams", "3"])
    assert seen == [("https://example.test/a", "capture.bin", 3)]
    assert "published.bin" in capsys.readouterr().out

    with pytest.raises(SystemExit) as exc:
        netmax.main(["fetch", "--help"])
    assert exc.value.code == 0
    assert "--mcp-output-name" not in capsys.readouterr().out


def test_ordinary_cli_fetch_path_semantics_are_unchanged(monkeypatch, capsys):
    seen = []
    monkeypatch.setattr(
        netmax_fetch, "download",
        lambda url, out_path, **kwargs: seen.append((url, out_path)) or {
            "bytes": 7, "mbps": 1.0, "streams_used": 1,
        })

    netmax.main(["fetch", "https://example.test/a", "manual/location.bin"])

    assert seen == [("https://example.test/a", "manual/location.bin")]
    assert "manual/location.bin" in capsys.readouterr().out


def test_output_name_unicode_error():
    class FakeStr(str):
        def encode(self, *a, **k):
            raise UnicodeError("invalid utf-8")

    with pytest.raises(NetMaxError, match="not valid UTF-8"):
        netmax_fetch.validate_mcp_output_name(FakeStr("test"))


def test_mcp_output_root_not_user_owned(monkeypatch, tmp_path):
    _set_home(monkeypatch, tmp_path)
    monkeypatch.setattr(os, "getuid", lambda: 99999)
    with pytest.raises(NetMaxError, match="home directory is not a user-owned directory"):
        netmax_fetch._mcp_output_root()


def test_mcp_output_root_open_oserror(monkeypatch, tmp_path):
    _set_home(monkeypatch, tmp_path)
    orig_open = os.open

    def failing_open(path, *args, **kwargs):
        if str(path).endswith("Downloads"):
            raise OSError("permission denied")
        return orig_open(path, *args, **kwargs)

    monkeypatch.setattr(os, "open", failing_open)
    with pytest.raises(NetMaxError, match="cannot safely open MCP download parent"):
        netmax_fetch._mcp_output_root()


def test_assemble_and_meta_unsafe_symlinks(monkeypatch, tmp_path):
    sym = tmp_path / "symlink_out"
    target = tmp_path / "real_target"
    sym.symlink_to(target)
    with pytest.raises(NetMaxError, match="refusing unsafe output path"):
        netmax_fetch._assemble(sym, [(0, 10)])

    monkeypatch.setattr(netmax_fetch, "_head", lambda *a, **k: (100, True))
    meta_sym = netmax_fetch._meta_path(tmp_path / "file")
    meta_sym.symlink_to(target)
    with pytest.raises(NetMaxError, match="refusing unsafe meta path"):
        netmax_fetch.download("https://download.example/file", tmp_path / "file")

