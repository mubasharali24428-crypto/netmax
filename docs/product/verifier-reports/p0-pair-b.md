# P0 Pair B — Verifier Report (Lane B2: engine bridge)

Date: 2026-08-23 · Verifier: PAIR B (PASS 1 mechanical sweep + PASS 2 prime judgment)
Scope: `desktop/bridge/engine_bridge.py`, `desktop/bridge/test_engine_bridge.py` only.
Contract: C1 in `docs/product/mission-p0-graph.md` — CLI
`engine_bridge.py run <mode> [--streams N] [--seconds N] [--count N] --json-out PATH`;
envelope `{"success":bool,"mode":str,"data":obj-or-null,"error":str-or-null}`;
interpreter `$NETMAX_PYTHON -> sys.executable`; timeout 180 s kill; failures exit nonzero;
tests OFFLINE (mock subprocess).

## PASS 1 — mechanical sweep (all output verbatim)

### 1. Footprint

```
$ cd /Users/user/netmax-app && git status --short
?? desktop/
```

Only owned lane path untracked (plus other pairs' reports under
docs/product/verifier-reports/ at final re-check). Nothing outside owned paths.
No commits made.

### 2. Lane test suite

```
$ /Users/user/1/bin/python -m pytest desktop/bridge/test_engine_bridge.py -q
....................................                                     [100%]
36 passed in 0.03s
```

(40 passed after the PASS 2 fix below — 4 new regression tests added, 1 updated.)

### 3. selftest

```
$ /Users/user/1/bin/python desktop/bridge/engine_bridge.py selftest; echo $?
PASS arg_mapping_per_mode
PASS envelope_writer_temp_file
PASS interpreter_resolution_mocked_env
selftest: 3/3 checks passed
0
```

### 4a. Probe — `run loss --count 3` (real engine run; network hit by engine)

```
$ /Users/user/1/bin/python desktop/bridge/engine_bridge.py run loss --count 3 --json-out /tmp/p0probe.json; echo $?
0
$ cat /tmp/p0probe.json
{"success": true, "mode": "loss", "data": {"raw": "packet loss: 0.0%\n"}, "error": null}
```

Path exercised: SUCCESS envelope (exit 0). Engine emitted human text; bridge wrapped
it as {"raw": ...} per its documented stdout policy. Re-verified identical after fix.

### 4b. Probe — `run bogus_mode`

Before fix:

```
$ /Users/user/1/bin/python desktop/bridge/engine_bridge.py run bogus_mode --json-out /tmp/p0b.json; echo $?
usage: engine_bridge run [-h] [--streams STREAMS] [--seconds SECONDS]
...
engine_bridge run: error: argument mode: invalid choice: 'bogus_mode' ...
2
$ cat /tmp/p0b.json
cat: /tmp/p0b.json: No such file or directory
```

Exit nonzero ✓ but NO envelope written — argparse rejected before any envelope logic,
contradicting the module's own docstring ("every failure lands in the envelope") and
the brief's expectation of an envelope with success:false. Classified MAJOR; fixed
in-lane (see PASS 2). After fix:

```
$ /Users/user/1/bin/python desktop/bridge/engine_bridge.py run bogus_mode --json-out /tmp/p0b.json 2>/tmp/p0b.err; echo "EXIT=$?"
EXIT=1
$ cat /tmp/p0b.json
{"success": false, "mode": "bogus_mode", "data": null, "error": "invalid arguments: argument mode: invalid choice: 'bogus_mode' (choose from baseline, turbo, boost, dns, bloat, full, upload, loss, jitter, wifi)"}
$ cat /tmp/p0b.err
engine_bridge: invalid arguments: argument mode: invalid choice: 'bogus_mode' (choose from baseline, turbo, boost, dns, bloat, full, upload, loss, jitter, wifi)
```

### 4c. Probe — interpreter resolution failure

```
$ NETMAX_PYTHON=/nonexistent /Users/user/1/bin/python desktop/bridge/engine_bridge.py run baseline --json-out /tmp/p0c.json; echo $?
1
$ cat /tmp/p0c.json
{"success": false, "mode": "baseline", "data": null, "error": "[Errno 2] No such file or directory: '/nonexistent'"}
```

Error-envelope path validated: exit 1, success:false, data null, error carries the OS
message. Re-verified identical after fix.

### 5. Anti-synthesis scan

```
$ grep -nE 'TODO|FIXME|XXX' desktop/bridge/engine_bridge.py desktop/bridge/test_engine_bridge.py
(no matches; grep exit 1)
```

Mocks present in tests (offline requirement):

```
$ grep -nE 'mock|Mock|patch' desktop/bridge/test_engine_bridge.py | head
15:from unittest import mock
72:    with mock.patch.dict(os.environ, {"NETMAX_PYTHON": PY}):
160:# ── run_engine end-to-end with mocked subprocess.run ────────────────────────
269:def test_cli_run_happy_path_via_main(monkeypatch, tmp_path):
271:    monkeypatch.setattr(
...(plus runner-injection mocks throughout run_engine tests)
```

No network imports in tests:

```
$ grep -nE '^import (requests|urllib|http)|^from (requests|urllib|http)' desktop/bridge/test_engine_bridge.py
(no matches; grep exit 1)
```

Contract constants implemented:

```
42|TIMEOUT_S = 180
43|STDERR_TAIL_CHARS = 400
97|def stderr_tail(text: str, limit: int = STDERR_TAIL_CHARS): return (text or "")[-limit:]
146|    timeout_s: float = TIMEOUT_S,
```

Timeout kill path is unit-covered (`test_run_timeout_kills_and_fails_envelope`);
stderr tail truncation covered (`test_run_stderr_longer_than_400_truncated_to_tail`,
asserts len == 400 and newest bytes kept).

### 6. Repo-root suite

```
$ /Users/user/1/bin/python -m pytest -q | tail -1
157 passed in 8.03s          # pre-fix
157 passed in 7.97s          # post-fix re-run
```

## PASS 2 — prime judgment

### Arg-mapping vs netmax.py argparse (~line 350) — CORRECT for all 10 modes

Engine truth (netmax.py:342–365):
- core loop `RUNNERS`: baseline=(--seconds); turbo/boost/bloat/full=(--streams,--seconds);
  dns=() (no seconds).
- v0.4 parsers: upload=(--seconds); loss/jitter=(--count); wifi=().

Bridge `MODE_FLAGS` (engine_bridge.py:48–59) matches every entry exactly, and
`build_command` forwards only mode-supported flags (verified by parametrized tests for
all 10 modes + drop-of-unsupported-flag test). Engine-only extras (`export`, `fetch`,
`bloat-eco`) are intentionally not exposed by the desktop bridge — no C1 violation.

### Envelope shape — EXACT

Writer emits exactly the four keys with correct types on both paths; verified live in
probes 4a/4b(post-fix)/4c and by shape tests (`test_write_envelope_*_shape`). Exit code
mirrors envelope: 0 success / 1 failure (argparse usage errors were 2 pre-fix — fixed).

### Findings

| # | Sev | Finding | Disposition |
|---|-----|---------|-------------|
| F1 | MAJOR | Usage errors (e.g. unknown mode) exited 2 with no envelope, violating the documented "every failure lands in the envelope" promise and leaving a UI consumer without machine-readable failure info. | FIXED in-lane: `parser.error` overridden (root + both subparsers — subparsers are separate parser instances with their own default error()) to write the C1 envelope when mode+--json-out are derivable from raw argv, print to stderr, exit 1. 5 tests added/updated. |

MINOR observations (no action required): none beyond F1. SUSPICION: none — all tested
behavior was reproduced live against the real CLI.

### Fix-loop reruns (post-fix)

- Lane suite: `40 passed in 0.05s`
- selftest: exit 0, 3/3 checks
- Probes re-run: 4a exit 0 success envelope; 4b exit 1 + success:false envelope; 4c exit 1 + success:false envelope
- Repo root: `157 passed in 7.97s`
- Footprint: edits confined to the two bridge files + this report; no commits.

## Files touched by verification

- `desktop/bridge/engine_bridge.py` (F1 fix: argv helpers `_argv_mode`/`_argv_json_out`, `_fail_envelope` wired to all three argparse instances)
- `desktop/bridge/test_engine_bridge.py` (unknown-mode test updated 2→1; +4 regression tests)
- `docs/product/verifier-reports/p0-pair-b.md` (this report — only new file from this pair)

Verdict: READY-TO-MERGE
