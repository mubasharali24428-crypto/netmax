#!/usr/bin/env python3
"""Dependency and manifest audit (P3 item 50).

The app ships a signed bundle that loads Python at runtime, an MCP server
that executes on a user's machine, and a Swift package. Each of those can
be broken — or exploited — by something upstream, and none of them are
covered by the test suite: a test cannot tell you a dependency was yanked.

This is a static check over the manifests in this repo. It is deliberately
OFFLINE: no advisory-service calls, no network, no telemetry. It reports
what it can prove from the files themselves plus a small, versioned table
of known-bad ranges that ships with the code so the tool keeps working
offline. That table is the honest limit of this tool — it knows only what
it has been told.

What it checks:
  - unpinned or floating dependency versions in the manifests we ship
  - a dependency present in a manifest but absent from the lockfile
  - runtime-loaded Python reaching for a shell
  - the MCP tool count the banners advertise vs the tools actually defined
  - known-bad version ranges from the local advisory table
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# Known-bad ranges, offline. `last_affected` is INCLUSIVE: a version equal
# to it is still affected. Extend this as advisories land; it is a
# hand-maintained table precisely so this tool never needs the network.
# Keyed by package name, matched against the pinned version only.
ADVISORIES: dict[str, list[tuple[str, str, str]]] = {
    # (introduced_exclusive, last_affected_inclusive, why)
    "urllib3": [
        ("1.0.0", "1.26.17",
         "redirects and cookies could leak credentials across hosts"),
    ],
    "requests": [
        ("2.0.0", "2.31.0",
         "Proxy-Authorization header could leak on redirect"),
    ],
    "setuptools": [
        ("0.0.0", "65.5.0",
         "package_index download path traversal"),
    ],
}


@dataclass
class Finding:
    """One audit result."""
    level: str            # error | warn | info
    check: str
    subject: str
    detail: str
    advice: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {"level": self.level, "check": self.check,
                "subject": self.subject, "detail": self.detail,
                "advice": self.advice}


@dataclass
class AuditReport:
    findings: list[Finding] = field(default_factory=list)
    files_scanned: list[str] = field(default_factory=list)

    def add(self, *args: Any, **kwargs: Any) -> None:
        self.findings.append(Finding(*args, **kwargs))

    @property
    def errors(self) -> int:
        return sum(1 for f in self.findings if f.level == "error")

    @property
    def warnings(self) -> int:
        return sum(1 for f in self.findings if f.level == "warn")

    def to_dict(self) -> dict[str, Any]:
        return {
            "files_scanned": list(self.files_scanned),
            "errors": self.errors,
            "warnings": self.warnings,
            "findings": [f.to_dict() for f in self.findings],
        }


def _parse_version(text: str) -> tuple[int, ...]:
    """Loose PEP440-ish parse to a comparable tuple.

    Deliberately not a full implementation: it extracts the leading numeric
    components, which is enough to order the ranges we ship and to refuse
    to guess when it cannot.
    """
    parts = re.findall(r"\d+", text or "")
    return tuple(int(p) for p in parts[:4]) if parts else ()


def _in_range(version: str, low_exclusive: str, high_inclusive: str) -> bool:
    v = _parse_version(version)
    if not v:
        return False
    lo = _parse_version(low_exclusive)
    hi = _parse_version(high_inclusive)
    # A malformed bound must not silently widen the range.
    if not lo or not hi:
        return False
    width = max(len(v), len(lo), len(hi))

    def pad(seq: tuple[int, ...]) -> tuple[int, ...]:
        return seq + (0,) * (width - len(seq))

    v, lo, hi = pad(v), pad(lo), pad(hi)
    return lo < v <= hi


def audit_manifest_versions(root: Path, report: AuditReport) -> None:
    """pyproject runtime deps must be pinned exactly."""
    path = root / "pyproject.toml"
    if not path.exists():
        return
    report.files_scanned.append(str(path.relative_to(root)))
    text = path.read_text(encoding="utf-8")

    block = re.search(r"dependencies\s*=\s*\[(.*?)\]", text, re.S)
    if not block:
        return
    for raw in re.findall(r"[\"']([^\"']+)[\"']", block.group(1)):
        name, _, spec = raw.partition(">=")
        if not spec:
            continue
        version = spec.strip()
        for low, high, why in ADVISORIES.get(name.strip(), []):
            if _in_range(version, low, high):
                report.add("error", "advisory", name.strip(),
                           f"pinned {version} is in an affected range "
                           f"(> {low}, <= {high})", why)
                break

    # A `>=` on a runtime dependency is a floating pin.
    for raw in re.findall(r"[\"']([^\"']+)[\"']", block.group(1)):
        if ">=" in raw or "~>" in raw:
            name = raw.split(">=")[0].split("~>")[0].strip()
            report.add("warn", "floating_pin", name,
                       f"runtime dependency uses a range: {raw!r}",
                       "pin exactly so the signed bundle is reproducible")


def audit_node_manifest(root: Path, report: AuditReport) -> None:
    """package.json runtime deps must be exact and present in the lockfile."""
    pkg = root / "desktop" / "package.json"
    if not pkg.exists():
        return
    report.files_scanned.append(str(pkg.relative_to(root)))
    try:
        data = json.loads(pkg.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        report.add("error", "unparseable", str(pkg.relative_to(root)),
                   f"package.json is not valid JSON: {exc}")
        return

    deps = data.get("dependencies") or {}
    for name, spec in deps.items():
        if spec.startswith("^") or spec.startswith("~"):
            report.add("warn", "floating_pin", name,
                       f"runtime dependency uses a range: {spec}",
                       "pin exactly — the MCP server executes on user machines")
        entry = ADVISORIES.get(name)
        if entry:
            bare = spec.lstrip("^~")
            for low, high, why in entry:
                if _in_range(bare, low, high):
                    report.add("error", "advisory", name,
                               f"{spec} is in an affected range (<= {high})",
                               why)
                    break

    lock = root / "desktop" / "package-lock.json"
    if lock.exists():
        report.files_scanned.append(str(lock.relative_to(root)))
        try:
            lock_data = json.loads(lock.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            lock_data = {}
        locked = set((lock_data.get("packages") or {}).keys())
        for name in deps:
            if f"node_modules/{name}" not in locked and name not in locked:
                report.add("warn", "lockfile_drift", name,
                           "in package.json dependencies but absent from "
                           "package-lock.json",
                           "run npm install to refresh the lockfile")


def audit_swift_manifest(root: Path, report: AuditReport) -> None:
    """Report Swift package dependencies so they are at least visible."""
    path = root / "desktop" / "SwiftNetMax" / "Package.swift"
    if not path.exists():
        return
    report.files_scanned.append(str(path.relative_to(root)))
    text = path.read_text(encoding="utf-8")
    for name, spec in re.findall(
            r'\.package\s*\(\s*url:\s*"[^"]+"[^)]*?name:\s*"([^"]+)"[^)]*?'
            r'(?:from|exact|branch|revision):\s*"([^"]+)"', text, re.S):
        pinned = spec.startswith("v") or re.match(r"^\d", spec)
        report.add(
            "info" if pinned else "warn",
            "swift_dependency", name, f"resolved from {spec!r}",
            "" if pinned else "a branch/revision pin makes the build "
                              "irreproducible — prefer an exact version")


def audit_shell_reach(root: Path, report: AuditReport) -> None:
    """Flag shell=True / os.system in the engine and AI modules.

    Skips this file: it necessarily CONTAINS those literals in its own
    patterns, so scanning itself reports two phantom errors every run. An
    auditor that cries wolf about itself gets ignored.
    """
    targets = [p for p in root.glob("netmax*.py")
               if p.is_file() and p.name != Path(__file__).name]
    if not targets:
        return
    for path in sorted(targets):
        rel = path.relative_to(root)
        report.files_scanned.append(str(rel))
        for number, line in enumerate(
                path.read_text(encoding="utf-8").splitlines(), 1):
            if "shell=True" in line or "os.system(" in line:
                report.add("error", "shell_reach", f"{rel}:{number}",
                           "spawns a shell or os.system",
                           "argv lists keep arguments un-interpolated")


def audit_tool_count(root: Path, report: AuditReport) -> None:
    """The MCP banner's tool count must match the tools actually defined.

    A hardcoded count silently under-reports the moment a tool is added,
    which is how a missing tool ships unnoticed.
    """
    server = root / "desktop" / "netmax-mcp-server.mjs"
    if not server.exists():
        return
    rel = server.relative_to(root)
    report.files_scanned.append(str(rel))
    text = server.read_text(encoding="utf-8")

    declared = re.search(r"const\s+TOOL_COUNT\s*=\s*(\d+)", text)
    actual = len(set(re.findall(r'server\.tool\(\s*\n?\s*"([a-z_]+)"', text)))
    if declared is None:
        report.add("warn", "tool_count", str(rel),
                   "no TOOL_COUNT constant found",
                   "derive the banner count from a single constant")
        return
    if int(declared.group(1)) != actual:
        report.add("error", "tool_count", str(rel),
                   f"banner advertises {declared.group(1)} tools but "
                   f"{actual} are defined",
                   "set TOOL_COUNT from the real definition count")


def audit_import_closure(root: Path, report: AuditReport) -> None:
    """Every locally-imported engine module must be declared in py-modules.

    `netmax.py` imports its siblings lazily inside functions, so a missing
    py-modules entry does NOT break `import netmax` — it breaks that one
    mode at runtime with a bare ModuleNotFoundError. Nothing else in the
    suite can see this, and the console script looks healthy until a user
    runs the affected mode.
    """
    pyproject = root / "pyproject.toml"
    if not pyproject.exists():
        return
    match = re.search(r"py-modules\s*=\s*\[(.*?)\]", pyproject.read_text(
        encoding="utf-8"), re.S)
    declared = set(re.findall(r"\"([^\"]+)\"",
                              match.group(1) if match else ""))
    if not declared:
        return

    report.files_scanned.append("pyproject.toml")
    # Any local module that some shipped module imports.
    sources = sorted(p for p in root.glob("*.py")
                     if p.is_file() and not p.name.startswith("_"))
    imported: set[str] = set()
    pattern = re.compile(r"^\s*(?:from|import)\s+(netmax[a-z_]*|netmetrics)\b",
                         re.M)
    for path in sources:
        text = path.read_text(encoding="utf-8", errors="replace")
        # Skip the auditor's own pattern definitions.
        if path.name == Path(__file__).name:
            continue
        imported |= set(pattern.findall(text))

    for name in sorted(imported):
        if name not in declared:
            report.add("error", "unpackaged_import", name,
                       f"{name}.py is imported by the package but is not in "
                       "py-modules — that mode fails at runtime with "
                       "ModuleNotFoundError while `import netmax` still works",
                       f'add "{name}" to py-modules')

    # And the reverse: declared but absent from disk.
    for name in sorted(declared):
        if not (root / f"{name}.py").exists():
            report.add("error", "missing_module", name,
                       f"py-modules declares {name} but {name}.py is absent",
                       "remove the entry or restore the file")


def audit(root: str | Path = ".") -> dict[str, Any]:
    """Run every check and return a report."""
    base = Path(root).resolve()
    report = AuditReport()
    audit_manifest_versions(base, report)
    audit_node_manifest(base, report)
    audit_swift_manifest(base, report)
    audit_shell_reach(base, report)
    audit_tool_count(base, report)
    audit_import_closure(base, report)
    return report.to_dict()