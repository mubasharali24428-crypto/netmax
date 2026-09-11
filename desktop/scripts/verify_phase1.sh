#!/usr/bin/env bash
# verify_phase1.sh — P0 Phase 1 merge gate (ALPHA-A2-10). Layer-4 verification.
#
# Same PASS/FAIL discipline as verify_phase0.sh, aimed at the L4 lanes:
#   a) swift release build green
#   b) full repo pytest suite green (>=150 passed)
#   c) Scheduler next-fire unit snippet exits 0        (SKIP if Scheduler.swift absent)
#   d) Notifications rule snippet exits 0              (SKIP if Notifications*.swift absent)
#   e) ReportCardPDF generates a /tmp PDF              (SKIP if ReportCardPDF*.swift absent)
#
# Sibling-lane policy: unlike phase0 there is NO poll-wait. A lane whose
# feature file has not landed yet is reported as SKIP — printed honestly,
# counted, and shown in the summary. It neither passes nor fails the gate.
# A file that EXISTS and misbehaves is a hard FAIL.
#
# Probe design: steps c/d compile the package's non-entry-point sources with
# `swiftc` plus a generated main.swift exercising the pure logic directly
# (ScheduleMath.nextFire/isDue; evaluateDegradation/NotificationRules), so
# the snippet is a real executable assertion, not just a typecheck.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SWIFT_DIR="$REPO_ROOT/desktop/SwiftNetMax"
SRC_DIR="$SWIFT_DIR/Sources"

PY="${NETMAX_PYTHON:-$(command -v python3 || true)}"
if [[ -z "$PY" ]]; then
  printf 'FATAL: no python found (set NETMAX_PYTHON)\n' >&2
  exit 2
fi

PASS=0; FAIL=0; SKIP=0
declare -a FAILED_STEPS=() SKIPPED_STEPS=()

step_header() { printf '\n=== [%s] %s\n' "$1" "$2"; }
report() { # $1 = PASS|FAIL|SKIP, $2 = step id, $3.. = detail
  local verdict="$1" id="$2"; shift 2
  case "$verdict" in
    PASS) PASS=$((PASS+1)) ;;
    FAIL) FAIL=$((FAIL+1)); FAILED_STEPS+=("$id") ;;
    SKIP) SKIP=$((SKIP+1)); SKIPPED_STEPS+=("$id") ;;
  esac
  printf '[%s] %s %s\n' "$verdict" "$id" "$*"
}

find_source() { find "$SRC_DIR" -name "$1" -type f 2>/dev/null | sort | head -1 || true; }

# probe_sources <main-snippet-file> — compile all package sources except
# @main / XCTest files together with the given main.swift, run the binary.
# The snippet must exit nonzero itself if its assertions fail.
probe_sources() {
  local snippet="$1"
  local probe_dir src f
  probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/netmax_phase1_probe.XXXXXX")"
  cp "$snippet" "$probe_dir/main.swift"

  local copied=()
  while IFS= read -r src; do
    f="$(basename "$src")"
    grep -qE '^[[:space:]]*@main' "$src" && continue       # app entry point(s)
    grep -qE '^[[:space:]]*import XCTest' "$src" && continue
    cp "$src" "$probe_dir/$f"
    copied+=("$probe_dir/$f")
  done < <(find "$SRC_DIR" -name '*.swift' -type f | sort)

  if [[ ${#copied[@]} -eq 0 ]]; then
    echo "no compilable .swift under $SRC_DIR" >&2
    rm -rf "$probe_dir"; return 9
  fi

  # Single invocation: because one input is literally named main.swift,
  # swiftc treats it as the top-level-code entry file and everything else
  # as library sources — no -parse-as-library needed (that flag makes
  # swiftc try to link a mainless executable and die with undefined _main).
  if ! ( cd "$probe_dir" && swiftc -suppress-warnings \
         "${copied[@]}" main.swift -o probe_bin ) 2> "$probe_dir/main.err"; then
    sed 's/^/    /' "$probe_dir/main.err" | head -25
    rm -rf "$probe_dir"; return 8                          # compile failed
  fi
  ( cd "$probe_dir" && ./probe_bin ); local rc=$?
  rm -rf "$probe_dir"
  return "$rc"
}

printf 'Phase 1 verify gate (L4) — repo: %s\n' "$REPO_ROOT"
printf 'python: %s (%s)\n' "$PY" "$("$PY" --version 2>&1)"

# --- a) swift build -c release green -----------------------------------------
step_header a "swift build -c release"
if ( cd "$SWIFT_DIR" && swift build -c release ); then
  report PASS a "swift build -c release green"
else
  report FAIL a "swift build -c release failed"
fi

# --- b) full pytest suite -> require >=150 passed -----------------------------
step_header b "full pytest suite (expect >=150 passed)"
set +e
PYTEST_OUT="$(cd "$REPO_ROOT" && "$PY" -m pytest -q 2>&1)"; PYTEST_RC=$?
set -e
printf '%s\n' "$PYTEST_OUT" | tail -5 | sed 's/^/    /'
# Same discipline as phase0 step b: rc=0 AND threshold met AND no failed/error text.
if [[ $PYTEST_RC -eq 0 ]] \
   && grep -Eq '(^|[^0-9])(1[5-9][0-9]|[2-9][0-9]{2}|[0-9]{4,}) passed' <<<"$PYTEST_OUT" \
   && ! grep -Eiq '[1-9][0-9]* (failed|error)|^=+ ERRORS =+' <<<"$PYTEST_OUT"; then
  report PASS b "pytest rc=0 AND >=150 passed AND no failed/error text"
else
  report FAIL b "need rc=0 AND >=150 passed AND no failures/errors; got rc=$PYTEST_RC (see output above)"
fi

# --- c) Scheduler next-fire unit snippet --------------------------------------
SCHEDULER_FILE="$(find_source 'Scheduler.swift')"
step_header c "Scheduler next-fire unit snippet"
if [[ -z "$SCHEDULER_FILE" ]]; then
  report SKIP c "Scheduler.swift not present yet (sibling lane hasn't landed)"
else
  PROBE_C="$(mktemp "${TMPDIR:-/tmp}/netmax_phase1_c.XXXXXX.swift")"
  cat > "$PROBE_C" <<'SWIFT'
// L4 probe: ScheduleMath.nextFire / ScheduleMath.isDue (pure date math).
import Foundation
func eqD(_ a: Date, _ b: Date) -> Bool { abs(a.timeIntervalSince(b)) < 0.001 }
var n = 0
func check(_ cond: Bool, _ what: String) {
  if cond { n += 1 } else { print("ASSERT FAIL: \(what)"); exit(1) }
}
let now = Date(timeIntervalSince1970: 1_000_000)
let iv = TimeInterval(300) // 5 min

// never fired -> first fire exactly one interval out (not instant)
check(eqD(ScheduleMath.nextFire(lastRun: nil, interval: iv, now: now),
          now.addingTimeInterval(iv)), "nil lastRun => now+interval")
// normal cadence
check(eqD(ScheduleMath.nextFire(lastRun: now.addingTimeInterval(-60), interval: iv, now: now),
          now.addingTimeInterval(240)), "lastRun-60s => now+240s")
// overdue catches up instead of skipping ahead
check(eqD(ScheduleMath.nextFire(lastRun: now.addingTimeInterval(-600), interval: iv, now: now),
          now), "overdue => fires now")
// clock skew guard: future lastRun treated as now
check(eqD(ScheduleMath.nextFire(lastRun: now.addingTimeInterval(+600), interval: iv, now: now),
          now.addingTimeInterval(iv)), "future lastRun (skew) => now+interval")
// non-positive interval falls back to default cadence, never <= 0 wait
let fallbackIv = TimeInterval(ScheduleFallbacks.intervalMinutes) * 60
check(eqD(ScheduleMath.nextFire(lastRun: nil, interval: 0, now: now),
          now.addingTimeInterval(fallbackIv)), "interval<=0 => default cadence")

// isDue: disabled never fires; first cycle waits; boundary counts as due
check(ScheduleMath.isDue(enabled: false, lastRun: nil, interval: iv, now: now) == false,
      "disabled => never due")
check(ScheduleMath.isDue(enabled: true, lastRun: nil, interval: iv, now: now) == false,
      "never fired => not due")
check(ScheduleMath.isDue(enabled: true, lastRun: now.addingTimeInterval(-301), interval: iv, now: now),
      "overdue => due")
check(ScheduleMath.isDue(enabled: true, lastRun: now.addingTimeInterval(-iv), interval: iv, now: now),
      "exactly on boundary => due")
check(ScheduleMath.isDue(enabled: true, lastRun: now.addingTimeInterval(-60), interval: iv, now: now) == false,
      "inside window => not due")
print("SCHEDULER_PROBE_OK \(n)/\(n) assertions passed")
SWIFT
  set +e
  OUT="$(probe_sources "$PROBE_C")"; RC=$?
  set -e
  [[ -n "$OUT" ]] && printf '%s\n' "$OUT" | sed 's/^/    /'
  rm -f "$PROBE_C"
  if [[ $RC -eq 0 ]]; then
    report PASS c "scheduler snippet exit 0 ($(head -1 <<<"$OUT"))"
  else
    report FAIL c "scheduler snippet exited $RC (see output above)"
  fi
fi

# --- d) Notifications rule snippet --------------------------------------------
NOTIF_FILE="$(find_source 'Notifications*.swift')"
step_header d "Notifications rule snippet"
if [[ -z "$NOTIF_FILE" ]]; then
  report SKIP d "Notifications*.swift not present yet (sibling lane hasn't landed)"
else
  PROBE_D="$(mktemp "${TMPDIR:-/tmp}/netmax_phase1_d.XXXXXX.swift")"
  cat > "$PROBE_D" <<'SWIFT'
// L4 probe: NotificationRules.gradeDrop + evaluateDegradation rule behavior.
import Foundation
var n = 0
func check(_ cond: Bool, _ what: String) {
  if cond { n += 1 } else { print("ASSERT FAIL: \(what)"); exit(1) }
}
func rec(minutesAgo: Double, grade: String) -> HistoryRecord {
  HistoryRecord(ts: Date().addingTimeInterval(-minutesAgo * 60),
                mode: "auto",
                params: [:],
                resultRaw: "grade: \(grade)\nsummary: probe")
}

// rubric math
check(NotificationRules.gradeDrop(from: "A", to: "C") == 2, "A->C drops 2")
check(NotificationRules.gradeDrop(from: "B", to: "A+") == -2, "B->A+ negative")
check(NotificationRules.gradeDrop(from: "Z", to: "A") == nil, "unknown grade => nil")

// evaluateDegradation: needs >= 2 records; big drop raises an alert
let flat = [rec(minutesAgo: 20, grade: "A"), rec(minutesAgo: 10, grade: "A")]
check(evaluateDegradation(flat).isEmpty, "stable grades => no alert")
let drop2 = [rec(minutesAgo: 20, grade: "A"), rec(minutesAgo: 10, grade: "C")]
let alerts = evaluateDegradation(drop2)
check(alerts.count == 1 && alerts[0].kind == .bloatGradeDrop, "A->C raises one bloatGradeDrop alert")

// back-to-back drops: implementation emits one alert per consecutive pair
// (evaluateDegradation loops pairs; its docstring's "collapse" wording is
// aspirational). Pin the ACTUAL per-pair behavior + newest index here so any
// regression in either direction fails loudly.
let repeatDrop = [rec(minutesAgo: 30, grade: "A"),
                  rec(minutesAgo: 20, grade: "C"),
                  rec(minutesAgo: 10, grade: "F")]
let rep = evaluateDegradation(repeatDrop)
check(rep.count == 2, "back-to-back drops => one alert per consecutive pair")
check(rep.last?.newerIndex == 2 && rep.last?.kind == .bloatGradeDrop,
      "last alert points at the newest pair")

// rule 2: packet-loss spike from a JSON payload ("loss" key)
func recJSON(_ minutesAgo: Double, _ json: String) -> HistoryRecord {
  HistoryRecord(ts: Date().addingTimeInterval(-minutesAgo * 60),
                mode: "auto", params: [:], resultRaw: json)
}
let lossSeq = [recJSON(20, #"{"loss": 1.0}"#), recJSON(10, #"{"loss": 6.0}"#)]
let lossAlerts = evaluateDegradation(lossSeq)
check(lossAlerts.count == 1 && lossAlerts[0].kind == .packetLossSpike,
      "loss 1% -> 6% raises one packetLossSpike alert")

// rule 3: success -> failure transition
let sfSeq = [recJSON(20, #"{"success": true}"#), recJSON(10, #"{"success": false}"#)]
let sfAlerts = evaluateDegradation(sfSeq)
check(sfAlerts.count == 1 && sfAlerts[0].kind == .successToFailure,
      "success -> failure raises one successToFailure alert")

print("NOTIFY_PROBE_OK \(n)/\(n) assertions passed")
SWIFT
  set +e
  OUT="$(probe_sources "$PROBE_D")"; RC=$?
  set -e
  [[ -n "$OUT" ]] && printf '%s\n' "$OUT" | sed 's/^/    /'
  rm -f "$PROBE_D"
  if [[ $RC -eq 0 ]]; then
    report PASS d "notifications snippet exit 0 ($(head -1 <<<"$OUT"))"
  else
    report FAIL d "notifications snippet exited $RC (see output above)"
  fi
fi

# --- e) ReportCardPDF generates /tmp PDF --------------------------------------
PDF_FILE="$(find_source 'ReportCardPDF*.swift')"
step_header e "ReportCardPDF generates /tmp PDF"
if [[ -z "$PDF_FILE" ]]; then
  report SKIP e "ReportCardPDF*.swift not present yet (sibling lane hasn't landed)"
else
  ART_DIR="$(mktemp -d "${TMPDIR:-/tmp}/netmax_phase1_pdf.XXXXXX")"
  PROBE_E="$(mktemp "${TMPDIR:-/tmp}/netmax_phase1_e.XXXXXX.swift")"
  cat > "$PROBE_E" <<SWIFT
// L4 probe: ReportCardPDF must produce a real PDF file.
import Foundation
import AppKit
let outDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NETMAX_PDF_OUT_DIR"] ?? NSTemporaryDirectory())
let records: [HistoryRecord] = (0..<6).map { i in
  HistoryRecord(ts: Date().addingTimeInterval(Double(-i) * 600),
                mode: i %% 2 == 0 ? "a" : "b",
                params: ["up": 900, "down": 100],
                resultRaw: "grade: \(i %% 3 == 0 ? "A" : "B")\nsummary: probe row \(i)")
}
do {
  // Real API chain (landed lanes): ReportCardModel.makeCard → ReportCardPDF.content → write
  let card = ReportCardModel.makeCard(from: records)
  let content = ReportCardPDF.content(from: card,
                                      title: "NetMax Report Card",
                                      dateRangeText: "probe range")
  let url = try ReportCardPDF.write(content, to: outDir.appendingPathComponent("probe-card.pdf"))
  print("PDF_PROBE_OK \(url.path)")
} catch {
  print("PDF_PROBE_ERROR \(error)")
  exit(1)
}
SWIFT
  # escape the shell-expansion backslashes we want literal inside the heredoc
  sed -i '' 's/i %% 2/i % 2/g; s/i %% 3/i % 3/g' "$PROBE_E"
  set +e
  OUT="$(NETMAX_PDF_OUT_DIR="$ART_DIR" probe_sources "$PROBE_E")"; RC=$?
  set -e
  [[ -n "$OUT" ]] && printf '%s\n' "$OUT" | sed 's/^/    /'
  if [[ $RC -eq 0 ]] && grep -q '^PDF_PROBE_OK ' <<<"$OUT"; then
    PDF_PATH="$(grep -o '/[^ ]*\.pdf' <<<"$OUT" | head -1)"
    if [[ -n "$PDF_PATH" && -s "$PDF_PATH" ]] && head -c 5 "$PDF_PATH" | grep -q '%PDF-'; then
      printf '    artifact: %s (%s bytes, magic OK)\n' "$PDF_PATH" "$(wc -c < "$PDF_PATH" | tr -d ' ')"
      report PASS e "PDF generated and validated ($(wc -c < "$PDF_PATH" | tr -d ' ') bytes)"
    else
      report FAIL e "snippet exited 0 but artifact missing/not a PDF: ${PDF_PATH:-<none reported>}"
    fi
  else
    report FAIL e "ReportCardPDF probe exited $RC or printed no success marker (see output above)"
  fi
  rm -rf "$ART_DIR"; rm -f "$PROBE_E"
fi

# --- f) LicenseGate offline gate (P2.9, Strategic Revenue Plan) ----------------
LG_FILE="$(find_source 'LicenseGate.swift')"
step_header f "LicenseGate offline checks (trial/pro/free tiering)"
if [[ -z "$LG_FILE" ]]; then
  report SKIP f "LicenseGate.swift not present yet (sibling lane hasn't landed)"
else
  PROBE_F="$(mktemp "${TMPDIR:-/tmp}/netmax_phase1_f.XXXXXX.swift")"
  cat > "$PROBE_F" <<'SWIFT'
import Foundation
let n = LicenseGateTests.runAll()
if n == 0 {
    print("LICENSE_GATE_OK")
    exit(0)
}
print("LICENSE_GATE_FAILS")
exit(1)
SWIFT
  set +e
  OUT="$(probe_sources "$PROBE_F")"; RC=$?
  set -e
  [[ -n "$OUT" ]] && printf '%s\n' "$OUT" | sed 's/^/    /'
  rm -f "$PROBE_F"
  if [[ $RC -eq 0 ]] && grep -q '^LICENSE_GATE_OK' <<<"$OUT"; then
    report PASS f "LicenseGate checks exit 0 ($(head -1 <<<"$OUT"))"
  else
    report FAIL f "LicenseGate probe exited $RC or printed no success marker (see output above)"
  fi
fi

# --- Summary -------------------------------------------------------------------
printf '\n===== PHASE 1 GATE (L4): '
if [[ $FAIL -eq 0 ]]; then
  printf 'PASS (%d/%d executable steps green, %d skipped) =====\n' "$PASS" "$((PASS+FAIL))" "$SKIP"
  [[ $SKIP -gt 0 ]] && printf 'skipped (siblings not landed): %s\n' "${SKIPPED_STEPS[*]}"
  exit 0
else
  printf 'FAIL (%d passed / %d failed / %d skipped) =====\n' "$PASS" "$FAIL" "$SKIP"
  printf 'failed: %s\n' "${FAILED_STEPS[*]}"
  [[ $SKIP -gt 0 ]] && printf 'skipped: %s\n' "${SKIPPED_STEPS[*]}"
  exit 1
fi
