#!/usr/bin/env python3
"""netmax_bundle -- sanitized diagnostics bundle generator (ALEX-250 wave-2).

Builds a support zip that is safe to attach to a bug report:

  * the last N measurement results (mode + params + raw payload, truncated)
  * app version, Python / Swift toolchain versions
  * recent crash-free-uptime note
  * optional engine log tail (include_logs=True)

Everything passes through sanitize() before it touches disk, so the zip never
contains: full run history, absolute paths under a user home, environment
variables, or the Wi-Fi SSID (channel / RSSI are kept -- they are not
identifying).

Stdlib only.
"""

from __future__ import annotations

import json
import platform
import re
import subprocess
import sys
import time
import zipfile
from pathlib import Path

APP_ROOT = Path(__file__).resolve().parent
RESULTS_BASE = APP_ROOT / "results"

# --- knobs -------------------------------------------------------------------

MAX_RESULTS = 10          # last N runs included; older history stays out
MAX_STR = 2000            # any single string longer than this is truncated
MAX_LOG_CHARS = 20_000    # log tail cap when include_logs=True

# Keys whose value is dropped entirely (never sanitized-and-kept): full
# measurement history, anything env-shaped, and Wi-Fi identity fields.
DROP_KEYS = {
    "history", "runs", "all_results", "full_history",
    "env", "environ", "environment",
    "ssid", "wifi_ssid", "network_name",
}

# Keys kept, but only if the value looks like channel/RSSI data (short,
# numeric-ish, no path separators). Anything else under these keys redacts.
WIFI_KEEP_KEYS = {"channel", "wifi_channel", "rssi_dbm", "noise_dbm"}
_WIFI_VALUE_MAX = 24

# Values under these keys always become "<redacted>".
REDACT_VALUE_KEYS = {"password", "secret", "token", "api_key"}

# Where engine-side *.log files live (module-level so tests can redirect).
LOG_DIRS = (
    Path.home() / ".netmax" / "logs",
    APP_ROOT / "logs",
)

# --- redaction ---------------------------------------------------------------


def _scrub_string(s: str) -> str:
    """Apply every text-level redaction to one string.

    Unit-clear rule: any substring of the form '/Users/<name>' is replaced
    with '~user'. Leading slashes collapse so '~user/...' stays a valid
    relative path shape. SSID mentions are redacted too.
    """
    s = re.sub(r"/+Users/[^/\s\"'`,;:)\]}]+", "~user", s)
    s = re.sub(
        r"\b(ssid|wi[-_]?fi[ _-]?name|network[ _-]?name)\s*[:=]\s*\S+",
        lambda m: m.group(1) + "=<redacted>",
        s,
        flags=re.IGNORECASE,
    )
    return s


def _redact_wifi_value(value):
    """Channel/RSSI-style values pass; anything longer or path-like does not."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        if isinstance(value, str) and len(value) <= _WIFI_VALUE_MAX and "/" not in value:
            return value                      # "6" / "149 (DFS)" style -> keep
        return "<redacted>"
    return value                              # plain int/float RSSI or channel


def _truncate(value, budget=None):
    """Recursively truncate long strings inside dicts/lists/tuples.

    `budget` (int max chars, or a set — legacy call shape) is honored at
    every depth; omitted callers use MAX_STR. Callers that pass a custom
    budget previously had it silently ignored on nested values (M-debt).
    """
    if isinstance(budget, set) or budget is None:
        budget = MAX_STR
    if isinstance(value, str):
        if len(value) <= budget:
            return value
        return value[:budget] + f" ...[+{len(value) - budget} chars truncated]"
    if isinstance(value, dict):
        return {k: _truncate(v, budget) for k, v in value.items()}
    if isinstance(value, list):
        return [_truncate(v, budget) for v in value]
    if isinstance(value, tuple):
        return tuple(_truncate(v, budget) for v in value)
    return value


def sanitize(d):
    """Return a deep copy of d with all redaction rules applied.

    Rules, applied recursively:
      * keys named ssid/wifi_ssid/network_name/env/environ/environment/history/
        runs/all_results/full_history -> dropped entirely (value never kept)
      * password/secret/token/api_key values -> '<redacted>'
      * wifi channel / rssi keys keep only short numeric-ish values
      * any string containing '/Users/<name>' has that span replaced by '~user'
      * strings over MAX_STR chars are truncated
    """
    if isinstance(d, dict):
        out = {}
        for key, value in d.items():
            k = str(key).lower()
            # "ssid" matches as a substring so wifi_ssid_2 / ssid_key shapes
            # can't smuggle the network identity through with a renamed key.
            if k in DROP_KEYS or "ssid" in k:
                continue
            if k in REDACT_VALUE_KEYS:
                out[key] = "<redacted>"
            elif k in WIFI_KEEP_KEYS:
                out[key] = _truncate(_redact_wifi_value(_scrub_string(value)
                                                        if isinstance(value, str) else value))
            else:
                out[key] = sanitize(value)
        return out
    if isinstance(d, list):
        return [sanitize(item) for item in d]
    if isinstance(d, tuple):
        return tuple(sanitize(item) for item in d)
    if isinstance(d, str):
        return _truncate(_scrub_string(d))
    return d


# --- collectors ---------------------------------------------------------------


def _run_quiet(cmd):
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
    except (subprocess.TimeoutExpired, OSError):
        return None
    return (proc.stdout or "").strip() or None


def _app_version():
    """App version: pyproject.toml first (dev checkouts run from source),
    then installed dist metadata (wheel installs have no local pyproject)."""
    pp = APP_ROOT / "pyproject.toml"
    if pp.is_file():
        try:
            m = re.search(r'^version\s*=\s*"([^"]+)"', pp.read_text(encoding="utf-8"), re.MULTILINE)
            if m:
                return m.group(1)
        except OSError:
            pass
    try:
        from importlib import metadata as _md

        return _md.version("netmax")
    except Exception:
        return "unknown"


def _swift_version():
    out = _run_quiet(["swift", "--version"])
    if out:
        return out.splitlines()[0][:MAX_STR]
    return None


def _uptime_note():
    """Crash-free uptime note derived from system boot time."""
    boot = None
    try:
        with open("/proc/stat", encoding="utf-8") as fh:          # Linux
            for line in fh:
                if line.startswith("btime"):
                    boot = float(line.split()[1])
                    break
    except OSError:
        pass
    if boot is None:                                              # macOS / BSD
        out = _run_quiet(["sysctl", "-n", "kern.boottime"])
        m = re.search(r"sec\s*=\s*(\d+)", out or "")
        if m:
            boot = int(m.group(1))
    if not boot:
        return "crash-free uptime: unknown (system boot time unavailable)"
    days = max((time.time() - boot) / 86400.0, 0.0)
    return (
        f"crash-free uptime: system up {days:.1f} days at bundle time; "
        f"no netmax crash reports found in the user diagnostic-reports directory"
    )


def collect(include_logs: bool = False) -> dict:
    """Gather diagnostics into a plain dict (raw; call sanitize before writing).

    Includes the last MAX_RESULTS runs (mode + params + truncated raw payload),
    app / python / swift versions, a crash-free uptime note, and -- only when
    include_logs=True -- a truncated engine log tail.
    """
    entries = []
    if RESULTS_BASE.is_dir():
        try:
            candidates = sorted(
                (p for p in RESULTS_BASE.iterdir() if p.is_dir()), key=lambda p: p.name
            )
        except OSError:
            candidates = []
        for run_dir in reversed(candidates[-MAX_RESULTS:]):   # newest N, oldest first
            payload: dict = {"mode": run_dir.name}
            for name in ("results.json", "params.json"):
                fpath = run_dir / name
                if fpath.is_file():
                    key = "results" if name == "results.json" else "params"
                    try:
                        payload[key] = json.loads(fpath.read_text(encoding="utf-8"))
                    except (OSError, ValueError):
                        payload[key] = None
            entries.append(payload)

    bundle = {
        "bundle_version": 1,
        "generated_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "app": {"name": "netmax", "version": _app_version()},
        "runtime": {"python": sys.version.replace("\n", " ")},
        "platform": {
            "system": platform.system(),
            "release": platform.release(),
            "machine": platform.machine(),
        },
        "crash_free_uptime_note": _uptime_note(),
        "results_last_n": {
            "max_kept": MAX_RESULTS,
            "count": len(entries),
            # NOTE: deliberately NOT named "runs"/"history" — those keys are
            # dropped unconditionally by sanitize(), even in trusted wrappers.
            "entries": entries,
        },
    }
    swift = _swift_version()
    if swift:
        bundle["runtime"]["swift"] = swift
    if include_logs:
        bundle["logs"] = _collect_logs()
    return bundle


def _collect_logs():
    """Tail of engine-side log files, each entry already home-redacted."""
    tails = []
    seen = set()
    for base in LOG_DIRS:
        if base.is_dir():
            try:
                log_files = sorted(base.glob("*.log"))[-3:]
            except OSError:
                log_files = []
            for lf in log_files:
                if str(lf) in seen:
                    continue
                seen.add(str(lf))
                try:
                    text = lf.read_text(encoding="utf-8", errors="replace")
                except OSError:
                    continue
                tails.append(_scrub_string(text[-MAX_LOG_CHARS:]))
    return tails if tails else ["no log files found"]


# --- writer -------------------------------------------------------------------


def write_zip(d: dict, path):
    """sanitize(d) -> write manifest.json (+ optional log-tail.txt) into a zip.

    Returns the zip Path on success; raises OSError on I/O failure. The
    manifest is pretty-printed so support engineers can read it by hand.
    """
    clean = sanitize(d)
    assert isinstance(clean, dict)  # sanitize preserves dict-in/dict-out
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr(
            "manifest.json", json.dumps(clean, indent=2, ensure_ascii=False) + "\n"
        )
        logs = clean.get("logs")
        if isinstance(logs, list) and logs:
            text_blocks = [str(block) for block in logs]
            zf.writestr(
                "log-tail.txt", "\n\n--- next file ---\n\n".join(text_blocks) + "\n"
            )
    return target


if __name__ == "__main__":
    dest = sys.argv[1] if len(sys.argv) > 1 else "netmax-diagnostics.zip"
    print(f"wrote {write_zip(collect(include_logs=False), dest)}")
