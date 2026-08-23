#!/usr/bin/env bash
# verify_phase0.sh — P0 Phase 0 merge gate (P0-B4). OFFLINE checks only.
#
# Runs every gate step, prints PASS/FAIL per step with the actual command
# output, and exits nonzero if any step fails.
#
# NOTE: B1–B3 land files concurrently. If a dependency is missing we
# poll-wait up to 15 minutes (45 s interval) before declaring FAIL,
# so a slow sibling lane doesn't fail the gate spuriously.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SWIFT_DIR="$REPO_ROOT/desktop/SwiftNetMax"
BRIDGE_DIR="$REPO_ROOT/desktop/bridge"
APP="$REPO_ROOT/desktop/build/NetMaxDesktop.app"
PY="${NETMAX_PYTHON:-/Users/user/1/bin/python}"
WAIT_TOTAL_SECS=900   # 15 min
WAIT_INTERVAL=45

PASS=0; FAIL=0
declare -a FAILED_STEPS=()

step_header() { printf '\n=== [%s] %s\n' "$1" "$2"; }
report() { # $1 = PASS|FAIL, $2 = step id, $3.. = detail
  local verdict="$1" id="$2"; shift 2
  if [[ "$verdict" == "PASS" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED_STEPS+=("$id"); fi
  printf '[%s] %s %s\n' "$verdict" "$id" "$*"
}

# wait_for <file-or-dir>... — poll until all exist or 15 min elapse.
wait_for() {
  local missing=()
  for _ in $(seq 1 $(( WAIT_TOTAL_SECS / WAIT_INTERVAL ))); do
    missing=()
    for p in "$@"; do [[ -e "$p" ]] || missing+=("$p"); done
    [[ ${#missing[@]} -eq 0 ]] && return 0
    printf '[WAIT] missing: %s — sleeping %ss (%d/%d)\n' "${missing[*]}" "$WAIT_INTERVAL" "$SECONDS" "$WAIT_TOTAL_SECS"
    sleep "$WAIT_INTERVAL"
  done
  return 1
}

printf 'Phase 0 verify gate — repo: %s\n' "$REPO_ROOT"
printf 'python: %s (%s)\n' "$PY" "$($PY --version 2>&1)"

# --- Dependencies from B1–B3 (poll-wait up to 15 min) -----------------------
DEPS=(
  "$SWIFT_DIR/Package.swift"
  "$SWIFT_DIR/Sources/netmax-desktop"
  "$BRIDGE_DIR/engine_bridge.py"
  "$BRIDGE_DIR/test_engine_bridge.py"
)
step_header deps "dependency files from B1–B3"
if ! wait_for "${DEPS[@]}"; then
  report FAIL deps "timed out after ${WAIT_TOTAL_SECS}s waiting for: ${DEPS[*]}"
  printf '\n===== PHASE 0 GATE: FAIL (%d passed / %d failed) =====\n' "$PASS" "$FAIL"
  exit 1
fi
report PASS deps "all present after ${SECONDS}s wait"

# --- a) swift build -c release green ----------------------------------------
step_header a "swift build -c release"
if ( cd "$SWIFT_DIR" && swift build -c release ); then
  report PASS a "swift build -c release green"
else
  report FAIL a "swift build -c release failed"
fi

# --- b) full pytest suite -> require >=150 passed ----------------------------
step_header b "full pytest suite (expect >=150 passed)"
set +e
PYTEST_OUT="$(cd "$REPO_ROOT" && "$PY" -m pytest -q 2>&1)"; PYTEST_RC=$?
set -e
printf '%s\n' "$PYTEST_OUT" | tail -5 | sed 's/^/    /'
# Un-pinned threshold: accept any pass count >=150 (grows with the suite); a
# nonzero rc OR any "N failed"/"N error(s)" text still fails the gate.
if [[ $PYTEST_RC -eq 0 ]] \
   && grep -Eq '(^|[^0-9])(1[5-9][0-9]|[2-9][0-9]{2}|[0-9]{4,}) passed' <<<"$PYTEST_OUT" \
   && ! grep -Eiq '[1-9][0-9]* (failed|error)|^=+ ERRORS =+' <<<"$PYTEST_OUT"; then
  report PASS b "pytest rc=0 AND >=150 passed AND no failed/error text"
else
  report FAIL b "need rc=0 AND >=150 passed AND no failures/errors; got rc=$PYTEST_RC (see output above)"
fi

# --- c) bridge tests ---------------------------------------------------------
step_header c "desktop/bridge/test_engine_bridge.py"
set +e
BRIDGE_OUT="$(cd "$REPO_ROOT" && "$PY" -m pytest "$BRIDGE_DIR/test_engine_bridge.py" -q 2>&1)"; BRIDGE_RC=$?
set -e
printf '%s\n' "$BRIDGE_OUT" | tail -5 | sed 's/^/    /'
if [[ $BRIDGE_RC -eq 0 ]]; then
  report PASS c "$(grep -oE '[0-9]+ passed[^ ]*' <<<"$BRIDGE_OUT" | head -1 || echo 'all pass')"
else
  report FAIL c "bridge tests failed (rc=$BRIDGE_RC, see above)"
fi

# --- d) bridge selftest ------------------------------------------------------
step_header d "engine_bridge.py selftest"
set +e
SELFTEST_OUT="$("$PY" "$BRIDGE_DIR/engine_bridge.py" selftest 2>&1)"; SELFTEST_RC=$?
set -e
[[ -n "$SELFTEST_OUT" ]] && printf '%s\n' "$SELFTEST_OUT" | sed 's/^/    /'
if [[ $SELFTEST_RC -eq 0 ]]; then
  report PASS d "selftest exit 0"
else
  report FAIL d "selftest exit $SELFTEST_RC (see above)"
fi

# --- e) bundle exists (build_app.sh ran) ------------------------------------
step_header e ".app bundle present"
if [[ -d "$APP/Contents/MacOS" ]]; then
  report PASS e "$APP/Contents/MacOS exists"
else
  report FAIL e "$APP/Contents/MacOS missing — run scripts/build_app.sh first"
fi

# --- f) codesign valid on disk ----------------------------------------------
step_header f "codesign -v"
if CS_OUT="$(codesign -v "$APP" 2>&1)"; then
  report PASS f "valid on disk${CS_OUT:+ ($CS_OUT)}"
else
  report FAIL f "codesign -v failed: ${CS_OUT:-<no output>}"
fi

# --- g) plist lint + LSUIElement true ---------------------------------------
PLIST="$APP/Contents/Info.plist"
step_header g "plutil lint + LSUIElement"
LINT_OUT="$(plutil -lint "$PLIST" 2>&1)" || true
LSUI_OUT="$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$PLIST" 2>&1)" || true
printf '    %s\n    LSUIElement=%s\n' "${LINT_OUT:-<lint failed>}" "$LSUI_OUT"
if [[ "${LINT_OUT:-}" == *OK* && "$LSUI_OUT" == "true" ]]; then
  report PASS g "plist OK, LSUIElement=true"
else
  report FAIL g "lint='${LINT_OUT:-<none>}' LSUIElement='${LSUI_OUT:-<none>}'"
fi

# --- Summary -----------------------------------------------------------------
printf '\n===== PHASE 0 GATE: '
if [[ $FAIL -eq 0 ]]; then
  printf 'PASS (%d/%d steps green) =====\n' "$PASS" "$((PASS+FAIL))"
  exit 0
else
  printf 'FAIL (%d passed / %d failed) =====\n' "$PASS" "$FAIL"
  printf 'failed: %s\n' "${FAILED_STEPS[*]}"
  exit 1
fi
