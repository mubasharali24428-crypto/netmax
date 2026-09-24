#!/usr/bin/env bash
# sync_versions.sh — Task 5 version/release hygiene.
#
# Reads the canonical app version from desktop/package.json and keeps every
# other version source in lockstep:
#   1. pyproject.toml           (Python package version)
#   2. homebrew cask            (Casks/netmax.rb version line)
#   3. RELEASE-NOTES.md         (reports current version at the top)
#
# Modes:
#   ./sync_versions.sh              # apply: propagate package.json → all
#   ./sync_versions.sh --check      # CI/dry-run: exit 1 on any drift
#   ./sync_versions.sh 1.0.7        # set package.json to 1.0.7, then apply
#
# Design notes:
#   • package.json is THE source of truth (build_app.sh already reads it
#     for APP_VERSION / CFBundleShortVersionString).
#   • Cask sha256 is intentionally NOT touched — it must be recomputed
#     against the actual DMG at release time (see build_dmg.sh).
#   • --check never mutates files; it only reports and exits non-zero.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PKG_JSON="$REPO_ROOT/desktop/package.json"
PYPROJECT="$REPO_ROOT/pyproject.toml"
RELEASE_NOTES="$REPO_ROOT/RELEASE-NOTES.md"
CASK=""
for candidate in \
    "$REPO_ROOT/../homebrew-netmax/Casks/netmax.rb" \
    "$HOME/homebrew-netmax/Casks/netmax.rb" \
    "/Users/user/homebrew-netmax/Casks/netmax.rb"; do
  if [[ -f "$candidate" ]]; then CASK="$candidate"; break; fi
done

CHECK=0
NEW_VERSION=""

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \?//'
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    -h|--help) usage ;;
    -*) echo "unknown flag: $1" >&2; usage ;;
    *) NEW_VERSION="$1"; shift ;;
  esac
done

# --- read/write helpers -------------------------------------------------------

read_package_version() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$PKG_JSON"
}

set_package_version() {
  local v="$1"
  python3 - "$PKG_JSON" "$v" <<'PY'
import json, sys, pathlib
path, ver = pathlib.Path(sys.argv[1]), sys.argv[2]
data = json.loads(path.read_text(encoding="utf-8"))
data["version"] = ver
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
}

read_pyproject_version() {
  python3 -c 'import re,sys; t=open(sys.argv[1]).read(); m=re.search(r"^version\s*=\s*\"([^\"]+)\"", t, re.M); print(m.group(1) if m else "")' "$PYPROJECT"
}

set_pyproject_version() {
  local v="$1"
  python3 - "$PYPROJECT" "$v" <<'PY'
import re, sys, pathlib
path, ver = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text(encoding="utf-8")
text, n = re.subn(r'(^version\s*=\s*")[^"]+(")', rf'\g<1>{ver}\g<2>', text, count=1, flags=re.M)
if n != 1:
    raise SystemExit("pyproject version= line not found")
path.write_text(text, encoding="utf-8")
PY
}

read_cask_version() {
  [[ -n "$CASK" ]] || { echo ""; return; }
  python3 -c 'import re,sys; t=open(sys.argv[1]).read(); m=re.search(r"version\s+\"([^\"]+)\"", t); print(m.group(1) if m else "")' "$CASK"
}

set_cask_version() {
  local v="$1"
  [[ -n "$CASK" ]] || return 0
  python3 - "$CASK" "$v" <<'PY'
import re, sys, pathlib
path, ver = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text(encoding="utf-8")
text, n = re.subn(r'(version\s+")[^"]+(")', rf'\g<1>{ver}\g<2>', text, count=1)
if n != 1:
    raise SystemExit("cask version= line not found")
path.write_text(text, encoding="utf-8")
PY
}

release_notes_has_version() {
  local v="$1"
  [[ -f "$RELEASE_NOTES" ]] || return 1
  # Accept a heading like "## 1.0.7" / "## v1.0.7" / "### 1.0.7 (…)".
  grep -Eq "^#+[[:space:]]*v?${v}([^0-9]|$)" "$RELEASE_NOTES"
}

# --- optional: bump package.json first --------------------------------------

VERSION="$(read_package_version)"
if [[ -n "$NEW_VERSION" ]]; then
  if [[ "$NEW_VERSION" != "$VERSION" ]]; then
    if [[ "$CHECK" -eq 1 ]]; then
      echo "FAIL: --check does not allow a version argument (would mutate)" >&2
      exit 2
    fi
    set_package_version "$NEW_VERSION"
    VERSION="$NEW_VERSION"
    echo "package.json → $VERSION"
  fi
fi

# --- collect current values --------------------------------------------------

PY_V="$(read_pyproject_version)"
CASK_V="$(read_cask_version)"

drift=0
report() { # label current expected
  local label="$1" current="$2" expected="$3"
  if [[ "$current" == "$expected" ]]; then
    echo "OK    $label = $current"
  else
    echo "DRIFT $label = ${current:-<missing>} (expected $expected)"
    drift=1
  fi
}

echo "canonical (package.json): $VERSION"
report "pyproject.toml" "$PY_V" "$VERSION"
if [[ -n "$CASK" ]]; then
  report "cask $(basename "$(dirname "$CASK")")/$(basename "$CASK")" "$CASK_V" "$VERSION"
else
  echo "WARN  cask file not found — skipped"
fi
if release_notes_has_version "$VERSION"; then
  echo "OK    RELEASE-NOTES.md has a $VERSION section"
else
  echo "DRIFT RELEASE-NOTES.md missing a \"$VERSION\" heading"
  drift=1
fi

# --- apply or exit ------------------------------------------------------------

if [[ "$CHECK" -eq 1 ]]; then
  if [[ "$drift" -ne 0 ]]; then
    echo ""
    echo "sync_versions: drift detected (re-run without --check to fix)"
    exit 1
  fi
  echo "sync_versions: all version sources in sync"
  exit 0
fi

if [[ "$drift" -eq 0 ]]; then
  echo "sync_versions: nothing to do"
  exit 0
fi

if [[ "$PY_V" != "$VERSION" ]]; then
  set_pyproject_version "$VERSION"
  echo "updated pyproject.toml → $VERSION"
fi
if [[ -n "$CASK" && "$CASK_V" != "$VERSION" ]]; then
  set_cask_version "$VERSION"
  echo "updated cask → $VERSION (sha256 left alone — recompute at DMG build)"
fi
if ! release_notes_has_version "$VERSION"; then
  if [[ -f "$RELEASE_NOTES" ]]; then
    python3 - "$RELEASE_NOTES" "$VERSION" <<'PY'
import sys, pathlib
path, ver = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text(encoding="utf-8")
entry = f"## {ver}\n\n- TBD: describe this release.\n\n"
# Insert after the first top-level heading if present, else prepend.
lines = text.splitlines(keepends=True)
insert_at = 0
for i, line in enumerate(lines):
    if line.startswith("# "):
        insert_at = i + 1
        # skip a blank line after the title
        while insert_at < len(lines) and lines[insert_at].strip() == "":
            insert_at += 1
        break
lines.insert(insert_at, entry)
path.write_text("".join(lines), encoding="utf-8")
PY
    echo "added RELEASE-NOTES.md section for $VERSION"
  else
    printf '## %s\n\n- TBD: describe this release.\n' "$VERSION" > "$RELEASE_NOTES"
    echo "created RELEASE-NOTES.md for $VERSION"
  fi
fi

echo "sync_versions: done (sha256 not touched — recompute when the DMG is rebuilt)"
