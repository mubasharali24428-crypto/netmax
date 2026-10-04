"""Tests for the offline dependency/manifest audit (P3 item 50).

Two properties matter more than the individual checks:
  1. It NEVER touches the network. The offline suite's tripwires enforce
     that, and these tests must not disable them.
  2. It does not report phantom findings about itself — an auditor that
     cries wolf on its own source gets ignored by everyone.
"""

from __future__ import annotations

import json

import pytest

import netmax_audit as audit


@pytest.fixture
def repo(tmp_path):
    """A miniature repo with one manifest of each kind."""
    (tmp_path / "desktop").mkdir()
    (tmp_path / "desktop" / "SwiftNetMax").mkdir(parents=True)
    (tmp_path / "pyproject.toml").write_text(
        '[project]\nname = "x"\ndependencies = ["urllib3>=1.26.18"]\n',
        encoding="utf-8")
    (tmp_path / "desktop" / "package.json").write_text(
        json.dumps({"dependencies": {"zod": "3.25.1", "left-pad": "^1.0.0"}}),
        encoding="utf-8")
    (tmp_path / "desktop" / "package-lock.json").write_text(
        json.dumps({"packages": {"node_modules/zod": {}}}), encoding="utf-8")
    (tmp_path / "desktop" / "SwiftNetMax" / "Package.swift").write_text(
        '.package(url: "https://example.com/x.git", from: "1.2.3")', encoding="utf-8")
    (tmp_path / "netmax.py").write_text(
        "import subprocess\nsubprocess.run(['curl'])\n", encoding="utf-8")
    return tmp_path


class TestAdvisoryMatching:
    def test_version_inside_range_is_flagged(self):
        assert audit._in_range("1.26.5", "1.0.0", "1.26.17") is True

    def test_boundary_last_affected_is_inclusive(self):
        assert audit._in_range("1.26.17", "1.0.0", "1.26.17") is True

    def test_patched_version_is_clean(self):
        assert audit._in_range("1.26.18", "1.0.0", "1.26.17") is False

    def test_lower_bound_is_exclusive(self):
        assert audit._in_range("1.0.0", "1.0.0", "1.26.17") is False

    def test_unparseable_version_refuses_rather_than_guessing(self):
        """A version we cannot order must not silently widen the range."""
        assert audit._in_range("latest", "1.0.0", "1.26.17") is False

    def test_malformed_bound_does_not_widen(self):
        assert audit._in_range("9.9.9", "", "1.26.17") is False

    def test_v_prefixed_versions_compare(self):
        assert audit._in_range("v1.26.5", "1.0.0", "1.26.17") is True


class TestManifestChecks:
    def test_floating_pin_is_a_warning(self, repo):
        report = audit.audit(repo)
        pins = [f for f in report["findings"] if f["check"] == "floating_pin"]
        assert any("left-pad" in f["subject"] for f in pins)

    def test_exact_pin_is_not_warned(self, repo):
        report = audit.audit(repo)
        assert not any(f["check"] == "floating_pin" and "zod" in f["subject"]
                       for f in report["findings"])

    def test_advisory_error_surfaces(self, repo):
        (repo / "pyproject.toml").write_text(
            '[project]\ndependencies = ["urllib3>=1.25.0"]\n', encoding="utf-8")
        report = audit.audit(repo)
        errors = [f for f in report["findings"] if f["check"] == "advisory"]
        assert errors and errors[0]["level"] == "error"

    def test_lockfile_drift_is_reported(self, repo):
        report = audit.audit(repo)
        assert any(f["check"] == "lockfile_drift" and "left-pad" in f["subject"]
                   for f in report["findings"])

    def test_unparseable_package_json_is_an_error(self, repo):
        (repo / "desktop" / "package.json").write_text("{nope", encoding="utf-8")
        report = audit.audit(repo)
        assert any(f["check"] == "unparseable" for f in report["findings"])


class TestShellReach:
    def test_real_shell_true_is_an_error(self, repo):
        (repo / "netmax.py").write_text(
            "import subprocess\nsubprocess.run('ls', shell=True)\n",
            encoding="utf-8")
        report = audit.audit(repo)
        assert any(f["check"] == "shell_reach" for f in report["findings"])

    def test_argv_form_is_clean(self, repo):
        report = audit.audit(repo)
        assert not any(f["check"] == "shell_reach" for f in report["findings"])

    def test_auditor_does_not_flag_itself(self):
        """It contains those literals in its own patterns — must not self-report."""
        report = audit.audit(".")
        assert not any(f["check"] == "shell_reach" for f in report["findings"]), \
            "the auditor reported itself"


class TestToolCount:
    def _server(self, repo, declared, names):
        calls = ",\n".join(f'  server.tool(\n    "{n}"' for n in names)
        (repo / "desktop" / "netmax-mcp-server.mjs").write_text(
            f"const TOOL_COUNT = {declared};\n{calls},\n", encoding="utf-8")

    def test_mismatch_is_an_error(self, repo):
        self._server(repo, 15, ["a", "b", "c"])
        report = audit.audit(repo)
        tc = [f for f in report["findings"] if f["check"] == "tool_count"]
        assert tc and tc[0]["level"] == "error"

    def test_agreement_is_clean(self, repo):
        self._server(repo, 3, ["a", "b", "c"])
        report = audit.audit(repo)
        assert not any(f["check"] == "tool_count" for f in report["findings"])

    def test_missing_constant_is_a_warning(self, repo):
        (repo / "desktop" / "netmax-mcp-server.mjs").write_text(
            'server.tool(\n  "a"),\n', encoding="utf-8")
        report = audit.audit(repo)
        tc = [f for f in report["findings"] if f["check"] == "tool_count"]
        assert tc and tc[0]["level"] == "warn"


class TestRealRepo:
    def test_this_repo_has_no_errors(self):
        """The gate that matters: our own manifests must be clean."""
        report = audit.audit(".")
        assert report["errors"] == 0, report["findings"]

    def test_this_repo_scans_the_expected_manifests(self):
        scanned = " ".join(audit.audit(".")["files_scanned"])
        for name in ("pyproject.toml", "package.json", "Package.swift"):
            assert name in scanned, name


class TestAuditSubcommand:
    def test_runs_and_prints_json(self, capsys):
        import netmax
        netmax.main(["audit", "--root", "."])
        out = json.loads(capsys.readouterr().out)
        assert "errors" in out and "findings" in out

    def test_strict_exits_nonzero_on_error(self, repo, monkeypatch):
        import netmax
        # Give the repo a genuine error-level finding first.
        (repo / "pyproject.toml").write_text(
            '[project]\ndependencies = ["urllib3>=1.25.0"]\n', encoding="utf-8")
        monkeypatch.chdir(repo)
        with pytest.raises(SystemExit):
            netmax.main(["audit", "--strict"])
        assert True      # the SystemExit is the assertion

    def test_strict_ignores_warnings(self, repo, monkeypatch):
        import netmax
        monkeypatch.chdir(repo)      # warnings only
        netmax.main(["audit", "--strict"])

    def test_strict_passes_on_a_clean_repo(self, capsys):
        import netmax
        netmax.main(["audit", "--root", ".", "--strict"])

    def test_list_advisories_prints_the_table(self, capsys):
        import netmax
        netmax.main(["audit", "--list-advisories"])
        out = json.loads(capsys.readouterr().out)
        assert "urllib3" in out
        assert out["urllib3"][0]["affected_through"]


class TestImportClosure:
    """The bug this check exists for: a lazy import + a missing py-modules
    entry leaves `import netmax` green and breaks one mode at runtime."""

    def test_missing_entry_is_an_error(self, repo):
        (repo / "netmax_sibling.py").write_text("x = 1\n", encoding="utf-8")
        (repo / "netmax.py").write_text(
            "def go():\n    import netmax_sibling\n", encoding="utf-8")
        # The fixture's pyproject declares no py-modules, which the check
        # treats as "nothing to compare against". Declare the closed list.
        (repo / "pyproject.toml").write_text(
            '[project]\ndependencies = []\npy-modules = ["netmax"]\n',
            encoding="utf-8")
        report = audit.audit(repo)
        hit = [f for f in report["findings"] if f["check"] == "unpackaged_import"]
        assert hit and hit[0]["subject"] == "netmax_sibling"
        assert hit[0]["level"] == "error"

    def test_absent_py_modules_key_is_not_an_error(self, repo):
        """No py-modules means there is nothing to compare — stay quiet."""
        report = audit.audit(repo)
        assert not any(f["check"] == "unpackaged_import"
                       for f in report["findings"])

    def test_declared_but_absent_is_an_error(self, repo):
        report = audit.audit(repo)
        assert not any(f["check"] == "missing_module"
                       for f in report["findings"])

    def test_closed_loop_is_clean(self, repo):
        (repo / "netmax_sibling.py").write_text("x = 1\n", encoding="utf-8")
        (repo / "netmax.py").write_text(
            "def go():\n    import netmax_sibling\n", encoding="utf-8")
        (repo / "pyproject.toml").write_text(
            '[project]\ndependencies = []\n'
            'py-modules = ["netmax", "netmax_sibling"]\n', encoding="utf-8")
        report = audit.audit(repo)
        assert not any(f["check"] in ("unpackaged_import", "missing_module")
                       for f in report["findings"])

    def test_this_repo_declares_everything_it_imports(self):
        """The gate: our own package must satisfy the closure it enforces."""
        report = audit.audit(".")
        assert not any(f["check"] in ("unpackaged_import", "missing_module")
                       for f in report["findings"]), report["findings"]
