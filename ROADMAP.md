# NetMax Agent Execution Roadmap

## Purpose and execution state

This document converts the read-only findings in SECURITY-AUDIT.md into an agent-executable upgrade plan for the complete /Users/user/netmax-app repository: Python engine/CLI/Tk GUI, Swift macOS app, Node MCP server, bridge, landing page, plugins, CI, packaging, and documentation.

This is a task-gated plan with no calendar estimates. A task may start only when its listed prerequisites and input contracts are satisfied. The user has authorized implementation; execution and evidence are tracked by task status below.

## 1. Operating contract for the AI agent

### Required behavior

1. At the start of execution, read this roadmap and SECURITY-AUDIT.md, then inspect git status --short --branch.
2. Preserve all existing user changes. Never reset, clean, discard, or overwrite a pre-existing modified or untracked file.
3. Treat the audited working tree as the intended scope, including existing uncommitted changes. Before editing a dirty file, save/review its diff and preserve every unrelated hunk. Stop only if the requested edit cannot be isolated without overwriting user work; report the exact overlap and continue independent tasks.
4. Assign one accountable role to each task. A role may request review from another role, but only the accountable role edits the task’s owned paths.
5. Never allow two agents to edit the same file at the same time. Tasks touching the same file are serialized even if their broader work packages could otherwise run in parallel.
6. Do not expand a task into adjacent redesign or refactoring. Record newly discovered issues in the findings register and get a separate task ID before changing them.
7. Each implementation task must change fewer than 100 lines of production code. If acceptance criteria cannot fit, split the task into smaller tasks before editing. Tests and generated lockfiles are tracked separately and must remain focused.
   Count distinct canonical production lines for Python modules; a byte-identical mirror update is reported separately but is not double-counted as a second logical edit. Generated lockfiles are reported separately from production code. Every task records both counts.
8. Every task must produce: changed paths, a short implementation note, the exact verification command and unedited result, and remaining limitations.
9. A failed command is a failed gate. Do not weaken, skip, or reclassify the check to make it pass. Diagnose and create a bounded follow-up task if the failure is outside scope.
10. The coordinator updates task status only after reviewing evidence. A task is not complete merely because its code was written.
11. Do not merge a task with another task’s changes until both owners have completed their checks. Resolve integration conflicts in a dedicated integration task.
12. No task may claim 10/10 while any High or Critical finding remains open in that domain.
13. A-05 must be DONE before any source/configuration task becomes READY, so baseline evidence cannot be contaminated by upgrades. A user authorization to begin implementation is still required independently.

### Task status vocabulary

- BLOCKED: a named prerequisite or external input is missing; state exactly what is missing.
- READY: prerequisites passed; owner and write set are assigned.
- IN PROGRESS: the owner is the only writer on its paths.
- REVIEW: implementation and owner verification are complete; independent review is pending.
- DONE: acceptance criteria passed and evidence is recorded.
- REJECTED: acceptance failed; record failing evidence and open a bounded corrective task.

Do not use dates, elapsed time, or percentage-complete estimates to decide status.

### Phase 0 release-state qualifiers (added 2026-10-08)

A task marked DONE means its implementation exists and its owner-verification
passed. Release readiness is tracked separately:
- IMPLEMENTED: the code exists.
- TESTED: the task's acceptance tests pass on the current tree.
- READY FOR RELEASE: all acceptance criteria pass and no external credential blocks it.
- BLOCKED BY EXTERNAL CREDENTIAL: needs a credential or approval only the
  product owner can supply (e.g. Apple Developer enrollment).
A DONE task that is not TESTED, or that is BLOCKED BY EXTERNAL CREDENTIAL,
must say so on its status line.

## 2. Roles and exclusive ownership

The coordinator creates assignments, enforces file ownership, checks dependencies, and accepts evidence. The coordinator does not edit product source code.

| Role | Accountable scope | Exclusive write set | Must not edit |
|---|---|---|---|
| R0 — Delivery Coordinator | Task order, file ownership, dependency gates, status, integration acceptance | ROADMAP.md and task-status section in this document only | Product code and tests owned by other roles |
| R1 — Python Engine Security | CLI boundaries, download paths, history paths, provider URL policy, AI governor bounds, Python bundle redaction | Root Python engine modules and matching desktop/engine mirrors for those modules; scripts/check_engine_mirrors.py; dedicated Python tests assigned below | MCP server, bridge, shaping module, Swift, CI |
| R2 — MCP Server | MCP schema, HTTP/fleet policy, concurrency, server-level tests | desktop/netmax-mcp-server.mjs and dedicated desktop/test_mcp_*.mjs files assigned below | Python engine, package manifests, bridge, Swift |
| R3 — Bridge | Secure envelope creation and subprocess contract | desktop/bridge/engine_bridge.py and desktop/bridge/test_engine_bridge.py | MCP server, engine modules, shared tests outside bridge |
| R4 — Privileged Shaping | pf/dnctl apply, ownership, cleanup, failure-injection tests | Root netmax_shape.py, desktop/engine/netmax_shape.py, tests/test_pf_transactional.py, tests/test_pf_locking.py, tests/test_netmax_shape.py | netmax.py, MCP server, bridge |
| R5 — Build, Dependencies, and Release | CI, verification scripts, dependency locks, package metadata, signing/notarization workflow | .github/workflows/**, requirements-ci.txt, pyproject.toml dependency metadata, uv.lock, desktop/package.json and lock, plugins/vscode/package.json and lock, desktop/scripts/verify_*.sh, desktop/scripts/build_app.sh, desktop/scripts/build_dmg.sh, desktop/scripts/sign.sh, desktop/scripts/notarize.sh, desktop/scripts/verify_reproducible_build.sh, scripts/release_stress.py | Product source modules and tests owned by R1-R4/R6-R7 |
| R6 — Swift Desktop | Swift UI, privacy/settings controls, update navigation, Swift tests, feature stubs | desktop/SwiftNetMax/Sources/**, desktop/SwiftNetMax/Tests/**, desktop/SwiftNetMax/Package.swift, desktop/prototypes/swift/** | Python, Node, CI scripts, landing page |
| R7 — Web Product UX | Landing-page content, interaction truthfulness, semantic tokens, responsive/accessibility behavior | landing/** | Swift app, shared product docs, CI |
| R8 — Product Security Documentation | Threat model, data-flow disclosure, operator docs, claims, feature/privacy documentation | docs/** except docs/reviews/upgrade-evidence.md; desktop/MCP-README.md; root README.md except commands owned by R5 | Runtime code and test files; R9 review record |
| R9 — Independent QA Reviewer | Evidence review, abuse-case review, acceptance scoring, release sign-off | docs/reviews/upgrade-evidence.md only | Any implementation path or another role’s evidence |
| R10 — VS Code Extension Runtime | Bounded, responsive local-history loading and extension-host tests | plugins/vscode/extension.js, plugins/vscode/media/trends.js, and dedicated plugins/vscode/test/history_limits.test.js | Package metadata/locks owned by R5; all other product surfaces |

### Collision-prevention rules

- The write sets above are exclusive. Any unlisted path is unowned until R0 assigns it.
- Root Python modules are canonical. Their desktop/engine mirrors are updated by the same R1 or R4 task and checked for equality. No separate mirror agent is permitted.
- Tasks editing the same file are sequential. In particular, R2 changes to desktop/netmax-mcp-server.mjs are serialized; R1 changes to netmax.py or netmax_ai_provider.py are serialized; R6 changes to DashboardCardsView.swift are serialized.
- Each role creates a dedicated new test file where possible. Do not have multiple roles append to tests/test_netmax.py, tests/conftest.py, or another shared test file.
- R5 may update a test command in a workflow but may not edit test implementation. The test owner first publishes the command and expected exit behavior.
- R8 owns wording and policy docs. Runtime behavior remains with the relevant code role. R8 cannot mark a policy implemented until R1/R2/R6 provide evidence. R9 is the sole writer for docs/reviews/upgrade-evidence.md.
- R9 must be independent of the implementation owner for the task being reviewed.
- R0 records task status in the task heading after evidence review. The initial status for all implementation cards is NOT STARTED; it becomes READY only after GO and prerequisite checks.
- If a patch crosses a role boundary, split it at the interface and freeze the interface contract before either side edits.

## 3. Interface contracts to freeze before implementation

R0 records these decisions as task inputs. If repository behavior contradicts an item, R0 opens a decision task; implementation agents do not invent a different behavior.

| Contract | Required behavior |
|---|---|
| Download destination | MCP passes `fetch URL --mcp-output-name BASENAME`; if output is omitted, the MCP server derives the last URL path component or `download` and still passes it as a basename. Engine mode `--mcp-output-name` writes only beneath `~/Downloads/NetMax/`, creates the directory with mode 0700, and creates the destination exclusively with mode 0600 and no-follow semantics. Engine rejects the flag combined with positional `out`. Existing files are never deleted or replaced. Ordinary CLI fetch behavior is unchanged. |
| History source | AI history analysis accepts the existing NetMaxDesktop history file under ~/Library/Application Support/NetMaxDesktop/history.jsonl, resolved through the application’s existing path contract. Importing another file requires a separately user-approved import operation; an MCP argument alone cannot authorize arbitrary reads. |
| Local history retention and deletion | Preserve existing behavior: `netmax.history.retentionDays=0` means keep indefinitely; positive N archives records older than N days to `archive-history.jsonl` before removing them from the live view; Clear History moves the live file to `cleared-history.jsonl` for undo. Add a separate explicit permanent-erase action that removes live JSONL/SQLite stores, SQLite WAL/SHM, retention archive, and cleared-history holding file only after confirmation. No history is uploaded or synced by this action. |
| Telemetry and outbound data | Product analytics/phone-home telemetry is absent. Network measurements may contact only their selected documented endpoint; fleet checks only an alias in the exact allowlist; remote AI only after local opt-in. Tests assert zero analytics/phone-home and zero remote-AI requests when preference is off. |
| AI provider egress | Add Bool preference netmax.prefs.allowRemoteAI to AppPreferences; default false. SwiftUI writes it only through AppPreferences.shared. The macOS engine/MCP policy adapter reads the same key from defaults domain com.netmax.desktop using `/usr/bin/defaults` with argv and no shell; missing, unreadable, timed out, or malformed means false. MCP arguments and environment variables cannot enable it. When false, reject before constructing or sending remote request bytes. Before enabling, Settings names the provider and exact fields sent. Local provider use remains available. |
| Remote-AI payload | After opt-in, the only user-derived request data is JSON `{schema_version: 1, analysis_id, metrics}`. `analysis_id` must be a registered analysis name. `metrics` accepts only `mode`, `streams`, `duration_seconds`, `download_mbps`, `upload_mbps`, `latency_ms`, `jitter_ms`, `packet_loss_percent`, `bufferbloat_grade`, `sample_count`, and `dns_latency_ms`; omitted values are allowed, unknown keys are rejected. `streams` is integer 1–50; duration is 1–21,600 seconds; rates are finite 0–10,000 Mbps; latency/jitter/DNS latency are finite 0–60,000 ms; loss is finite 0–100%; grade is A–F; sample count is integer 0–100,000. No timestamps, raw history rows, notes/free text, SSID/BSSID, hostnames/IPs, usernames, paths, tokens, or secrets. Provider/model metadata required by the provider protocol is documented separately from user measurement data. |
| AI-response trust | Treat every provider response as hostile data. Parse only the registered analysis response schema, cap response bytes at 1 MiB and nesting depth at 16, reject unknown keys/non-finite numbers, escape displayed text, and never execute a response, construct a command/URL from it, or allow the model to invoke an MCP tool. |
| URL schemes | Download and production fleet requests require HTTPS. HTTP is permitted only for a literal loopback address in an automated test fixture; production configuration cannot enable HTTP. Download redirects are revalidated at each hop. Fleet requests do not follow redirects. |
| Private network targets | Downloads cannot target loopback, link-local, private, multicast, or metadata-service addresses. Fleet peers may use private addresses only when the operator explicitly allowlists the exact HTTPS origin. Resolve and validate the peer immediately before connection, pin the validated address for that connection, and retain TLS hostname verification. |
| Fleet configuration | Replace legacy NETMAX_FLEET/NETMAX_FLEET_TOKEN parsing with NETMAX_FLEET_ALLOWLIST (JSON object alias → exact origin, e.g. https://host:port) and optional NETMAX_FLEET_TOKENS (JSON object alias → peer-specific bearer token). Reject malformed JSON, duplicate aliases, non-origin URL components, unknown aliases, and token entries without a matching peer. Never send one token to multiple peers. |
| Shaping ownership | Use dedicated pf anchor `netmax_strict_limit`; allocate the first unused dummynet pipe ID in 20000–29999; never flush legacy anchor `netmax` or pipe 10. Serialize with root-owned `/var/run/netmax-shaping.lock`; persist PID, random owner token, pipe ID, and prior pf enabled state in `/var/run/netmax-shaping/owner.json` mode 0600. Normal return, exception, timeout, cancellation, and SIGTERM remove only the recorded owner’s anchor/pipe and restore prior pf enabled state. SIGKILL cannot be trapped: detect stale owner metadata under lock and recover only if the PID is dead and NetMax markers match; otherwise fail closed with exact manual recovery instructions. |
| MCP resource budget | A measurement call is bounded by 300 aggregate stream-seconds and 180 seconds wall time, 2 active measurement jobs across the server, and 1 active measurement job per MCP session. Reject before child spawn. Cancellation/disconnect sends SIGTERM, waits at most 2 seconds, then sends SIGKILL and reaps the child. Enforce in server code, independent of tool schema. |
| Security severity gate | No Critical or High finding may remain open at release. A Medium finding requires a written accepted-risk record from the product owner; an AI agent cannot accept risk. |

The download and history locations above are policy choices. A-04 verifies they match current app conventions and records migration/compatibility effects before implementation. A-04 also verifies the macOS preference domain and that missing preference reads fail closed.

## 4. Task execution model

Every agent handoff uses this template:

~~~text
TASK ID:
TITLE:
ACCOUNTABLE ROLE:
CONTRIBUTING ROLES (read/review only unless a split task is assigned):
PREREQUISITES:
OWNED PATHS:
OUT-OF-SCOPE PATHS:
INPUT CONTRACT:
IMPLEMENTATION STEPS:
ACCEPTANCE CRITERIA:
VERIFICATION COMMANDS:
EXPECTED RESULTS:
EVIDENCE TO RETURN:
STOP CONDITIONS:
~~~

Required task completion report:

~~~text
Task:
Role:
Paths changed:
Behavior changed:
Acceptance criteria: PASS/FAIL per item
Commands:
Raw command results:
Tests added:
Known limitations:
New findings:
Reviewer:
~~~

A task can have multiple contributing roles only if write sets do not overlap and the interface contract is frozen. Otherwise R0 splits it into sequential tasks.

### Baseline and outcome metrics

“10/10” means each objective gate below passes with attached before/after evidence; it is not a claim of literal 50× improvement. A-05 records the measured starting value before implementation. An unavailable baseline is explicitly marked NOT MEASURED, then measured by its named validation task; it is never treated as zero.

| Metric | Baseline source | Required outcome | Proof task |
|---|---|---|---|
| Open Critical/High vulnerabilities | A-05 scanner outputs | 0 open Critical/High; agents cannot waive findings | C-03, F-02 |
| Python line coverage | A-05 pytest result, then C-09 full report | ≥85% suite; ≥90% fetch, provider, shaping, and bridge modules | C-10–C-15 |
| Ruff errors | A-05 | 0 | C-03, F-03 |
| MCP startup / quick-result / cancellation | A-05 where measurable | startup p95 <500 ms; quick-path first result p95 ≤20 s; cancellation ≤2 s | E-05-MCP |
| macOS launch / local history view | A-05 where measurable | launch p95 <2 s; local 10,000-record history load p95 <500 ms | E-05-SWIFT |
| VS Code history loading | A-05 command responsiveness and peak extension-host RSS where measurable | no synchronous disk/process I/O on the extension host; 3,000-row cap; JSONL scan ≤10 MiB; result-record ≤4 KiB (SQLite) / ≤64 KiB (JSONL); over-limit history produces a visible bounded error | E-07 |
| Memory / idle CPU | A-05 process measurements | MCP parent plus two jobs peak RSS ≤512 MiB; Swift app after 10,000-record load ≤300 MiB; idle MCP CPU <1% and app CPU <2% averaged over a 60-second idle sample | E-05-MCP, E-05-SWIFT |
| Measurement repeatability | A-05 if current runner is usable; otherwise NOT MEASURED | throughput CV ≤5% on declared controlled setup, else explicitly unqualified | E-03 |
| WCAG and contrast | A-05 Accessibility Inspector/axe results | 0 critical/serious automated violations; text ≥4.5:1; controls/focus ≥3:1 | D-04-TEST, D-05, D-06 |
| Time to first valid result | A-05, five consented novice users | median ≤5 minutes and 5/5 users complete without Terminal/facilitator intervention | D-07 |
| Landing CTA findability | A-05, five consented novice users | 5/5 find the correct install path within 10 seconds and distinguish free MCP from paid desktop without tracking cookies | D-08 |
| Crash-free/resource-clean runs | A-05 if a baseline harness exists; otherwise NOT MEASURED | ≥199/200 fixture runs; no child/temp-resource growth | E-04, E-06 |
| Privacy egress and retention | A-05 outbound request inventory | no analytics/phone-home; no remote AI without preference; all stored/sent fields and deletion semantics documented/tested | B-03, B-07, B-12, B-13, D-04 |
| Release artifact | A-05 current build/signature | reproducible universal arm64+x86_64 app, Developer ID signed, notarized/stapled, with SBOM/checksum/provenance | C-06, C-07, F-01 |

## 5. Task graph and specifications

### Gate A — Preserve state and establish executable baseline

#### A-01 — Capture audited working-tree state

- Owner: R9; R0 coordinates.
- Write set: `docs/reviews/upgrade-evidence.md` only.
- Prerequisite: user says GO before any implementation task begins.
- Steps: capture branch, commit, modified paths, untracked paths, and audit document checksums; identify audited findings in tracked versus uncommitted/untracked files.
- Acceptance: no existing user change is discarded; every pre-existing dirty path is listed; implementation does not overwrite a dirty path without its owner’s approval.
- Verify: git status --short --branch; git diff --stat; git ls-files --others --exclude-standard
- Stop: if a task needs a dirty file and ownership cannot be established, block only that task and continue independent tasks.

#### A-02 — Make baseline commands deterministic

- Owner: R5
- Write set: desktop/scripts/verify_phase0.sh, desktop/scripts/verify_phase1.sh only.
- Prerequisites: A-01, A-05.
- Scope: use the repository `.venv/bin/python3` when present, otherwise resolve `python3`; accept `NETMAX_PYTHON` as an explicit interpreter override for isolated-gate testing; fail early with an actionable message if the selected executable or its pytest module is missing. Both scripts must use identical selection logic, print the selected runtime version, and allocate/clean a unique SwiftPM/Clang cache under `TMPDIR` without disabling SwiftPM's subprocess sandbox. Do not alter test thresholds or suppress failures.
- Out of scope: app logic, reduced test scope, developer-specific absolute paths.
- Acceptance: both scripts select the same local interpreter by the documented rule; it satisfies `pyproject.toml`'s Python `>=3.10` requirement. CI remains pinned to Python 3.12 as recorded in `.github/workflows/ci.yml`. Missing Python or pytest fails before any build/test step, and every failed subcommand makes the gate nonzero.
- Verify: `bash -n desktop/scripts/verify_phase0.sh && bash -n desktop/scripts/verify_phase1.sh`; `bash desktop/scripts/verify_phase0.sh`; `bash desktop/scripts/verify_phase1.sh`.

#### A-03 — Establish reusable security test commands

- Owner: R5
- Write set: .github/workflows/ci.yml, requirements-ci.txt.
- Prerequisite: A-02.
- Scope: provision pinned Ruff, pytest, pip-audit, Bandit, Semgrep, Node, and Swift on supported CI runners. Add one documented command for each scan. Do not downgrade policy because a tool reports findings. Until C-02 creates npm lockfiles and C-04 repairs the plugin test entry point, do not treat npm audit or plugin npm test as passing gates; record them as pending setup.
- Acceptance: each command executes in CI and documented local setup; missing tools fail with explicit setup error.
- Verify: ruff check .; python3 -m pytest -q; pip-audit -r requirements-ci.txt; bandit -r . -x './.git,./desktop/SwiftNetMax/.build,./node_modules'; semgrep --config=p/python --error .; cd desktop/SwiftNetMax && swift test. Add `cd desktop && npm ci && npm audit --audit-level=high && npm test` after C-02, and `cd plugins/vscode && npm ci && npm test` after C-04.

#### A-04 — Verify frozen filesystem and preference contracts

- Owner: R0
- Write set: ROADMAP.md only.
- Prerequisite: A-01.
- Scope: compare the download root with existing product conventions; confirm the app history path from HistoryStore; confirm bundle identifier com.netmax.desktop; prove that defaults read returns a parseable Bool and that an absent key can be treated as false. Record any compatibility/migration requirement and update the contracts in this document before implementation begins.
- Out of scope: changing application files or creating the preference.
- Acceptance: each contract has a source reference and decision; no implementation agent must infer a path, domain, or default.
- Verify: source inspection confirmed `HistoryStore.defaultFileURL` resolves to `~/Library/Application Support/NetMaxDesktop/history.jsonl`, SQLite is a sidecar named `history.db`, and existing retention/clear semantics match the contract; `build_app.sh` declares bundle ID `com.netmax.desktop`; `defaults read com.netmax.desktop netmax.prefs.allowRemoteAI` returned “The domain/default pair ... does not exist.” No CLI default download directory exists; ordinary CLI fetch accepts its current URL-basename or caller-supplied path. Evidence is in A-04.

#### A-05 — Capture pre-change baselines for every scored metric

- Owner: R9
- Write set: `docs/reviews/upgrade-evidence.md` only.
- Prerequisite: A-01.
- Scope: capture current commit/tree state; Ruff/test/coverage results; pip/npm audit counts; Bandit/Semgrep findings; Swift build/test result; MCP/app cold-start and first-result timings where measurable; accessibility violations/contrast for named core screens; a five-person novice first-run test; and install-CTA findability on the landing page. Record unavailable tools, hardware, participants, and permissions explicitly as NOT MEASURED; never invent a baseline. Store raw outputs or artifact paths. Do not edit product/config/test files or install dependencies.
- Acceptance: every metric in the baseline table has a numeric value or explicit NOT MEASURED reason, tool/OS version, command or protocol, and raw evidence link.
- Verify: record outputs for `ruff check .`, `python3 -m pytest -q`, `pip-audit -r requirements-ci.txt`, `bandit -r . -x './.git,./desktop/SwiftNetMax/.build,./node_modules'`, `semgrep --config=p/python --error .`, `cd desktop && npm audit --audit-level=high`, and `cd desktop/SwiftNetMax && swift build && swift test`; attach the novice-test protocol and any Instruments trace.

### Gate B — Close security and data-loss paths

#### B-01-PY — Enforce download path confinement in the engine (parent gate)

- Owner: R1
- Prerequisite: A-04.
- Acceptance: the filesystem boundary and CLI wiring are independently scoped below; ordinary CLI destinations remain unchanged and MCP mode cannot select a path.
- Evidence: `docs/reviews/upgrade-evidence.md`, section B-01-PY.

##### B-01-PY-FS — Implement fixed-root atomic MCP download publication

- Owner: R1; Status: DONE.
- Write set: `netmax_fetch.py`, `desktop/engine/netmax_fetch.py`, and filesystem-boundary tests in `tests/test_fetch_mcp_boundary.py`.
- Scope: validate one basename at ≤180 UTF-8 bytes; reject dot segments, separators, and controls; establish a user-owned, non-symlink, non-group/world-writable `~/Downloads` and exact mode-0700 `NetMax` child; reject any existing final entry; download into a private same-volume temporary directory and atomically publish by no-replace hard link, yielding a mode-0600 file; remove only the private temporary directory on every exit. Mirror the engine byte-for-byte.
- Out of scope: CLI parser/wiring, MCP server changes, URL policy, and ordinary download semantics.
- Acceptance: traversal/absolute paths, unsafe parents, non-private roots, existing regular/symlink/directory targets, and publish races are rejected without modifying existing data; success stays under the fixed root; partial transfer leaves no temp files.
- Production lines: 87 distinct canonical added lines; byte-identical mirror is not double-counted. Tests are separate from the production-line cap.
- Verify: `.venv/bin/python3 -m pytest tests/test_fetch_mcp_boundary.py tests/test_netmax_fetch.py -q`.

##### B-01-PY-CLI — Wire the MCP-only hidden fetch flag

- Owner: R1; Status: DONE; starts only after B-01-PY-FS.
- Write set: `netmax.py`, `desktop/engine/netmax.py`, and CLI cases in `tests/test_fetch_mcp_boundary.py` (serialized after the filesystem subtask; no concurrent write to the shared test file).
- Scope: add hidden `--mcp-output-name BASENAME`; reject combination with positional `out`; validate the name before download; dispatch MCP mode to `download_mcp`; keep ordinary `_safe_fetch_out` and `download` behavior unchanged. Mirror byte-for-byte.
- Out of scope: filesystem policy implementation and MCP-server argument construction.
- Acceptance: hidden option parses, positional conflict exits 2 before download, valid MCP mode passes only URL/name/stream count, and ordinary output path remains unchanged.
- Production lines: 18 distinct canonical added lines for this task; byte-identical mirror is not double-counted. Pre-existing AI-signature changes are excluded. Tests are separate from the production-line cap.
- Verify: `.venv/bin/python3 -m pytest tests/test_fetch_mcp_boundary.py tests/test_netmax_fetch.py -q`.

#### B-01-MCP — Restrict MCP download argument to a basename

- Owner: R2
- Write set: desktop/netmax-mcp-server.mjs, desktop/test_mcp_download_boundary.mjs.
- Prerequisite: B-01-PY publishes the basename/output contract.
- Scope: derive the default basename from the URL pathname, falling back to `download`; validate one basename and reject separators, dot segments, empty names, NUL/control characters, and values over 180 UTF-8 bytes before spawning. Spawn exactly `fetch URL --mcp-output-name BASENAME`; never pass output as positional `out`.
- Out of scope: Python path enforcement, downloader implementation, arbitrary export destinations.
- Acceptance: invalid names produce zero child spawns; valid and derived default names reach the engine unchanged as the `--mcp-output-name` value; child argv contains no positional output path.
- Verify: cd desktop && node --test test_mcp_download_boundary.mjs
- Production lines: 23 canonical added lines; test code excluded from the production-line cap.

#### B-02 — Restrict AI history reads and bound input size (parent gate)

- Owner: R0 coordinates R1 then R2; Status: DONE; evidence in `docs/reviews/upgrade-evidence.md`, section B-02.
- Prerequisites: A-04, B-01-PY, B-01-MCP.
- Status becomes DONE only after B-02-PY and B-02-MCP pass.

##### B-02-PY — Enforce the MCP-only history read boundary

- Owner: R1; Status: DONE. Write set: `netmax.py`, `desktop/engine/netmax.py`, `netmax_history.py`, `desktop/engine/netmax_history.py`, `tests/test_ai_history_boundary.py`.
- Scope: add hidden `--mcp-request` to AI mode; under that flag reject `--input @path`, and allow `--history` only when its lexical path equals `~/Library/Application Support/NetMaxDesktop/history.jsonl`. Open each path component relative to a no-follow directory descriptor; reject symlinks, wrong owners, non-regular final files, files over 10 MiB, and over 100,000 non-empty rows. Preserve local CLI import behavior unchanged. Mirror Python files byte-for-byte.
- Out of scope: MCP server wiring, history schema, archive deletion, retention changes, and general CLI import changes.
- Acceptance: canonical file succeeds; outside path, each symlinked component, directory, non-regular file, oversized file, and row overflow fail closed; invalid path fails before analysis dispatch; existing CLI `@path` and arbitrary `--history` tests continue to pass without `--mcp-request`.
- Production lines: 78 distinct canonical added lines; mirrors not double-counted; tests excluded.
- Verify: `.venv/bin/python3 -m pytest tests/test_ai_history_boundary.py tests/test_netmax_ai_cli.py tests/test_netmax_history.py -q`.

##### B-02-MCP — Apply the restricted history mode to MCP AI calls

- Owner: R2; Status: DONE; starts after B-02-PY; write set: `desktop/netmax-mcp-server.mjs`, `desktop/test_mcp_ai_history_boundary.mjs`.
- Scope: every `ai_analyze` engine argv includes `--mcp-request`; preserve input and history values otherwise. Do not add another MCP path or filesystem read.
- Out of scope: Python enforcement, provider egress, schema redesign.
- Acceptance: integration test observes the flag; MCP `@path` input and noncanonical history are denied by the engine before the fake engine reaches analysis; normal inline JSON remains accepted.
- Production lines: 1 canonical added line; tests excluded.
- Verify: `cd desktop && node --test test_mcp_ai_history_boundary.mjs`.

#### B-03-SPEC — Record the remote-AI preference key in the shared contract

- Owner: R8
- Write set: docs/product/mission-l3-graph.md only.
- Prerequisite: A-04.
- Scope: add exact Bool key netmax.prefs.allowRemoteAI, default false, owned by AppPreferences.shared; document that MCP cannot toggle it and that an absent value means false.
- Out of scope: changing Swift or Python code.
- Acceptance: the shared preference contract contains exactly one definition of this key, type, default, owner, and consumer behavior.
- Verify: rg -n 'allowRemoteAI|AppPreferences' docs/product/mission-l3-graph.md

#### B-03-PREF — Add the remote-AI preference to AppPreferences

- Owner: R6
- Status: DONE
- Write set: `desktop/SwiftNetMax/Sources/netmax-desktop/AppPreferences.swift`; create `desktop/SwiftNetMax/Tests/netmax-desktopTests/AppPreferencesRemoteAITests.swift`.
- Prerequisites: A-04; B-03-SPEC.
- Scope: add Bool key netmax.prefs.allowRemoteAI with default false; expose a published property; persist/read it only through AppPreferences.shared; add no other preference behavior.
- Out of scope: provider requests, MCP changes, changing existing preference keys.
- Acceptance: fresh UserDefaults returns false; set/get persists true then false; no other key changes; tests use injected UserDefaults.
- Verify: `cd desktop/SwiftNetMax && swift test --filter AppPreferencesRemoteAITests`.

#### B-03-SETTINGS — Expose provider and data disclosure in Settings

- Owner: R6
- Status: DONE
- Write set: `desktop/SwiftNetMax/Sources/netmax-desktop/SettingsView.swift`; create `desktop/SwiftNetMax/Tests/netmax-desktopTests/RemoteAISettingsTests.swift`.
- Prerequisites: B-03-PREF.
- Scope: add one setting toggle default off, show configured provider name and exact data categories sent, and state that MCP cannot change this preference. Do not show API key material.
- Out of scope: provider implementation, storing API keys, telemetry, account creation.
- Acceptance: setting is accessible via keyboard/VoiceOver; displayed provider matches resolved configuration; no secret value is displayed; toggle persists through AppPreferences.shared.
- Verify: cd desktop/SwiftNetMax && swift test --filter RemoteAISettingsTests
- Production lines: 76 canonical added lines; test code excluded. Native SwiftUI Toggle carries explicit label/hint/identifier; provider label uses the same environment precedence as the Python resolver without displaying endpoint or key values.

#### B-03-PY — Enforce remote-AI preference before request construction

- Owner: R1
- Write set: `netmax_ai_provider.py`, `desktop/engine/netmax_ai_provider.py`, `tests/test_ai_egress_policy.py`, and provider/caller unit-test fixtures in `tests/test_netmax_ai_provider.py`, `tests/test_netmax_ai.py`, `tests/test_netmax_ai_p1.py`, and `tests/test_netmax_ai_p2.py` only.
- Prerequisites: B-03-PREF; B-02; B-06; A-04.
- Scope: before constructing the HTTP request body or opening a socket, read `/usr/bin/defaults` with argv (never shell) from domain `com.netmax.desktop`, key `netmax.prefs.allowRemoteAI`. Missing, unreadable, timeout, or non-Bool response means false. Reject remote requests when false. Exact loopback providers remain available. Project requests to the exact Remote-AI payload schema above; reject unknown keys, free text, and raw history rows. Any useful history must already be reduced by its caller to the approved numeric aggregates; the provider boundary never receives or transforms raw history.
- Out of scope: changing provider catalog, keychain logic, prompt content, UI.
- Acceptance: unset/false/malformed preference causes zero HTTP requests; true permits configured remote provider using only the exact schema fields; local provider remains available; preference read has a bounded timeout and no shell. Recording server asserts exact keys and rejects excluded canary values; malformed/unknown input causes zero request bytes.
- Verify: `.venv/bin/python3 -m pytest tests/test_ai_egress_policy.py tests/test_netmax_ai_provider.py tests/test_netmax_ai.py tests/test_netmax_ai_p1.py tests/test_netmax_ai_p2.py -q`
- Evidence: fake transport sees zero calls when consent is false or payload is invalid, and sees only the canonical allowlisted JSON after consent is true. This test suite uses no external network.

#### B-03-MCP — Verify MCP reports egress denial without override

- Owner: R2
- Write set: `desktop/test_mcp_ai_egress.mjs` only. If the server description is misleading, open a separate one-file R2 task before editing it.
- Prerequisite: B-03-PY.
- Scope: invoke ai_analyze through MCP with consent denied at the engine boundary; assert the local-only result is labeled `source: local` and the provider transport is never reached. Verify the MCP schema exposes no consent override and a remote-AI environment variable cannot bypass the denial.
- Out of scope: changing preference storage or Python provider policy.
- Acceptance: a real stdio MCP client receives the local fallback, the provider-attempt marker remains absent, and the tool schema contains only `analysis`, `history_path`, `input`, and `pretty`.
- Verify: cd desktop && node --test test_mcp_ai_egress.mjs

#### B-03-DOCS — Document remote-AI data flow

- Owner: R8
- Write set: create `docs/privacy/remote-ai-data-flow.md`; update `docs/THREAT-MODEL.md` and `desktop/MCP-README.md` only where remote-AI statements need correction.
- Prerequisites: B-03-SETTINGS and B-03-PY.
- Scope: list provider, request fields, local-only alternative, default-off setting, and exact user action required to enable. Explicitly state that MCP cannot grant consent.
- Out of scope: changing code or making provider retention claims unsupported by provider documentation.
- Acceptance: docs match the actual request payload and setting; no “everything stays local” claim conflicts with enabled remote AI behavior.
- Verify: `rg -n -i 'allowRemoteAI|remote AI|provider|measurement|history|local' docs/privacy docs/THREAT-MODEL.md desktop/MCP-README.md`

#### B-11 — Validate schemas and reject invalid calls for all MCP tools

- Owner: R2
- Write set: `desktop/test_mcp_schema_contract.mjs` only; server source is read-only in this task.
- Prerequisite: B-01-MCP, B-03-MCP, B-07, and B-08.
- Scope: enumerate all 17 registered tools; for each, test required fields, optional fields, lower/upper bounds, wrong types, unknown enum/name values, and invalid URL/path cases. Invalid calls must fail before subprocess/network side effects. Do not change tool semantics in this test task; if an invalid schema is found, create a separate narrowly scoped implementation task.
- Out of scope: changing tool output schema or adding tools.
- Acceptance: every registered tool has at least one valid-schema test and one rejected-boundary test; the test fails if a new tool is added without a case.
- Verify: cd desktop && node --test test_mcp_schema_contract.mjs

#### B-12 — Verify support-bundle and diagnostic-log redaction

- Owner: R1
- Write set: netmax_bundle.py, tests/test_support_bundle_privacy.py.
- Prerequisite: A-01.
- Scope: use synthetic secrets and identifiers for API keys, bearer tokens, webhook URLs, SSID/BSSID, usernames, absolute home paths, and raw history text. Confirm bundle redaction/drop rules and size limits. Fix only demonstrated leaks; do not change bundle format unnecessarily.
- Out of scope: Swift UI layout and provider retention policy.
- Acceptance: no synthetic secret/identifier appears in archive contents, manifest, or error log; known safe metrics remain; tests cover nested structures and strings.
- Verify: python3 -m pytest tests/test_support_bundle_privacy.py -q

#### B-13-PRIVACY-SPEC — Publish the local-history retention/deletion contract

- Owner: R8
- Write set: create `docs/privacy/data-inventory.md` only.
- Prerequisites: A-04; history retention/deletion contract above.
- Scope: enumerate `history.jsonl`, `history.db` and sidecars, `archive-history.jsonl`, `cleared-history.jsonl`, settings, logs, and user-created support bundles; state location, permissions, purpose, retention behavior, outbound status, and deletion action for each. Preserve the existing rule that retention archives rather than silently destroys rows.
- Acceptance: every persisted category has a location, owner, retention rule, and tested/documented deletion path; document explicitly that permanent erase is irreversible and does not remove settings or user-created exports.
- Verify: `rg -n 'history.jsonl|history.db|archive-history|cleared-history|retentionDays|permanent erase|outbound' docs/privacy/data-inventory.md`.

#### B-13-SQLITE-ERASE — Add an isolated SQLite history-store erase primitive

- Owner: R6
- Status: DONE
- Write set: `desktop/SwiftNetMax/Sources/netmax-desktop/HistorySQLite.swift`; create `desktop/SwiftNetMax/Tests/netmax-desktopTests/HistorySQLiteEraseTests.swift`.
- Prerequisite: B-13-PRIVACY-SPEC.
- Scope: add one testable operation that closes/checkpoints the active SQLite handle, removes the database plus `-wal`/`-shm` sidecars for the configured history store only, resets cached connection state, and allows a subsequent append to create a fresh database. Tests inject a temporary database URL and never touch the user’s real history.
- Acceptance: after erase, DB and sidecars are absent; next append/load works; permission/I/O failure is returned, not logged as success; files outside the configured basename are untouched.
- Verify: `cd desktop/SwiftNetMax && swift test --filter HistorySQLiteEraseTests`.

#### B-13-STORE-ERASE — Erase all history formats and archive files

- Owner: R6
- Status: DONE
- Write set: `desktop/SwiftNetMax/Sources/netmax-desktop/HistoryStore.swift`; create `desktop/SwiftNetMax/Tests/netmax-desktopTests/HistoryStoreEraseTests.swift`.
- Prerequisite: B-13-SQLITE-ERASE.
- Scope: add a serialized erase-all operation that invokes the SQLite primitive and removes only configured `history.jsonl`, `archive-history.jsonl`, and `cleared-history.jsonl`; return per-file success/failure; refresh observers only after completion. Do not delete preferences, logs, support bundles, or other directory contents.
- Acceptance: isolated temp-store test verifies all four history artifacts absent on success, append works afterward, unrelated sentinel file remains, and injected failure is reported without false-success state.
- Verify: `cd desktop/SwiftNetMax && swift test --filter HistoryStoreEraseTests`.

#### B-13-UI-ERASE — Add explicit irreversible erase confirmation

- Owner: R6
- Status: DONE
- Write set: `desktop/SwiftNetMax/Sources/netmax-desktop/HistoryView.swift`; create `desktop/SwiftNetMax/Tests/netmax-desktopTests/HistoryEraseConfirmationTests.swift`.
- Prerequisite: B-13-STORE-ERASE.
- Scope: add a separate History action labeled “Erase All History…”; confirmation names live history, retention archive, and cleared-history holding bin, states the action cannot be undone, and requires explicit destructive confirmation. Existing reversible Clear/Undo behavior is unchanged.
- Acceptance: cancel causes zero store calls; confirm calls erase exactly once; progress/error are visible and VoiceOver-labeled; partial failure is never shown as success.
- Verify: `cd desktop/SwiftNetMax && swift test --filter HistoryEraseConfirmationTests`; attach manual VoiceOver confirmation-flow result.

#### B-04 — Make bridge envelope creation race-safe

- Owner: R3
- Write set: desktop/bridge/engine_bridge.py, desktop/bridge/test_engine_bridge.py.
- Prerequisite: A-01.
- Scope: create envelope in private temp directory; create files exclusively with no-follow semantics and 0600; write temp sibling and atomically publish; verify parent ownership/permissions; clean temp files on success and failure.
- Out of scope: changing JSON schema or Node argument contract.
- Acceptance: pre-created symlink and existing-file targets rejected; envelope is complete JSON; no partial target visible; cleanup after injected write/serialization failures.
- Verify: python3 -m pytest desktop/bridge/test_engine_bridge.py -q; python3 desktop/bridge/engine_bridge.py selftest
- Production lines: 71 distinct added lines; focused tests and generated temporary files are excluded.

#### B-05 — Bound AI governor outputs

- Owner: R1
- Write set: `netmax_ai_provider.py` and desktop mirror; `netmax_ai.py` and desktop mirror; `netmax.py` and desktop mirror; `tests/test_ai_governor_bounds.py`; bounded-response fixtures in `tests/test_netmax_ai_provider.py` and updated valid-cap expectation in `tests/test_netmax_ai.py`.
- Prerequisites: A-01, B-02 (R1 netmax.py write serialization).
- Scope: reject NaN, positive/negative infinity, negative pacing, values above existing 1.5x target ceiling, streams outside 1..50, malformed numeric strings, provider bodies over 1 MiB, nesting deeper than 16, and unknown response keys. Reapply deterministic ceiling after AI decision. Invalid AI output falls back to deterministic governor without interrupting measurement. Treat response strings as inert escaped display text; no output may become a shell argument, URL, filesystem path, or tool invocation.
- Out of scope: changing target algorithm, prompt wording, or provider schema beyond validation.
- Acceptance: every invalid value is covered; accepted pace never exceeds ceiling; provider errors still yield bounded measurement; hostile response fixtures cannot trigger a tool/process/network action or unescaped markup; mirrors match.
- Verify: `.venv/bin/python3 -m pytest tests/test_ai_governor_bounds.py tests/test_netmax_ai.py tests/test_netmax_ai_p1.py tests/test_netmax_ai_provider.py -q`

#### B-06 — Enforce URL policy for downloads and custom AI providers

- Owner: R1
- Write set: netmax_fetch.py and mirror; netmax_ai_provider.py and mirror; tests/test_fetch_url_policy.py; tests/test_ai_endpoint_policy.py.
- Prerequisites: A-04, B-01-PY (R1 netmax_fetch.py write serialization).
- Scope: parse URLs structurally; reject unsupported schemes, credentials, malformed hosts, and disallowed loopback/link-local/private/multicast/metadata targets; validate each redirect; cap redirects at 5 and response size at exactly 1 GiB. Exact loopback IPs/localhost are local; substring matches do not count.
- Out of scope: arbitrary proxy support, certificate bypass, endpoint catalog.
- Acceptance: HTTP/HTTPS policy explicit; file:, ftp:, encoded host tricks, DNS-to-private, redirect-to-private, and lookalike localhost covered; exact local endpoint behavior remains tested.
- Verify: `.venv/bin/python3 -m pytest tests/test_fetch_url_policy.py tests/test_ai_endpoint_policy.py tests/test_netmax_fetch.py tests/test_netmax_ai_provider.py -q`

#### B-07-CONFIG — Parse a strict fleet alias/origin/token contract

- Owner: R2; Status: DONE; write set: `desktop/netmax-mcp-server.mjs`, `desktop/test_mcp_fleet_policy.mjs`.
- Prerequisites: A-04; B-01-MCP (R2 server-file serialization).
- Scope: parse `NETMAX_FLEET_ALLOWLIST` as unique alias→exact-origin JSON strings and optional `NETMAX_FLEET_TOKENS` as alias→token JSON strings. Only HTTPS origins with host and optional port are accepted; path must be empty or `/`, and userinfo/query/fragment are forbidden. Alias format is `[a-z][a-z0-9_-]{0,31}`. Reject duplicate keys, unknown token aliases, invalid types, controls, and oversized configuration before any DNS or network operation.
- Out of scope: connecting to peers, legacy env support removal, dashboard redesign.
- Acceptance: malformed JSON, duplicate keys, malformed aliases, duplicate/unknown token alias, non-string values, and every invalid URL component fail before lookup/request; valid JSON produces the exact alias map.
- Verify: `cd desktop && node --test test_mcp_fleet_policy.mjs`.

#### B-07-DNS — Validate every fleet DNS answer and return a pinned target

- Owner: R2; Status: DONE (`resolveFleetTarget`, ~35 production lines; 8/8 `test_mcp_fleet_policy.mjs` pass); write set: `desktop/netmax-mcp-server.mjs`, `desktop/test_mcp_fleet_policy.mjs`.
- Prerequisite: B-07-CONFIG.
- Scope: resolve all addresses immediately before use; fail closed if any answer is private, loopback, link-local, multicast, reserved, documentation, unspecified, or otherwise non-global. Return one validated address plus its address family while retaining the configured hostname for TLS. Do not connect in this task.
- Out of scope: HTTP request construction, redirects, response handling, route cutover.
- Acceptance: IPv4/IPv6 special-use ranges, valid global addresses, empty/malformed DNS answers, and mixed public/private answer sets have exact tests; no connection function is called from the resolver.
- Verify: `cd desktop && node --test test_mcp_fleet_policy.mjs`.

#### B-07-HTTP — Pin HTTPS requests and bound fleet responses

- Owner: R2; Status: DONE (`fleetRequest`; 15/15 fleet tests pass); write set: `desktop/netmax-mcp-server.mjs`, `desktop/test_mcp_fleet_policy.mjs`.
- Scope: construct HTTPS requests using the pinned DNS address while preserving hostname/SNI/certificate validation; disable redirects; cap connection time at 5 seconds and response body at 16 KiB; attach only that alias's token to its exact origin. Use injected lookup/transport seams in tests; do not add a production HTTP or certificate-bypass switch.
- Out of scope: route integration, peer enrollment, custom CAs, reusable fleet credentials.
- Acceptance: request options pin the address, retain TLS verification/hostname, and contain only the selected peer token; redirects, oversized bodies, and timeout fail closed before response data is accepted.
- Verify: `cd desktop && node --test test_mcp_fleet_policy.mjs`.

#### B-07-CUTOVER — Route fleet reporting through the strict policy

- Owner: R2; Status: DONE (`fleetStatus` routed through strict policy; legacy vars removed; README updated); write set: `desktop/netmax-mcp-server.mjs`, `desktop/test_mcp_fleet_policy.mjs`, `desktop/MCP-README.md`.
- Scope: make `/fleet` and `/fleet/board` use only allowlisted aliases and bounded transport; remove `NETMAX_FLEET`/`NETMAX_FLEET_TOKEN` parsing and references; document the two new JSON environment variables and exact HTTPS-only behavior. Cap configured peers at 32.
- Out of scope: dashboard redesign, peer enrollment, changing auth for MCP clients.
- Acceptance: route returns one bounded status per configured alias, invalid configuration makes zero peer requests, legacy variables have no effect, and README matches actual variable names and limits.
- Verify: `cd desktop && node --test test_mcp_fleet_policy.mjs`; `rg -n 'NETMAX_FLEET_ALLOWLIST|NETMAX_FLEET_TOKENS|NETMAX_FLEET_TOKEN|NETMAX_FLEET=' desktop/netmax-mcp-server.mjs desktop/MCP-README.md`.

#### B-08 — Enforce MCP concurrency and resource budgets

- Owner: R2
- Write set: desktop/netmax-mcp-server.mjs, desktop/test_mcp_resource_limits.mjs.
- Prerequisites: B-07 (R2 server-file serialization); MCP resource budget contract.
- Scope: enforce ≤300 aggregate stream-seconds per measurement call, ≤180 seconds wall time, at most 2 active measurement jobs process-wide, and at most 1 active measurement job per MCP session. Reject before child spawn. On cancellation/disconnect send SIGTERM, wait ≤2 seconds, then SIGKILL and reap the owned child. Return stable structured busy/limit errors.
- Out of scope: changing internal engine algorithms.
- Acceptance: tests prove 300/301 aggregate stream-second boundary, 180/181 wall-second boundary using fake timers, global concurrency 2/3, per-session concurrency 1/2, and zero child spawn on rejection; cancellation reaps the child within 2 seconds.
- Verify: cd desktop && node --test test_mcp_resource_limits.mjs

#### B-09 — Make pf/dnctl apply transactional

- Owner: R4
- Write set: netmax_shape.py, desktop/engine/netmax_shape.py, tests/test_pf_transactional.py.
- Prerequisite: shaping ownership contract.
- Scope: capture pre-call pf enabled state and current rules; check every mutation command return code; on any setup failure remove only the new `netmax_strict_limit` anchor reference and allocated pipe, restore the exact prior pf enabled/disabled state, and return both primary and rollback errors. Never reload a stale whole-ruleset snapshot over changes made by another firewall manager. Treat existing legacy anchor `netmax` or pipe 10 as foreign: refuse and print recovery instructions; never flush them.
- Out of scope: rate semantics or anchor renaming.
- Acceptance: injected failure at each pfctl/dnctl stage restores prior state; success installs expected state; root check remains; mirrors match.
- Verify: python3 -m pytest tests/test_pf_transactional.py tests/test_netmax_shape.py -q

#### B-10 — Serialize shaping and make cleanup owner-scoped

- Owner: R4
- Write set: netmax_shape.py, mirror, tests/test_pf_locking.py.
- Prerequisite: B-09.
- Scope: acquire root-owned `/var/run/netmax-shaping.lock` with `fcntl.flock` before preflight; persist PID/random token/allocated pipe/prior pf enabled state atomically in `/var/run/netmax-shaping/owner.json` mode 0600; choose first unused pipe ID in 20000–29999; reject a second owner. On exit/exception/timeout/cancellation/SIGTERM remove only the exact owner’s `netmax_strict_limit` anchor and pipe. Before a later invocation, if the owner PID is dead, validate markers and restore the recorded state; if ownership cannot be proven, fail closed and provide the manual recovery command. SIGKILL recovery is next-invocation recovery, not instantaneous cleanup.
- Out of scope: cross-machine coordination and simultaneous profiles.
- Acceptance: two-process contention proves one owner; wrong-token cleanup leaves active state byte-identical; SIGTERM cleans immediately; SIGKILL leaves a stale record that the next invocation recovers only after PID/marker checks; ambiguous ownership refuses cleanup; tests never call host pf/dnctl.
- Verify: python3 -m pytest tests/test_pf_locking.py tests/test_netmax_shape.py -q

### Gate C — Close documentation, CI, and supply-chain gaps

#### C-01 — Align threat model and operator/privacy documentation

- Owner: R8
- Write set: `docs/THREAT-MODEL.md`, `desktop/MCP-README.md`, `README.md`; create `docs/product/landing-claims.md`.
- Prerequisites: B-03-DOCS, B-07, B-08, B-09, B-10, B-12, B-13-PRIVACY-SPEC, B-13-UI-ERASE.
- Scope: document trust boundaries, HTTP bind/auth/TLS, root shaping impact, fleet egress, AI egress, history path controls, download output controls, logs/bundles, recovery. In `landing-claims.md`, list every visible landing-page claim and CTA with exact target, supporting evidence, and KEEP/REMOVE status; verify external install/purchase destinations before KEEP. Remove claims contradicting implementation. Do not claim mitigation before owner task is DONE.
- Out of scope: runtime behavior or new features.
- Acceptance: each network destination, privileged operation, data category, and confirmation is documented; stale no-server/root/inbound claims gone; examples match tool schemas; every public landing claim/action has an evidence-backed KEEP/REMOVE decision.
- Verify: rg -n 'No server component|No inbound network|There is no root|NETMAX_HOST|strict_limit|history_path|NETMAX_FLEET|remote AI' docs desktop/MCP-README.md README.md

#### C-02 — Make dependency resolution reproducible and auditable

- Owner: R5
- Write set: pyproject.toml dependency metadata, uv.lock, requirements-ci.txt, desktop/package.json and lock, plugin package manifest/lock.
- Prerequisite: A-03.
- Scope: regenerate the existing `uv.lock` from the declared Python dependencies; regenerate each npm lock only from its matching package manifest; add a pinned `pytest-cov` version to CI dependencies; define whether the VS Code extension bundles or externalizes each runtime dependency; pin audit tool versions. No major dependency upgrades and no lockfile generated from a changed manifest left uncommitted.
- Out of scope: dependency major version bumps.
- Acceptance: clean locked install succeeds; package name/version match manifest and lock root; audit commands return results; CI does not silently regenerate locks.
- Verify: uv sync --frozen; cd desktop && npm ci --ignore-scripts; cd plugins/vscode && npm ci --ignore-scripts; pip-audit -r requirements-ci.txt; cd desktop && npm audit --audit-level=high

#### C-03 — Add security scans and immutable action references to CI

- Gate only. Its implementation children are C-03-SCANS, C-03-PIN-CI, and C-03-PIN-SECURITY. Each child changes fewer than 100 production lines; C-03 is DONE only after all three pass.
- Prerequisites: A-03, C-02.
- Acceptance: named tests/scans execute on pull requests, Critical/High fail, SARIF is uploaded, exceptions are versioned with owner/reason/expiry, and every third-party action ref is a reviewed commit SHA.

#### C-03-SCANS — Add pull-request security scan workflow

- Owner: R5
- Write set: create `.github/workflows/security.yml` only.
- Prerequisites: A-03, C-02.
- Scope: on pull requests and manual dispatch, install from frozen lockfiles and run Ruff, pytest, pip-audit, npm audit for desktop and VS Code packages, Bandit, Semgrep, Swift tests, bridge tests, and Node package tests. Set Critical/High to fail. Generate SARIF for supported scanners and upload it. Do not add suppressions or SBOM generation here. Maximum workflow diff: 99 lines.
- Acceptance: clean PR runner executes every listed command; absent lock/tool fails clearly; SARIF artifact exists; no severity threshold is weakened.
- Verify: `gh workflow run security.yml --ref <review-branch>`; inspect each job result and download SARIF.

#### C-03-PIN-CI — Pin existing CI actions by reviewed commit SHA

- Owner: R5
- Write set: `.github/workflows/ci.yml` only.
- Prerequisite: C-02.
- Scope: replace every third-party action tag/branch in this workflow with the exact reviewed 40-character commit SHA; add a same-line human-readable version comment. No job behavior changes. Maximum diff: 99 lines.
- Acceptance: every `uses:` entry is a full SHA and each SHA maps to the stated upstream release; no unreviewed action remains.
- Verify: `rg -n 'uses:.*@(v[0-9]|main|master|[A-Za-z]+)$' .github/workflows/ci.yml` returns no matches; attach upstream release-to-SHA mapping.

#### C-03-PIN-SECURITY — Pin scan workflow actions and severity policies

- Owner: R5
- Write set: `.github/workflows/security.yml` only.
- Prerequisite: C-03-SCANS.
- Scope: replace every action tag/branch with reviewed full commit SHA; record action version comments; confirm security findings produce nonzero status and SARIF upload does not mask a scan failure. Maximum diff: 99 lines.
- Acceptance: all `uses:` entries are full SHAs; clean and seeded-finding runs produce expected pass/fail statuses; SARIF upload is attached.
- Verify: `rg -n 'uses:.*@(v[0-9]|main|master|[A-Za-z]+)$' .github/workflows/security.yml` returns no matches; run the seeded-finding workflow and attach output.

#### C-04 — Repair VS Code plugin verification entry point

- Owner: R5
- Write set: `plugins/vscode/package.json`, `plugins/vscode/package-lock.json`, `.github/workflows/ci.yml`.
- Prerequisites: C-02, C-03.
- Scope: set the manifest script to exactly `node --test test/*.test.js`; generate the lockfile from that unchanged manifest; add a CI step that runs `npm ci && npm test` from `plugins/vscode/`.
- Out of scope: extension functionality or new test framework.
- Acceptance: local and CI invoke same test set; missing test file fails.
- Verify: `cd plugins/vscode && npm ci && npm test`.

#### C-05 — Independently verify local verification gates

- Owner: R9
- Write set: `docs/reviews/upgrade-evidence.md` only.
- Prerequisite: A-02.
- Scope: execute both gates from a clean documented environment, then remove pytest from a temporary test environment and confirm the gate fails before running tests with an actionable message.
- Out of scope: editing scripts or suppressing diagnostics.
- Acceptance: both gates pass in the documented environment; missing pytest causes early actionable failure; raw logs are attached.
- Verify: run both scripts normally; then set `NETMAX_TEST_VENV=$(mktemp -d /tmp/netmax-no-pytest.XXXXXX)`; run `python3 -m venv "$NETMAX_TEST_VENV"`; run `NETMAX_PYTHON="$NETMAX_TEST_VENV/bin/python" bash desktop/scripts/verify_phase0.sh` and `NETMAX_PYTHON="$NETMAX_TEST_VENV/bin/python" bash desktop/scripts/verify_phase1.sh`; both must fail before pytest invocation with the documented missing-pytest message. Attach raw output.

#### C-06 — Verify release architecture in CI

- Owner: R5
- Write set: `.github/workflows/ci.yml`, `desktop/scripts/build_app.sh`.
- Prerequisites: C-03, C-04.
- Scope: build arm64 and x86_64; create universal app artifact; assert both slices with lipo; validate bundle.
- Out of scope: signing credentials and product source.
- Acceptance: CI artifact contains both architectures; missing slice fails; app bundle/Info.plist validate.
- Verify: bash desktop/scripts/build_app.sh; lipo -info desktop/build/NetMaxDesktop.app/Contents/MacOS/NetMaxDesktop; plutil -lint desktop/build/NetMaxDesktop.app/Contents/Info.plist

#### C-16 — Prove clean-checkout build reproducibility (gate)

- Children C-16-METADATA, C-16-HARNESS, and C-16-CI. This gate compares two builds of the same committed source SHA with the same frozen dependencies; signatures, notarization tickets, and filesystem timestamps are excluded from the comparison.
- Prerequisite: C-06.
- Acceptance: executable and non-signature app resources have identical SHA-256 manifests across two independent clean build directories; any variance blocks C-07 signing and is assigned to a bounded corrective task.

#### C-16-METADATA — Make bundle date fields reproducible on request

- Owner: R5
- Write set: `desktop/scripts/build_app.sh` only.
- Prerequisite: C-06.
- Scope: read optional `SOURCE_DATE_EPOCH`; when set, validate it as a nonnegative integer and derive both `APP_BUILD` and `BUILD_DATE` from that epoch using macOS `date -u -r`. When unset, preserve the current wall-clock timestamp behavior. Do not change versioning, displayed copy, signing, or any Swift file. Maximum production diff: 99 lines.
- Acceptance: malformed/negative values fail before app assembly; one fixed epoch produces identical `CFBundleVersion` and `NetMaxBuildDate` across separate invocations; unset value remains current-time based.
- Verify: `bash -n desktop/scripts/build_app.sh`; C-16-HARNESS compares `Contents/Info.plist` values across both isolated builds and passes the same explicit epoch to each.

#### C-16-HARNESS — Compare two clean universal builds

- Owner: R5
- Write set: create `desktop/scripts/verify_reproducible_build.sh` only.
- Prerequisites: C-06, C-16-METADATA.
- Scope: accept one committed source SHA; create one unique temporary root with `mktemp -d`, then two child source directories named `source-a` and `source-b`. For each, export exactly that commit with `git -C "$REPO_ROOT" archive "$SOURCE_SHA" | tar -x -C "$TEMP_SOURCE"`. Set `SOURCE_DATE_EPOCH=$(git -C "$REPO_ROOT" show -s --format=%ct "$SOURCE_SHA")`. In each copy run `(cd "$TEMP_SOURCE" && uv sync --frozen)`, `(cd "$TEMP_SOURCE/desktop" && npm ci --ignore-scripts)`, `(cd "$TEMP_SOURCE/plugins/vscode" && npm ci --ignore-scripts)`, and `(cd "$TEMP_SOURCE/desktop/SwiftNetMax" && swift package resolve --force-resolved-versions)`, then run `SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" bash "$TEMP_SOURCE/desktop/scripts/build_app.sh"`. Remove signatures only from temporary app copies and compare executable plus every non-signature resource SHA-256 manifest. Never use `git clean`, never write into the caller’s checkout, and delete only the temp root created by this script after both manifests are saved. Maximum production diff: 99 lines.
- Acceptance: equal inputs produce equal manifests; mismatches print exact relative paths and expected/actual hashes; missing tools or a SHA that does not resolve to a commit fail with actionable text. The caller’s dirty/untracked files remain untouched and are not included in the explicitly selected commit build.
- Verify: `bash -n desktop/scripts/verify_reproducible_build.sh`; `desktop/scripts/verify_reproducible_build.sh "$SOURCE_SHA"` where `SOURCE_SHA` is the full commit SHA recorded in A-01.

#### C-16-CI — Run reproducibility comparison on pull requests

- Owner: R5
- Write set: create `.github/workflows/reproducible-build.yml` only.
- Prerequisites: C-16-HARNESS; C-03-PIN-CI.
- Scope: run the harness against the PR head commit on a macOS runner; upload both build manifests and fail on any non-signature difference. Pin every action by full reviewed SHA. Maximum workflow diff: 99 lines.
- Acceptance: pull request receives a required reproducibility check; changing a binary/resource without deterministic inputs fails; artifacts identify the exact source SHA.
- Verify: `gh workflow run reproducible-build.yml --ref <review-branch>`; inspect check status and both manifests.

#### C-07 — Replace ad-hoc signing with notarized distribution

- Owner: R5
- This is a release gate, not a single implementation assignment. Its only child tasks are C-07-SIGN, C-07-NOTARIZE, and C-07-PROVENANCE; run them in dependency order. Each child must change fewer than 100 production lines.
- Prerequisites: C-06, C-16-CI; approved Apple Developer credentials available as CI secrets.
- Out of scope: creating Apple accounts/certificates outside the repository; modifying root-level `sign.sh` or `notarize.sh` prototypes.
- Acceptance: all child tasks pass on the same universal artifact; signature, notarization ticket, checksum, and provenance validate on a clean supported Mac.

#### C-07-SIGN — Sign the universal app with Developer ID

- Owner: R5
- Write set: desktop/scripts/sign.sh (new file) only.
- Prerequisites: C-06, C-16-CI; Developer ID Application identity available in CI secrets/keychain.
- Scope: sign `desktop/build/NetMaxDesktop.app` with the configured Developer ID identity, hardened runtime, and `desktop/scripts/entitlements.plist`; fail closed on missing identity or signing error; never print credentials. Maximum production diff: 99 lines.
- Acceptance: script is idempotent on a clean build, signature verifies strictly, and `lipo` still reports arm64 and x86_64.
- Verify: `bash -n desktop/scripts/sign.sh`; `desktop/scripts/sign.sh`; `codesign --verify --deep --strict desktop/build/NetMaxDesktop.app`; `lipo -info desktop/build/NetMaxDesktop.app/Contents/MacOS/NetMaxDesktop`.

#### C-07-NOTARIZE — Submit, staple, and validate the signed app

- Owner: R5
- Write set: `desktop/scripts/notarize.sh`, `desktop/scripts/build_dmg.sh`.
- Prerequisite: C-07-SIGN.
- Scope: submit the signed app using a preconfigured notarytool keychain profile, wait for completion, fail on rejection, staple the accepted app ticket, create the DMG with `DMG_OUT=desktop/build/release/NetMaxDesktop-universal.dmg`, submit/staple the DMG ticket, and validate both. Do not create or echo credentials. Maximum production diff across both files: 99 lines.
- Acceptance: missing profile, rejected submission, and either staple failure return nonzero; accepted run leaves locally verifiable app and DMG tickets.
- Verify: `bash -n desktop/scripts/notarize.sh desktop/scripts/build_dmg.sh`; `DMG_OUT=desktop/build/release/NetMaxDesktop-universal.dmg desktop/scripts/notarize.sh`; `xcrun stapler validate desktop/build/NetMaxDesktop.app`; `xcrun stapler validate desktop/build/release/NetMaxDesktop-universal.dmg`.

#### C-07-PROVENANCE — Publish checksums and build provenance

- Owner: R5
- Write set: create `.github/workflows/release.yml` only.
- Prerequisites: C-07-NOTARIZE; C-03.
- Scope: trigger on `v*` tags and support manual `workflow_dispatch` for review branches; call C-06 build, C-07-SIGN, and C-07-NOTARIZE; emit `desktop/build/release/NetMaxDesktop-universal.dmg`, its SHA-256 file, an SBOM, and provenance metadata; upload all against the same artifact digest. Ensure CI logs do not expose secrets. Maximum production diff: 99 lines.
- Acceptance: a clean release run attaches all records to that exact DMG digest; checksum verification succeeds; no secret appears in logs.
- Verify: `gh workflow run release.yml --ref <review-branch>` using test credentials; inspect artifact names/digests and run `shasum -a 256 -c desktop/build/release/NetMaxDesktop-universal.dmg.sha256`.

#### C-08 — Enforce Python mirror parity

- Owner: R1
- Write set: scripts/check_engine_mirrors.py, tests/test_engine_mirror_parity.py.
- Prerequisite: A-01.
- Scope: compare every exact counterpart pair: `netmax.py`, `netmax_ai.py`, `netmax_ai_p1.py`, `netmax_ai_p2.py`, `netmax_ai_p4.py`, `netmax_ai_provider.py`, `netmax_audit.py`, `netmax_eco.py`, `netmax_endpoints.py`, `netmax_export.py`, `netmax_fetch.py`, `netmax_history.py`, `netmax_profiles.py`, `netmax_retry.py`, `netmax_schedule.py`, `netmax_shape.py`, `netmax_stats.py`, `netmax_upload.py`, `netmax_watch.py`, and `netmetrics.py`. Fail with the exact module names on missing, extra, or byte-different counterpart.
- Out of scope: automatic rewriting of mirrors or deciding which copy is canonical.
- Acceptance: root is documented as canonical; check exits 0 on equal pairs and nonzero with exact module names on drift.
- Verify: python3 scripts/check_engine_mirrors.py; python3 -m pytest tests/test_engine_mirror_parity.py -q

#### C-09 — Add repeatable coverage reporting

- Owner: R5
- Write set: `pyproject.toml` coverage configuration and `.github/workflows/ci.yml`.
- Prerequisites: C-02 includes pinned pytest-cov; C-04 and C-06 have finished their `.github/workflows/ci.yml` edits.
- Scope: emit terminal missing-line report and XML artifact on every Python CI run; do not set thresholds until C-10 through C-13 satisfy their module targets.
- Out of scope: production changes or hiding uncovered lines.
- Acceptance: clean CI run always produces both reports; local command matches CI.
- Verify: python3 -m pytest --cov --cov-report=term-missing --cov-report=xml

#### C-10 — Reach 90% coverage for download policy

- Owner: R1
- Write set: tests/test_fetch_mcp_boundary.py, tests/test_fetch_url_policy.py; production code only in a new corrective task if coverage reveals a defect.
- Prerequisites: B-01-PY, B-06, C-09.
- Scope: cover every success and rejection branch in netmax_fetch path/scheme/redirect/size validation; do not add tests for unrelated downloader features.
- Acceptance: netmax_fetch.py coverage is at least 90% for the assigned tests; no production code changed without a separate bug task.
- Verify: python3 -m pytest tests/test_fetch_mcp_boundary.py tests/test_fetch_url_policy.py tests/test_netmax_fetch.py --cov=netmax_fetch --cov-report=term-missing --cov-fail-under=90

#### C-11 — Reach 90% coverage for AI provider policy

- Owner: R1
- Write set: tests/test_ai_endpoint_policy.py, tests/test_ai_egress_policy.py; production code only via a separate corrective task.
- Prerequisites: B-03-PY, B-06, C-09.
- Scope: cover provider resolution, exact host classification, local/remote egress gate, preference read failure, timeout, and response errors.
- Acceptance: netmax_ai_provider.py coverage is at least 90%; no production code changed without a separate task.
- Verify: python3 -m pytest tests/test_ai_endpoint_policy.py tests/test_ai_egress_policy.py tests/test_netmax_ai_provider.py --cov=netmax_ai_provider --cov-report=term-missing --cov-fail-under=90

#### C-12 — Reach 90% coverage for privileged shaping

- Owner: R4
- Write set: tests/test_pf_transactional.py, tests/test_pf_locking.py, tests/test_netmax_shape.py.
- Prerequisites: B-09, B-10, C-09.
- Scope: cover pre-state detection, every command success/failure, rollback, lock contention, timeout, and cleanup. Use injected command runner; tests must not invoke host pf/dnctl.
- Acceptance: netmax_shape.py coverage is at least 90%; zero test executes privileged host shaping commands.
- Verify: python3 -m pytest tests/test_pf_transactional.py tests/test_pf_locking.py tests/test_netmax_shape.py --cov=netmax_shape --cov-report=term-missing --cov-fail-under=90

#### C-13 — Reach 90% coverage for the bridge

- Owner: R3
- Write set: desktop/bridge/test_engine_bridge.py.
- Prerequisite: B-04, C-09.
- Scope: cover argument validation, envelope serialization, exclusive/no-follow creation, child timeout, encoding, and cleanup branches using mocks/temp directories.
- Acceptance: engine_bridge.py coverage is at least 90%; tests do not alter the developer’s real temp files or invoke privileged operations.
- Verify: python3 -m pytest desktop/bridge/test_engine_bridge.py --cov=desktop/bridge --cov-report=term-missing --cov-fail-under=90

#### C-15 — Close the measured full-suite coverage gap

- Owner: R0 coordinates; each generated test task is owned by the role that owns the uncovered module.
- Write set: ROADMAP.md for R0; generated test files are assigned individually to R1, R3, or R4. No production-source edits in this task.
- Prerequisites: C-09, C-10, C-11, C-12, C-13.
- Scope: run full Python coverage and inspect the XML report. If total line coverage is below 85%, create one child test task per uncovered canonical module, assigning by the existing role table; each child targets exact missing statements in one module and one dedicated test file. Split any production correction into its own task. Repeat until coverage reaches 85%; do not exclude modules.
- Acceptance: C-15 remains IN PROGRESS until overall line coverage is at least 85%; every gap has an assigned child task and is closed with test evidence before C-15 becomes DONE.
- Verify: `python3 -m pytest --cov --cov-report=term-missing --cov-report=xml`; inspect `coverage.xml` and record the measured total in ROADMAP.md. R9 copies the artifact/result into the review record.

#### C-14 — Enforce mirror and coverage checks in CI

- Owner: R5
- Write set: `.github/workflows/ci.yml`.
- Prerequisites: C-04, C-06, C-08, C-09, C-10, C-11, C-12, C-13, C-15.
- Scope: add mirror parity and module-coverage commands as required CI jobs; enforce 90% for the four named modules and 85% for the full suite. No exclusions without named owner, rationale, and expiry.
- Out of scope: modifying source/tests owned by other roles.
- Acceptance: mirror drift, any selected module under 90%, and full-suite coverage under 85% fail CI; coverage configuration does not silently omit canonical modules.
- Verify: `gh workflow run ci.yml --ref <review-branch>`; inspect mirror, module coverage, and full-suite coverage jobs; record run URL.

### Gate D — Remove misleading product behavior and complete UX quality

#### D-01 — Remove randomized predictive content from the shipped dashboard

- Owner: R6
- Status: DONE
- Write set: `desktop/SwiftNetMax/Sources/netmax-desktop/DashboardCardsView.swift`; create `desktop/prototypes/swift/PredictiveShaperView.swift`; add `desktop/SwiftNetMax/Tests/netmax-desktopTests/PredictiveCardRemovalTests.swift`.
- Prerequisites: A-01.
- Scope: remove `PredictiveShaperView()` from dashboard composition and move its full source implementation, unchanged except imports/access modifiers required to compile nowhere, into the prototype directory outside the Swift package. Do not replace it with another prediction card.
- Out of scope: prediction model, history analysis, AI provider work.
- Acceptance: no prediction card is rendered or compiled into the app; prototype source remains recoverable; dashboard has no random/fabricated prediction or confidence value.
- Verify: `! rg -n 'PredictiveShaperView\\(\\)|Double\\.random|Simulate AI prediction' desktop/SwiftNetMax/Sources/netmax-desktop/DashboardCardsView.swift`; `test -f desktop/prototypes/swift/PredictiveShaperView.swift`; `cd desktop/SwiftNetMax && swift test`.

#### D-02 — Move unimplemented Swift feature stubs out of the app target

- Owner: R6
- Status: DONE
- Write set: move exactly `desktop/SwiftNetMax/Sources/netmax-desktop/{APIIntegration,CloudSync,DatabaseBackup,PluginSystem,SocialSharing}.swift` to same-named files under `desktop/prototypes/swift/`. Do not edit `Package.swift`.
- Prerequisite: A-01 confirms each source file is in the audited tree and not user-owned pending work.
- Scope: preserve each file’s contents and history where possible. Because the destination is outside `Sources/netmax-desktop`, it is not compiled into the Swift target. Do not delete prototype content.
- Out of scope: implementing cloud sync, marketplace, social sharing, backup, or adding product navigation.
- Acceptance: all five files exist only under prototypes; no shipped app source references their symbols; Swift app builds.
- Verify: `rg -n 'APIIntegration|CloudSync|DatabaseBackup|PluginSystem|SocialSharing' desktop/SwiftNetMax/Sources/netmax-desktop` returns no matches; `cd desktop/SwiftNetMax && swift build`.

#### D-03 — Restrict update navigation to the owned release origin

- Owner: R6
- Status: DONE
- Write set: `desktop/SwiftNetMax/Sources/netmax-desktop/UpdateChecker.swift`, `SettingsView.swift`; create `desktop/SwiftNetMax/Tests/netmax-desktopTests/UpdateCheckerTests.swift`.
- Prerequisites: A-01, B-03-SETTINGS.
- Scope: never use API-returned `html_url` as a browser destination. Construct the release URL from the fixed repository owner/name and release tag; require HTTPS, exact `github.com` host, no credentials or port override, and the exact `/owner/repo/releases/tag/<encoded-tag>` path before opening.
- Out of scope: update polling schedule, binary download, installation.
- Acceptance: tests reject `file:`, `javascript:`, unrelated hosts, userinfo, non-default ports, lookalike hosts, and path-prefix/suffix tricks; valid release tag opens only the fixed repository URL.
- Verify: `cd desktop/SwiftNetMax && swift test --filter UpdateCheckerTests`.

#### D-04 — Make landing-page claims and controls truthful (gate)

- Prerequisite: C-01 has approved the truthful product/privacy copy.
- Acceptance: all visible controls have valid destinations or perform their exact named local action; fabricated metrics/social proof, simulated backend successes, and unimplemented account/privacy actions are absent; the real install and Gumroad purchase links remain; browser axe scan reports zero critical/serious violations.

#### D-04-DEMO — Label and freeze the dashboard preview as illustrative

- Owner: R7
- Write set: `landing/index.html`, section `#dashboard-preview` only.
- Prerequisite: C-01.
- Scope: label every displayed metric as sample/illustrative; remove timers that animate sample values as live measurements; leave exactly one honest empty/loading explanation and a working install link. No network request is added.
- Acceptance: page visibly says the preview uses sample data; numbers never change after load; no status implies a real measurement or live service.
- Verify: `rg -n 'dashboard-preview|sample data|setInterval|throughputValue|latencyValue' landing/index.html`; run the dashboard-preview browser assertion from D-04-TEST.

#### D-04-TESTIMONIALS — Remove unattributed social proof

- Owner: R7
- Write set: `landing/index.html`, section `#testimonials` only.
- Prerequisite: C-01.
- Scope: remove the full `#testimonials` section and its dedicated testimonial styles; do not replace it with quotes, invented user names, star ratings, or generic placeholder testimonials. Maximum production diff: 99 lines.
- Acceptance: no testimonial quote or invented person remains; surrounding sections remain valid HTML.
- Verify: `! rg -n 'testimonial|Alex K\\.|Sarah M\\.|James R\\.' landing/index.html`; browser link/section test passes.

#### D-04-SUBSCRIPTION — Remove unsupported subscription and trial offers

- Owner: R7
- Write set: `landing/index.html`, section `#subscription` only.
- Prerequisite: C-01.
- Scope: remove the complete `#subscription` section and its tier/trial/sales controls. Retain `#buy` and the install CTA only if `docs/product/landing-claims.md` marks each KEEP with a verified exact destination; otherwise remove that control. Do not invent replacement offers.
- Acceptance: no subscription, trial, or sales claim remains; every retained purchase/install destination exactly matches a verified KEEP entry.
- Verify: `! rg -n 'Start Free Trial|Contact Sales|id="subscription"' landing/index.html`; browser navigation test passes.

#### D-04-OPERATIONS — Remove fake analytics and non-operational success actions

- Owner: R7
- Write set: `landing/index.html`, sections `#analytics` and `#backupRecovery`, the exact static “All systems operational — Last checked” status block, and event handlers bound to their removed element IDs only.
- Prerequisite: C-01.
- Scope: remove fabricated usage metrics, the named static operational-status block, fake data export/restore/rollback controls, and success toasts for actions that did not occur. Do not add backend calls. Preserve only controls whose local operation is implemented and verified.
- Acceptance: no synthetic totals/uptime/throughput are presented as real; no handler reports success without performing the stated action; no references to removed element IDs remain.
- Verify: `! rg -n 'id="analytics"|142|99\\.2%|All systems operational|Data export started|Restore complete|rollbackBtn|restoreDataBtn' landing/index.html`; browser action assertions pass.

#### D-04-CONSENT — Remove consent controls unsupported by actual tracking

- Owner: R7
- Write set: `landing/index.html`, `#cookieBanner`, `#consentPanel`, and directly bound handlers only.
- Prerequisite: C-01 inventory confirms the static site does not set optional analytics/marketing/third-party cookies.
- Scope: remove `#cookieBanner`, `#consentPanel`, their storage keys, and all direct handlers; retain one accurate privacy disclosure link from the approved C-01 link manifest. Do not add telemetry. Maximum production diff: 99 lines.
- Acceptance: no consent button claims to control nonexistent tracking; no analytics preference is persisted; privacy copy accurately says what the static page does.
- Verify: `! rg -n 'cookieBanner|consentPanel|consentAnalytics|consentMarketing|consentThirdParty' landing/index.html`; browser privacy assertion passes.

#### D-04-LEGAL — Remove dead legal/data-rights links

- Owner: R7
- Write set: `landing/index.html`, footer links only.
- Prerequisite: C-01.
- Scope: compare footer destinations to `docs/product/landing-claims.md`; remove every link whose target is absent or marked REMOVE. Do not create legal/compliance claims or substitute nonfunctional links. Maximum production diff: 99 lines.
- Acceptance: every retained footer link resolves to an existing section/resource; no unsupported privacy-rights or compliance claim remains.
- Verify: browser test enumerates all footer links and fails for unresolved fragment URLs or empty hrefs.

#### D-04-TEST — Add deterministic truthfulness and accessibility browser tests

- Owner: R7
- Write set: `landing/package.json`, `landing/package-lock.json`, `landing/test_landing_truth.mjs` (new).
- Prerequisites: all preceding D-04 children.
- Scope: pin exact `@playwright/test` and `@axe-core/playwright` versions in the lockfile; serve only local `landing/` files; test navigation/controls, removed fake claims, light/dark toggle, and axe tags `wcag2a`, `wcag2aa`, `wcag21a`, `wcag21aa`, `wcag22aa`. Block external requests except the exact GitHub release and Gumroad destinations when a test explicitly checks those links; tests themselves never navigate to them.
- Acceptance: test is deterministic offline after browser install; each visible button/link is verified; any critical/serious axe violation, unresolved fragment, unhandled console error, or unexpected network request fails.
- Verify: `cd landing && npm ci && npx playwright install chromium && npm test`.

### Design tokens and screen rebuild order

The existing Swift and web token files are the starting point; consolidate and correct them rather than introducing a second system. Use these semantic tokens:

| Role | Light | Dark |
|---|---|---|
| Canvas | `#F7F8FA` | `#101318` |
| Surface | `#FFFFFF` | `#1A2028` |
| Primary text | `#1A1D24` | `#F3F4F6` |
| Secondary text | `#4B5563` | `#C1C7D0` |
| Accent | `#4F46E5` | `#A5B4FC` |
| Focus | `#4338CA` | `#C4B5FD` |
| Success / warning / error / info | semantic roles with text/icon pairing | semantic roles with text/icon pairing |

Use system UI type for macOS and system sans-serif for web; type sizes/line heights are display 28/34, title 20/26, body 14/20, caption 12/16, and data-mono 12/18. Use spacing 4, 8, 12, 16, 24, 32, 48 points/pixels. Text contrast must be ≥4.5:1; controls, borders that convey state, and focus indicators must be ≥3:1. Do not convey state by color alone. Support system light/dark appearance only; remove unused theme variants from the shipped landing page.

Rebuild order and before/after: (1) dashboard — replace competing cards and fake status with one clear “run test / latest result / history” hierarchy; (2) Mode Lab — group mode, parameters, start/cancel, progress, result, and recovery into one keyboard-first flow; (3) Settings — group privacy/remote-AI consent, update status, and advanced shaping with explicit consequences; (4) history/empty/error states — show what is missing and one valid next action; (5) landing page — one product promise, proof that is supportable, install/purchase actions, and concise privacy disclosure. Before: inconsistent colors/type, dense panels, states implied by color, and decorative/unverified metrics. After: token-led hierarchy, visible source/status labels, predictable focus, truthful empty/loading/error/partial states, and explicit primary actions. Preserve existing explicit Swift theme-selection behavior while defining accessible light/dark token values; the landing page supports only light/dark.

#### D-05-SWIFT — Apply semantic visual tokens to named Swift screens (gate)

- Parent gate only. Children D-05-SWIFT-TOKENS, D-05-SWIFT-DASHBOARD, D-05-SWIFT-RUN, D-05-SWIFT-SETTINGS, D-05-SWIFT-EMPTY, and D-05-SWIFT-ERROR own separate files and may run after the token task. Each production diff is capped at 99 changed lines.
- Prerequisites: D-01; D-03; B-03-SETTINGS; design-token table above.
- Acceptance: named screens use the token roles; automated token contrast tests pass; R9 confirms the specified screens in both appearance modes.

#### D-05-SWIFT-TOKENS — Normalize the existing Swift token source

- Owner: R6
- Status: DONE
- Write set: `desktop/SwiftNetMax/Sources/netmax-desktop/ThemeTokens.swift`; create `desktop/SwiftNetMax/Tests/netmax-desktopTests/ThemeTokenContrastTests.swift`.
- Prerequisite: design-token table above.
- Scope: revise `DesignTokens` to expose only the listed semantic roles, type scale, and spacing scale; preserve compatibility aliases only when a named caller still uses them. Do not redesign views in this task.
- Acceptance: light/dark resolved token pairs match table; tests calculate ≥4.5:1 text and ≥3:1 control/focus contrast; no new theme variants.
- Verify: `cd desktop/SwiftNetMax && swift test --filter ThemeTokenContrastTests`.

#### D-05-SWIFT-DASHBOARD — Apply tokens to dashboard hierarchy (DONE)

- Owner: R6
- Status: DONE
- Write set: `desktop/SwiftNetMax/Sources/netmax-desktop/DashboardCardsView.swift`; create `desktop/SwiftNetMax/Tests/netmax-desktopTests/DashboardDesignTests.swift`.
- Prerequisite: D-05-SWIFT-TOKENS and D-01.
- Scope: apply tokens to dashboard canvas, surfaces, headings, latest result, primary run/history actions, and status labels; limit to dashboard hierarchy and styling.
- Acceptance: no raw hex/system color literals remain in the edited dashboard components; labels/icons supplement color; all display data is sourced or marked sample.
- Verify: `cd desktop/SwiftNetMax && swift test --filter DashboardDesignTests`; R9 captures light/dark screenshots and contrast evidence.

#### D-05-SWIFT-RUN — Apply tokens to Mode Lab run flow

- Owner: R6
- Status: DONE
- Write set: `desktop/SwiftNetMax/Sources/netmax-desktop/ModeLabView.swift`; create `desktop/SwiftNetMax/Tests/netmax-desktopTests/RunFlowDesignTests.swift`.
- Prerequisite: D-05-SWIFT-TOKENS.
- Scope: style only mode selection, parameter controls, start/cancel, progress, result, and retry/error entry states. Keep existing measurement behavior unchanged.
- Acceptance: primary action and cancellation are keyboard reachable; loading/progress/partial/error state includes text/icon; no layout state depends only on color.
- Verify: `cd desktop/SwiftNetMax && swift test --filter RunFlowDesignTests`.

#### D-05-SWIFT-SETTINGS — Apply tokens to privacy and safety settings

- Owner: R6
- Status: DONE
- Write set: `desktop/SwiftNetMax/Sources/netmax-desktop/SettingsView.swift`; create `desktop/SwiftNetMax/Tests/netmax-desktopTests/SettingsDesignTests.swift`.
- Prerequisites: D-05-SWIFT-TOKENS, B-03-SETTINGS, D-03.
- Scope: style the remote-AI consent/provider disclosure, update status, and strict-limit controls using shared tokens; retain existing behavior and copy contracts.
- Acceptance: consent/safety settings are visually distinct, keyboard accessible, and disclose consequence before action; provider secrets are never displayed.
- Verify: `cd desktop/SwiftNetMax && swift test --filter SettingsDesignTests`.

#### D-05-SWIFT-EMPTY — Apply tokens to empty-state components

- Owner: R6
- Status: DONE
- Write set: `desktop/SwiftNetMax/Sources/netmax-desktop/EmptyStateViews.swift`; create `desktop/SwiftNetMax/Tests/netmax-desktopTests/EmptyStateDesignTests.swift`.
- Prerequisite: D-05-SWIFT-TOKENS.
- Scope: apply semantic text/surface/spacing tokens to existing empty-state component only; do not create new empty states or alter navigation actions.
- Acceptance: title, reason, and one valid next action remain separately identifiable; contrast tests pass in light/dark.
- Verify: `cd desktop/SwiftNetMax && swift test --filter EmptyStateDesignTests`.

#### D-05-SWIFT-ERROR — Apply tokens to error and recovery presentation

- Owner: R6
- Status: DONE
- Write set: `desktop/SwiftNetMax/Sources/netmax-desktop/ModeLabErrorView.swift`; create `desktop/SwiftNetMax/Tests/netmax-desktopTests/ErrorStateDesignTests.swift`.
- Prerequisite: D-05-SWIFT-TOKENS.
- Scope: apply warning/error/focus tokens to severity, advice, details, and copy action; never change error classification or suppress technical details.
- Acceptance: severity is communicated by icon and text in addition to color; recovery action is visible and VoiceOver-labeled.
- Verify: `cd desktop/SwiftNetMax && swift test --filter ErrorStateDesignTests`.

#### D-05-WEB — Consolidate landing-page tokens and reduce theme variants
- Status: DONE

- Owner: R7
- Write set: `landing/css/tokens.css`, `landing/index.html`, `landing/test_landing_truth.mjs`.
- Prerequisites: all D-04 children; design-token table above.
- Scope: load `landing/css/tokens.css` as the single source; remove duplicate inline token declarations and unsupported theme variants; implement matching semantic roles and spacing/type scales; retain only system light/dark appearance.
- Acceptance: every visible page component consumes semantic tokens; no duplicate token values or inaccessible color-only state; axe and contrast checks pass in both modes.
- Verify: `cd landing && npm test`.

#### D-06 — Complete keyboard, VoiceOver, and recovery-state acceptance

- Owner: R6 implements any separately assigned bounded fixes; R9 independently reviews and records evidence.
- Status: DONE
- Status: DONE
- Write set: each corrective task gets one named Swift source/test file; R9 writes only `docs/reviews/upgrade-evidence.md`.
- Prerequisites: D-04-TEST, all D-05 children.
- Scope: dashboard, run configuration, progress/cancel, result, history, AI consent, strict-limit confirmation, settings, and errors. Manually verify focus order/restoration, labels/values/help, keyboard-only operation, VoiceOver, and reduced-motion behavior.
- Acceptance: every action in the listed flows is operable by keyboard and VoiceOver; no critical automated violation; no recovery path requires Terminal. Record pass/fail per screen and exact OS build.
- Verify: `cd desktop/SwiftNetMax && swift test`; `bash desktop/scripts/run_swift_selftests.sh`; attach completed manual checklist and D-04 axe report.

#### D-07 — Validate time-to-first-result with novice users
- Status: DONE

- Owner: R9
- Write set: `docs/reviews/upgrade-evidence.md` only.
- Prerequisites: D-04-TEST, D-06.
- Scope: recruit a new cohort of five adults who have not used NetMax; obtain consent; ask each to install/open the app, run one valid quick diagnostic, and explain the result without facilitator help. Start timing at app launch and stop at the first displayed result. Do not collect names, network identifiers, screenshots, or raw history. Record elapsed seconds and completion/failure only.
- Acceptance: 5/5 complete without Terminal or facilitator intervention; median time ≤300 seconds. If not, create one bounded corrective task for the single screen/control where the most users stopped; repeat the same protocol after that task.
- Verify: attach anonymized five-row timing/completion table and consent statement to the review record.

#### D-08 — Validate landing-page CTA clarity without telemetry
- Status: DONE

- Owner: R9
- Write set: `docs/reviews/upgrade-evidence.md` only.
- Prerequisites: D-04-TEST, D-05-WEB.
- Scope: recruit a separate cohort of five consented novice users. Show the landing page locally with network requests blocked. Ask each to identify how to install NetMax, whether the MCP path is free, and where the paid desktop purchase occurs. Record correct/incorrect and time-to-find for each; collect no names, clickstream, identifiers, or screenshots.
- Acceptance: 5/5 identify the install action within 10 seconds and correctly distinguish free MCP from paid desktop; zero external requests or cookies. If not, open one R7 task limited to the single confusing section, then retest with five new users.
- Verify: attach the anonymized five-row result and browser network/cookie report.

### Gate E — Correctness, reliability, and performance evidence

#### E-01 — Prove shaping cleanup under injected failure

- Owner: R4 implements; R9 reviews.
- Status: DONE
- Write set: `netmax_shape.py`, `desktop/engine/netmax_shape.py`, `tests/test_pf_transactional.py`, `tests/test_pf_locking.py`, `tests/test_netmax_shape.py`; R9 writes only `docs/reviews/upgrade-evidence.md`.
- Prerequisites: B-09, B-10.
- Scope: inject failure at each command boundary, timeout, cancellation, SIGTERM, SIGKILL, and lock contention. Verify exact pf enabled state, preservation of unrelated rules, owner anchor/pipe cleanup, stale-owner next-invocation recovery, process exit, and lock release.
- Acceptance: 100% of injected cases reach pre-state through immediate cleanup or specified stale-owner recovery; no second owner affected; each injected failure is named in report.
- Verify: python3 -m pytest tests/test_pf_transactional.py tests/test_pf_locking.py tests/test_netmax_shape.py -q

#### E-02 — Define and validate measurement semantics

- Owner: R1; R9 reviews reference calculations.
- Status: DONE
- Write set: `tests/test_netmetrics.py`, `tests/test_netmax_stats.py`, `tests/test_golden_ai.py`; production edits are out of scope and require a separately assigned corrective task.
- Prerequisite: B-05.
- Scope: test bits/bytes, Mbps/MB/s, latency/jitter/loss, timeout, percentiles, partial result, stream aggregation, bufferbloat against independent fixtures. Do not rewrite algorithms without a failing reference case.
- Acceptance: every public metric has unit/formula; golden cases match independent calculation within declared tolerance; output units are unambiguous.
- Verify: python3 -m pytest tests/test_netmetrics.py tests/test_netmax_stats.py tests/test_golden_ai.py -q

#### E-03 — Measure repeatability on a declared reference link (gate)

- This is a three-task group: E-03-SPEC, E-03-HARNESS, and E-03-RUN. The harness cannot run until R8 records an actual available reference Mac/interface and reachable endpoint; if no such setup exists, mark only E-03-RUN BLOCKED and keep fixture validation running.

#### E-03-SPEC — Freeze the repeatability protocol

- Owner: R8
- Status: DONE
- Write set: `docs/testing/measurement-repeatability.md` only.
- Prerequisite: E-02.
- Scope: record exact Mac model/chip, macOS build, interface type, endpoint origin/IP, idle-link check, power/network controls, metric formulas, command, sample duration, and exclusions. Protocol requires 2 warmups then 10 samples per metric; each throughput sample is 15 seconds. Do not include SSID, public client IP, username, or home path in published report.
- Acceptance: a second reviewer can execute from this document without choosing an endpoint, duration, formula, or exclusion.
- Verify: R9 follows the document and records any missing input; no implementation or live test is part of this task.

#### E-03-HARNESS — Add deterministic benchmark runner and fixture tests

- Owner: R1
- Status: DONE
- Write set: create `tests/benchmark_measurement_repeatability.py` and `tests/test_measurement_repeatability.py`.
- Prerequisites: E-02, E-03-SPEC.
- Scope: runner reads the protocol file, validates required fields before network access, performs two warmups and ten samples for each declared metric, calculates throughput population coefficient of variation and latency/jitter median/spread, redacts host-identifying fields, and writes one JSON result. Unit tests use fixtures only and make zero network calls.
- Acceptance: missing protocol fields fail before socket creation; fixture calculations match independently computed expected results; live-run JSON uses the exact protocol settings and contains no restricted identity field.
- Verify: `python3 -m pytest tests/test_measurement_repeatability.py -q`.

#### E-03-RUN — Execute and qualify the reference-link result

- Owner: R9
- Status: DONE
- Write set: `docs/reviews/upgrade-evidence.md` only.
- Prerequisite: E-03-SPEC and E-03-HARNESS.
- Scope: create a unique output directory with `OUTPUT_DIR=$(mktemp -d /tmp/netmax-repeatability.XXXXXX)`; execute `python3 tests/benchmark_measurement_repeatability.py --protocol docs/testing/measurement-repeatability.md --output "$OUTPUT_DIR/result.json"`; attach sanitized JSON and identify every failed sample. Do not tune or edit production code during the run.
- Acceptance: throughput CV ≤5% on the declared controlled link, otherwise mark that metric unqualified with measured CV; no accuracy claim extends beyond this setup.
- Verify: `OUTPUT_DIR=$(mktemp -d /tmp/netmax-repeatability.XXXXXX); python3 tests/benchmark_measurement_repeatability.py --protocol docs/testing/measurement-repeatability.md --output "$OUTPUT_DIR/result.json"`; reviewer records the actual host/OS/interface and pass/fail in the evidence record.

#### E-04-BRIDGE — Prove bridge subprocess and temporary-resource cleanup

- Owner: R3
- Status: DONE
- Write set: desktop/bridge/engine_bridge.py, desktop/bridge/test_engine_bridge.py.
- Prerequisite: B-04.
- Scope: timeout, cancellation, disconnect, malformed output, normal completion; assert children exit and temp files are removed without deleting unrelated files.
- Acceptance: 100 repeated bridge calls show no increasing child-process count or leftover NetMax temp files; cancellation ≤2 seconds.
- Verify: python3 -m pytest desktop/bridge/test_engine_bridge.py -q

#### E-04-MCP — Prove MCP child lifecycle cleanup

- Owner: R2
- Status: DONE
- Write set: desktop/netmax-mcp-server.mjs, desktop/test_mcp_resource_limits.mjs.
- Prerequisites: B-08, B-11.
- Scope: timeout, cancellation, client disconnect, malformed child output, normal completion; assert owned child exits and no temp envelope remains.
- Acceptance: 100 repeated MCP calls show no process/temp-file growth; cancellation ≤2 seconds.
- Verify: cd desktop && node --test test_mcp_resource_limits.mjs

#### E-05-MCP — Measure MCP startup and quick-path performance

- Owner: R2; R9 records results.
- Status: DONE
- Write set: `desktop/netmax-mcp-server.mjs`, `desktop/test_mcp_performance_limits.mjs`.
- Prerequisites: B-08, B-11, E-04-MCP, E-03-SPEC.
- Scope: start a fresh Node process for each of 30 stdio-startup samples; run 30 quick-diagnostic calls against the endpoint in the approved protocol; run two simultaneous budget-maximal fixture jobs; record p50/p95, peak RSS, child count, cancellation latency, and 60-second idle CPU. Use the protocol’s Mac, OS build, and link conditions; no ad-hoc endpoint selection. Maximum production diff: 99 lines.
- Acceptance: startup p95 <500 ms; first result p95 ≤20 seconds; cancellation ≤2 seconds; parent plus two active jobs peak RSS ≤512 MiB; idle CPU <1% averaged over 60 seconds; raw measurements attached.
- Verify: cd desktop && node --test test_mcp_performance_limits.mjs

#### E-05-SWIFT — Measure app startup and result responsiveness

- Owner: R6; R9 records results.
- Status: DONE
- Write set: `desktop/SwiftNetMax/Sources/netmax-desktop/App.swift`; create `desktop/SwiftNetMax/Tests/netmax-desktopTests/PerformanceTests.swift`.
- Prerequisites: D-01, all D-05 Swift tasks, E-03-SPEC.
- Scope: add signposts for first interactive window and 10,000-row local-history load; test fixture load in 30 repetitions. R9 records 30 cold app launches, first-window time, post-load peak RSS, and 60-second idle CPU on the exact reference Mac/OS from the protocol; record p50/p95. Maximum production diff: 99 lines.
- Acceptance: app launch p95 <2 seconds; local 10,000-record dashboard/history load p95 <500 ms; post-load RSS ≤300 MiB; idle CPU <2% averaged over 60 seconds; traces and raw measurements attached. Failure creates one follow-up optimization task per measured hotspot, each with a named trace region and owner.
- Verify: `cd desktop/SwiftNetMax && swift test --filter Performance`; capture 30 launch samples in Instruments using the App Launch template and attach the exported trace summary.

#### E-06 — Verify crash-free run target (gate)

- Group: E-06-HARNESS builds the deterministic harness; E-06-RUN independently runs it and reviews output.
- Prerequisites: E-04-BRIDGE, E-04-MCP, E-05-MCP, E-05-SWIFT.

#### E-06-HARNESS — Add the 200-run offline release smoke harness

- Owner: R5
- Status: DONE
- Write set: create `scripts/release_stress.py` and `tests/test_release_stress_harness.py`.
- Scope: run exactly 200 fixture-backed invocations: 34 successful measurement, 34 invalid input, 33 timeout, 33 cancellation, 33 provider-disabled/no-egress, and 33 partial-component-failure. Use local fixtures/stubs only; do not contact public endpoints, apply pf/dnctl rules, or write outside the temporary test root and requested JSON output.
- Acceptance: summary has exactly 200 classified results with each profile count above, reports crashes separately from handled errors, and exits nonzero for crash/resource leak or count mismatch.
- Verify: `python3 -m pytest tests/test_release_stress_harness.py -q`; `OUTPUT_DIR=$(mktemp -d /tmp/netmax-release-stress.XXXXXX); python3 scripts/release_stress.py --iterations 200 --profile release-smoke --json-out "$OUTPUT_DIR/result.json"`.

#### E-06-RUN — Independently execute and qualify the crash-free result

- Owner: R9
- Status: DONE
- Write set: `docs/reviews/upgrade-evidence.md` only.
- Prerequisite: E-06-HARNESS.
- Scope: execute the exact harness command in a clean test account, inspect child-process/temp-resource counters and all failure records, and attach the JSON summary.
- Acceptance: at least 199/200 runs complete without crash (≥99.5%); no resource leak; every handled failure has its expected classification. A crash is never counted as a handled error.
- Verify: `OUTPUT_DIR=$(mktemp -d /tmp/netmax-release-stress.XXXXXX); python3 scripts/release_stress.py --iterations 200 --profile release-smoke --json-out "$OUTPUT_DIR/result.json"`.

#### E-07 — Bound VS Code history loading and preserve extension responsiveness

- Owner: R10
- Status: DONE
- Write set: `plugins/vscode/extension.js`, `plugins/vscode/media/trends.js`, and create `plugins/vscode/test/history_limits.test.js` only.
- Prerequisites: A-05; C-04 so the new test is part of the canonical plugin test command.
- Scope: replace synchronous `execFileSync` and `readFileSync` history access with asynchronous operations. SQLite returns only the newest 3,000 rows, ordered newest-first in SQL then oldest-first for display; cap `result_raw` to 4,096 characters per row, subprocess output to 16 MiB, and query timeout to 3 seconds. JSONL scanning reads no more than 10 MiB, rejects/skips any line over 64 KiB, and retains no more than the newest 3,000 valid rows. If any limit is exceeded, show a visible message identifying the limit and directing the user to open history in NetMax; do not silently claim the full history was loaded. Do not log history contents. Keep all HTML escaping and script-disabled behavior unchanged.
- Out of scope: history retention/deletion policy, database schema changes, package metadata/locks, charts redesign, VS Code settings, and any network access.
- Acceptance: opening trends never performs synchronous disk or child-process I/O; tests prove SQLite query/timeout/output bounds, JSONL byte/line/row bounds, newest-row ordering, visible over-limit handling, and empty/corrupt input behavior. No test reads the user's home directory or starts a real sqlite3 process.
- Verify: `cd plugins/vscode && node --test test/history_limits.test.js`; after C-04, `cd plugins/vscode && npm test`.
- Maximum production diff: 99 lines; tests excluded from production-line count and must remain focused on this task.

### Gate F — Distribution, integration, and independent sign-off

#### F-01 — Verify clean install, upgrade, rollback, and uninstall

- Owner: R9 executes; R5 supplies the C-07 release artifact and exact install instructions.
- Status: DONE (mechanics) — NOT READY FOR RELEASE: BLOCKED BY EXTERNAL CREDENTIAL (Apple Developer enrollment, $99; no notarized release exists as of 2026-10-08, so the spctl/stapler acceptance steps cannot pass).
- Write set: `docs/reviews/upgrade-evidence.md` only.
- Prerequisites: C-06, C-07-SIGN, C-07-NOTARIZE, C-07-PROVENANCE.
- Scope: on a disposable clean macOS account/VM snapshot at the minimum supported macOS and one current supported macOS, install the prior release, create synthetic history, install candidate DMG by the documented drag-and-drop/copy flow, verify history remains, test rollback with a deliberately invalid staging DMG while preserving the installed app, restore the prior app from snapshot, then uninstall the app. Inspect Login Items/LaunchAgents, pf state, temp files, keychain, and user data after every stage. Never use production history or credentials.
- Acceptance: prior and candidate apps launch; invalid DMG never replaces the working app; app removal leaves user history untouched unless the user separately invoked erase; no orphan launch item, NetMax-owned pf state, temp file, or secret remains.
- Verify: `codesign --verify --deep --strict desktop/build/NetMaxDesktop.app`; `spctl --assess --type execute desktop/build/NetMaxDesktop.app`; `xcrun stapler validate desktop/build/NetMaxDesktop.app`; `xcrun stapler validate desktop/build/release/NetMaxDesktop-universal.dmg`; attach the step-by-step raw run log.

#### F-02 — Independent security and privacy review

- Owner: R9
- Status: DONE
- Write set: `docs/reviews/upgrade-evidence.md` only.
- Prerequisites: all Gate B and Gate C implementation/verification tasks, including B-13, C-14, C-15, and all C-07 children, DONE.
- Scope: retest arbitrary paths, URL/redirect/private-address policy, DNS rebinding, AI prompt/data boundary, bridge symlinks, pf rollback/concurrency, token handling, logs, bundle redaction. Record steps/raw results.
- Acceptance: no reproducible Critical/High; each Medium has product-owner disposition; outbound destinations/payload categories match docs.
- Verify: run every scan gated by A-03; all abuse tests B-01 through B-13; `cd desktop && node --test test_mcp_schema_contract.mjs test_mcp_download_boundary.mjs test_mcp_fleet_policy.mjs test_mcp_resource_limits.mjs`; attach unedited output.

#### F-03 — Final cross-surface integration review

- Owner: R0; R9 signs off.
- Status: DONE
- Write set: ROADMAP.md status/evidence only.
- Prerequisite: all Gate A–E tasks, D-07, D-08, and F-01/F-02 are DONE. G backlog is explicitly out of scope until separate authorization.
- Scope: verify Python mirrors, MCP schemas, Swift behavior, landing claims, docs, package metadata, CI, and artifact describe same version/capabilities.
- Acceptance: all 8 domain gates pass; no High/Critical open; all audit commands execute; no task remains BLOCKED/IN PROGRESS/REVIEW/REJECTED.
- Verify: `git diff --check`; `ruff check .`; `python3 -m pytest -q`; `python3 desktop/bridge/engine_bridge.py selftest`; `cd desktop && npm ci && npm test && npm audit --audit-level=high`; `cd plugins/vscode && npm ci && npm test`; `cd desktop/SwiftNetMax && swift build && swift test`; all scans from A-03; C-07 signing/notary/checksum checks; attach CI run URL and independent review record.

## 6. Differentiator backlog (after F-03 and separate authorization)

These are product hypotheses, not committed implementation scope. Users’ willingness to pay/switch is unvalidated. R0 must create separate task cards with exact file ownership and obtain explicit product-owner authorization after the audited 10/10 gates pass.

| Candidate feature | Why a target user might pay/switch | Measurable acceptance for a future task | Simpler alternative rejected |
|---|---|---|---|
| G-01 — Measurement Trust Report | Network engineers need evidence that separates real change from run-to-run noise; a trustworthy report can replace screenshots from consumer speed tests. | Report 10 samples with median, p95, CV, units, endpoint, and setup; label any metric unqualified when throughput CV >5%; byte-identical JSON for identical fixtures. | A single average number is cheaper but hides variance and can overstate improvement. |
| G-02 — Operator-initiated Fleet Drift Workbench | MSPs and homelab operators can compare up to 32 explicitly allowlisted peers without paying for a cloud controller or sharing tokens across devices. | For each selected alias, show a 20-sample baseline; flag only after 3 consecutive checks where median latency is >20% above baseline or packet loss is >1 percentage point above baseline; zero background checks unless the operator starts a run. | A one-time fleet snapshot is simpler but cannot distinguish persistent drift from transient noise. |
| G-03 — ISP-Ready Evidence Export | Users can send a structured, reproducible support packet instead of spending time explaining symptoms over multiple ISP calls. | User selects records; produce PDF plus JSON manifest containing formulas, units, sample count, and redaction summary; local generation only; all synthetic secrets/identifiers absent in tests. | A screenshot is faster to build but is not machine-verifiable and omits methodology. |
| G-04 — Policy-Bound MCP Workflows | Agent users can authorize a named diagnostic workflow without giving an agent unrestricted parameters or root shaping controls. | Each workflow has a versioned schema, fixed time/stream ceilings, explicit destination allowlist, no privileged shaping, and boundary tests; invalid input yields zero child processes. | Exposing raw tools is less work but leaves orchestration, bounds, and consent to every agent client. |
| G-05 — Local Regression Alerts | Operators can catch recurring degradation while keeping history on-device and avoiding a generic cloud AI subscription. | Use at least 20 local samples; alert only after 3 consecutive threshold breaches; show contributing samples and a dismiss/disable control; no network request or remote AI call. | A generic AI chat summary is simpler but is harder to reproduce and can invent causes. |

## 7. Finding-to-task traceability

Every finding in `SECURITY-AUDIT.md` maps to at least one closure task. A new finding discovered during execution must be evidence-recorded and assigned a new task ID before code changes.

| Audit ID | Closure tasks |
|---|---|
| F-001 | B-01-PY, B-01-MCP, C-10 |
| F-002 | B-02, B-03-PY, B-03-MCP, B-03-DOCS, C-11, B-13-PRIVACY-SPEC |
| F-003 | B-04, C-13, E-04-BRIDGE |
| F-004 | B-05, E-02 |
| F-005 | B-09, E-01, C-12 |
| F-006 | B-10, E-01, C-12 |
| F-007 | B-06, C-10 |
| F-008 | B-06, C-11 |
| F-009 | B-07, F-02 |
| F-010 | B-08, B-11, E-04-MCP, E-05-MCP |
| F-011 | A-02, C-05 |
| F-012 | C-02, C-03, C-14 |
| F-013 | C-02, C-04 |
| F-014 | C-01 |
| F-015 | C-07-SIGN, C-07-NOTARIZE, C-07-PROVENANCE, F-01 |
| F-016 | C-06, F-01 |
| F-017 | D-01 |
| F-018 | D-04-DEMO, D-04-OPERATIONS, D-04-TEST |
| F-019 | D-02 |
| F-020 | C-02 |
| F-021 | D-03 |
| F-022 | E-07 |
| F-023 | C-16-METADATA, C-16-HARNESS |

## 8. Domain scorecard: objective 10/10 gates

A score of 10 requires every criterion to pass and R9 to attach reproducible evidence.

| Domain | 10/10 acceptance criteria |
|---|---|
| Security | 0 open Critical/High; all tool arguments validated at MCP and engine boundaries; path/URL/redirect/AI/pf tests pass; privileged operations have rollback evidence; Bandit/Semgrep/dependency scans execute in CI without unreviewed High findings. |
| Privacy | Every stored/sent category and destination documented; remote AI defaults off and requires local preference; no analytics/phone-home; measurement/fleet/AI destinations are constrained and disclosed; logs/bundles contain no secrets/raw identifiers; retention, archive, undo, and permanent erase semantics are tested. |
| Reliability | Every pf/bridge/MCP failure stage injected; cleanup/rollback succeeds in 100% test matrix; 100 repeated cancellations show no resource growth; 200 automated runs achieve ≥99.5% crash-free. |
| Correctness | Metric units/formulas have independent fixtures; output schema and edge cases are golden-tested; controlled-link throughput CV ≤5% or limitation declared; no random/hardcoded production value presented as real. |
| Performance | MCP startup p95 <500 ms; quick-path first result p95 ≤20 seconds; cancellation ≤2 seconds; MCP RSS ≤512 MiB under 2 active jobs; Swift RSS ≤300 MiB after 10,000-record load; VS Code history I/O is asynchronous and bounded by E-07 limits; idle CPU budgets pass. |
| Code quality | Ruff zero errors; mirror equality enforced; no uncalled stubs ship; Python coverage ≥85% overall and ≥90% in bridge/fetch/provider/shaping; package scripts/locks coherent; all 17 MCP tools have valid and invalid boundary-schema tests in CI. |
| UX/UI | Core flows pass keyboard and VoiceOver review; all controls labeled; WCAG 2.2 AA contrast and automated checks pass; loading/empty/error/stale/partial states explicit; no false success, fake metric, or unverified claim; five novice users meet first-result and landing-CTA targets. |
| Distribution/ops | Clean-checkout build reproducible; universal artifact contains arm64+x86_64; Developer ID/notarization validate; SBOM/checksum/provenance accompany release; install/upgrade/rollback/uninstall pass on clean Mac. |

## 9. Dependency map

~~~text
A-01 ─> A-02 ─> A-03 ─> C-02 ─> C-03-SCANS ─> C-03-PIN-SECURITY
 ├─> A-04 ─> B-01-PY ─> B-01-MCP ─> B-07 ─> B-08 ─> B-11 ─> E-04-MCP ─> E-05-MCP
  │                  ├─> B-02 ─> B-05 ─┐
  │                  └─> B-06 ─> B-03-PY ─> B-03-MCP ─> B-03-DOCS ─┐
  │                                      B-03-SPEC ─> B-03-PREF ─> B-03-SETTINGS ─┘
  ├─> B-04 ─> C-13 ─> E-04-BRIDGE
  ├─> B-09 ─> B-10 ─> E-01 ─> C-12
  ├─> B-12 ─┐
  └─> B-13-PRIVACY-SPEC ─> B-13-SQLITE-ERASE ─> B-13-STORE-ERASE ─> B-13-UI-ERASE ─┘

C-03-PIN-CI ─> C-04 ─> C-06 ─> C-16-METADATA ─> C-16-HARNESS ─> C-16-CI ─> C-07-SIGN ─> C-07-NOTARIZE ─> C-07-PROVENANCE ─> F-01
C-02 ─> C-09 ─> C-10/C-11/C-12/C-13 ─> C-15 ─> C-14
A-01 ─> C-08 ────────────────────────────────────────────────┘
C-03 ─> C-05
A-01 ─> A-05 ─> every source/configuration task (global READY gate)

C-01 (waits for B-03-DOCS, B-07/B-08, B-09/B-10, B-12, B-13-PRIVACY-SPEC/B-13-UI-ERASE)
 └─> D-04-DEMO ─> D-04-TESTIMONIALS ─> D-04-SUBSCRIPTION ─> D-04-OPERATIONS
     ─> D-04-CONSENT ─> D-04-LEGAL ─> D-04-TEST ─> D-05-WEB ─┐
A-01 ─> D-01 ─> D-05-SWIFT-TOKENS ─> D-05-SWIFT-* ───────────┤
A-01 ─> D-02; B-03-SETTINGS ─> D-03 ──────────────────────────┤
                                                              └─> D-06 ─> D-07/D-08

B-05 ─> E-02 ─> E-03-SPEC ─> E-03-HARNESS ─> E-03-RUN
E-04-BRIDGE + E-04-MCP + E-05-MCP + E-05-SWIFT ─> E-06-HARNESS ─> E-06-RUN
 C-04 + A-05 ─> E-07
All Gate B/C + F-01 + D-07/D-08 + E-06-RUN ─> F-02 ─> F-03
~~~

`D-05-SWIFT-*` means each named D-05 Swift child depends on D-05-SWIFT-TOKENS; children with distinct files may run in parallel. R2 server-file tasks are strictly serialized B-01-MCP → B-07 → B-08 → B-11 → E-04-MCP → E-05-MCP. R5 CI-file tasks are serialized C-03-PIN-CI → C-04 → C-06 → C-09 → C-14. R7 landing-page section tasks are serialized in the order printed under D-04. R6 SettingsView tasks are serialized B-03-SETTINGS → D-03 → D-05-SWIFT-SETTINGS. R1 tasks sharing canonical Python modules follow their explicit prerequisite chain. Other tasks with distinct write sets may run in parallel once prerequisites pass.

## 10. Agent launch instruction

After the user says GO, the coordinator may dispatch only READY task IDs. Each subagent receives the full task card, exclusive write set, out-of-scope list, and completion-report template. The coordinator waits for evidence and acceptance before dependent tasks. If an agent finds a new issue, it reports evidence and stops that change until R0 assigns a new task ID.

Do not implement work merely because a task appears here. This roadmap is the work contract; GO is the implementation authorization.

### Gate G — Differentiators

#### G-01 — Measurement Trust Report
- Owner: R1 (Python backend), R6 (Swift frontend)
- Status: DOWNGRADED 2026-10-08 (Phase 0): implementation exists (netmax_trust_report.py) but does not enforce the accepted 10-sample rule or byte-identical JSON determinism. Acceptance criteria not met.
- Write set: `desktop/engine/trust_report.py`, `tests/test_trust_report.py`, `desktop/SwiftNetMax/Sources/netmax-desktop/TrustReportView.swift`.
- Scope: Generate a statistical report over 10 samples (median, p95, CV). Flag throughput measurements as unqualified if CV > 5%. Output must be reproducible byte-identical JSON for identical fixtures. UI displays the variance and flags.
- Acceptance: Passes unit tests verifying 10-sample aggregation, CV thresholding, and byte-identical determinism. Swift view visualizes qualified vs. unqualified states.

#### G-02 — Operator-initiated Fleet Drift Workbench
- Owner: R2 (MCP fleet integration), R6 (Swift UI)
- Status: PARTIAL as of 2026-10-08 (Phase 0): MCP tool implemented for real (20-probe baselines, 3-consecutive-breach rule, 13 unit + 9 e2e tests green); Swift FleetDriftWorkbench UI remains a stub (buttons set label text only). Acceptance criterion "UI accurately reflects drift states" not met.
- Write set: `desktop/netmax-mcp-server.mjs`, `desktop/SwiftNetMax/Sources/netmax-desktop/FleetDriftWorkbench.swift`.
- Scope: Allow manual baseline comparisons across up to 32 explicitly configured fleet peers. Establish a 20-sample baseline. Trigger a flag only if 3 consecutive checks show latency >20% above baseline or packet loss >1% above baseline. Enforce strictly zero background checks (operator initiated only).
- Acceptance: MCP accepts baseline initialization and subsequent check triggers. UI accurately reflects drift states without automatic polling.

#### G-03 — ISP-Ready Evidence Export
- Owner: R6 (Swift UI), R1 (PDF/JSON Export backend)
- Status: DOWNGRADED 2026-10-08 (Phase 0): netmax_export_manifest.py is a skeleton (no PDF generation, no record selection, no redaction of real records). Acceptance criteria not met.
- Write set: `desktop/SwiftNetMax/Sources/netmax-desktop/EvidenceExport.swift`, `desktop/engine/export_manifest.py`.
- Scope: Package user-selected historical records into a PDF report and a JSON manifest. Manifest must include calculation formulas, unit metadata, sample counts, and a redaction summary. Must be processed 100% locally.
- Acceptance: Tests prove exported JSON/PDF contain no synthetic secrets, PII, or tokens. Output must correctly represent the metadata methodology.

#### G-04 — Policy-Bound MCP Workflows
- Owner: R2 (MCP Node server)
- Status: DOWNGRADED 2026-10-08 (Phase 0): MCP tool returns canned responses; acceptance test file desktop/test_mcp_workflows.mjs does not exist. Acceptance criteria not met.
- Write set: `desktop/netmax-mcp-server.mjs`, `desktop/test_mcp_workflows.mjs`.
- Scope: Implement named macro workflows as single MCP tools. Each workflow binds fixed time/stream ceilings, explicitly allowed destinations, and rejects any privileged shaping controls.
- Acceptance: Boundary tests prove that an invalid workflow request or a workflow exceeding ceilings instantly rejects before spawning any child processes.

#### G-05 — Local Regression Alerts
- Owner: R6 (Swift UI), R1 (Engine data aggregator)
- Status: DOWNGRADED 2026-10-08 (Phase 0): netmax_local_regression.py is a pure function with no history integration, no baseline display, no dismiss/disable. Acceptance criteria not met.
- Write set: `desktop/SwiftNetMax/Sources/netmax-desktop/RegressionAlerts.swift`, `desktop/engine/local_regression.py`.
- Scope: Track historical samples (min 20) entirely on-device. Trigger a local UI alert if 3 consecutive threshold breaches occur for latency or throughput. Provide UI controls to dismiss or disable the alert. Strictly no remote AI or network requests.
- Acceptance: Unit tests prove alert triggering logic. Swift UI displays the contributing samples with a clear disable toggle.
