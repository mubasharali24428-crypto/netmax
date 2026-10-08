#!/usr/bin/env bash
# verify_reproducible_build.sh — compare two clean universal builds (C-16-HARNESS)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_SHA="${1:-}"

if [[ -z "$SOURCE_SHA" ]]; then
  echo "ERROR: missing source commit SHA. Usage: $0 <commit-sha>" >&2
  exit 1
fi

if ! git -C "$REPO_ROOT" rev-parse --verify "$SOURCE_SHA^{commit}" >/dev/null 2>&1; then
  echo "ERROR: commit SHA '$SOURCE_SHA' does not resolve to a valid commit" >&2
  exit 1
fi
FULL_SHA="$(git -C "$REPO_ROOT" rev-parse --verify "$SOURCE_SHA^{commit}")"

for tool in git tar uv npm swift codesign shasum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required tool '$tool' is missing or not executable on PATH" >&2
    exit 1
  fi
done

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/netmax-repro-build.XXXXXX")"
MANIFEST_A="$TEMP_ROOT/manifest-a.txt"
MANIFEST_B="$TEMP_ROOT/manifest-b.txt"
SAVED_A="$(mktemp "${TMPDIR:-/tmp}/netmax-repro-manifest-a.XXXXXX")"
SAVED_B="$(mktemp "${TMPDIR:-/tmp}/netmax-repro-manifest-b.XXXXXX")"

cleanup() {
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

SOURCE_DATE_EPOCH="$(git -C "$REPO_ROOT" show -s --format=%ct "$FULL_SHA")"

build_copy() {
  local label="$1"
  local manifest="$2"
  local temp_source="$TEMP_ROOT/$label"

  mkdir -p "$temp_source"
  git -C "$REPO_ROOT" archive "$FULL_SHA" | tar -x -C "$temp_source"

  ( cd "$temp_source" && uv sync --frozen )
  ( cd "$temp_source/desktop" && npm ci --ignore-scripts )
  ( cd "$temp_source/plugins/vscode" && if [[ -f package-lock.json ]]; then npm ci --ignore-scripts; fi )
  ( cd "$temp_source/desktop/SwiftNetMax" && swift package resolve --force-resolved-versions )

  SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" bash "$temp_source/desktop/scripts/build_app.sh"

  local app="$temp_source/desktop/build/NetMaxDesktop.app"
  codesign --remove-signature "$app/Contents/MacOS/NetMaxDesktop" 2>/dev/null || true
  rm -rf "$app/Contents/_CodeSignature"

  ( cd "$app" && find . -type f ! -path '*/_CodeSignature*' | sort | while IFS= read -r f; do
      shasum -a 256 "$f"
    done ) > "$manifest"
}

echo "Building source-a for commit $FULL_SHA..."
build_copy "source-a" "$MANIFEST_A"
cp "$MANIFEST_A" "$SAVED_A"

echo "Building source-b for commit $FULL_SHA..."
build_copy "source-b" "$MANIFEST_B"
cp "$MANIFEST_B" "$SAVED_B"

echo "Comparing manifests for commit $FULL_SHA..."
if [[ -n "${REPRO_MANIFEST_DIR:-}" ]]; then
  mkdir -p "$REPRO_MANIFEST_DIR"
  cp "$SAVED_A" "$REPRO_MANIFEST_DIR/manifest-source-a.txt"
  cp "$SAVED_B" "$REPRO_MANIFEST_DIR/manifest-source-b.txt"
fi
if cmp -s "$SAVED_A" "$SAVED_B"; then
  echo "PASS: clean-checkout universal builds are bit-identical for commit $FULL_SHA"
  cat "$SAVED_A"
  rm -f "$SAVED_A" "$SAVED_B"
  exit 0
else
  echo "FAIL: build variance detected between source-a and source-b for commit $FULL_SHA" >&2
  echo "--- Relative paths and expected vs actual SHA-256 hashes ---" >&2
  diff -u "$SAVED_A" "$SAVED_B" >&2 || true
  rm -f "$SAVED_A" "$SAVED_B"
  exit 1
fi
