# NetMax Read-Only Security and Product Audit

Date: 2026-10-07
Scope: /Users/user/netmax-app working tree, including uncommitted and untracked files
Mode: read-only analysis; no application code was changed

## Executive assessment

The Python suite, Ruff, MCP syntax check, bridge self-test, and Swift package tests pass. The highest risks are at the MCP trust boundary: arbitrary output/history paths, unsafe temporary-envelope writes, weak URL policy, AI-controlled shaping values, and system-wide pf rollback/ownership. Public distribution is not release-ready because the bundle is ad-hoc signed. Existing good controls include 0600 history, hashed SSIDs, scrubbed bridge environments, downloader symlink checks, and bearer auth for off-loopback HTTP; the threat model and product claims lag the current implementation.

## 1. Architecture map (12 lines)

1. Root Python modules are the CLI/measurement engine; desktop/engine/ contains maintained mirrors.
2. netmax.py dispatches speed, DNS, bloat, AI, history, fetch, watch, export, and shaping modes.
3. desktop/SwiftNetMax is the macOS menu-bar UI and launches the Python bridge.
4. desktop/bridge/engine_bridge.py converts bounded argv into JSON envelopes and spawns the engine.
5. desktop/netmax-mcp-server.mjs exposes 17 tools over stdio or optional Streamable HTTP.
6. MCP HTTP is loopback by default; NETMAX_HOST enables LAN binding and NETMAX_TOKEN gates it.
7. strict_limit invokes macOS dnctl/pf and requires root; it shapes system-wide traffic.
8. download_file accepts tool-call URL/output input and writes through netmax_fetch.py.
9. ai_analyze accepts inline JSON or a caller-supplied history path and may send data to an AI provider.
10. Fleet aggregation fetches operator-configured peer URLs and can attach a shared bearer token.
11. Swift history stores hashed network identifiers; support bundles redact selected fields before export.
12. External inputs include CLI args, environment variables, MCP/HTTP calls, plugins, downloads, and AI/provider responses.

## 2. Tool verification

### Verified passing

~~~text
ruff check .
All checks passed!

pytest -q
1007 passed, 5 subtests passed in 21.21s

cd desktop && npm test
Syntax OK - 17 tools ready

python3 desktop/bridge/engine_bridge.py selftest
selftest: 4/4 checks passed

cd desktop/SwiftNetMax
CLANG_MODULE_CACHE_PATH=/private/tmp/netmax-clang-cache SWIFT_MODULECACHE_PATH=/private/tmp/netmax-swift-cache swift build
Build complete!

CLANG_MODULE_CACHE_PATH=/private/tmp/netmax-clang-cache SWIFT_MODULECACHE_PATH=/private/tmp/netmax-swift-cache swift test
Test Suite 'All tests' passed.
Executed 1 test, with 0 failures
~~~

### Not cleanly verified

~~~text
bandit -r . ...
zsh:1: command not found: bandit

semgrep --config=p/python ...
zsh:1: command not found: semgrep
~~~

~~~text
pip-audit -r requirements-ci.txt
ERROR:pip_audit._cli:Failed to upgrade pip: [...]
~~~

The pip audit failed during bootstrap because network/package installation was unavailable; it is not evidence of zero vulnerabilities.

~~~text
cd desktop && npm audit --audit-level=low
npm warn audit request to https://registry.npmjs.org/-/npm/v1/security/audits/quick failed, reason: getaddrinfo ENOTFOUND registry.npmjs.org
undefined
npm error audit endpoint returned an error

cd plugins/vscode && npm audit --audit-level=low
npm error code ENOLOCK
npm error audit This command requires an existing lockfile.
~~~

Phase 0 also failed in this checkout:

~~~text
===== PHASE 0 GATE: FAIL (5 passed / 3 failed) =====
failed: a b c
/opt/homebrew/opt/python@3.14/bin/python3.14: No module named pytest
~~~

Direct pytest and Swift build/test pass under the configured test environment. The gate failure is an automation/reproducibility finding, not source compile evidence.

## 3. Ranked findings

| ID | Sev | Domain | File:Line | Issue | Fix | Effort |
|---|---|---|---|---|---|---|
| F-001 | High | Security/data loss | desktop/netmax-mcp-server.mjs:496-505; netmax_fetch.py:379-386 | Arbitrary MCP output path can replace a regular file | Safe output root; no implicit unlink; no-follow writes | M |
| F-002 | High | Security/privacy | desktop/netmax-mcp-server.mjs:776-786; netmax.py:1230-1232,1267-1269,1905-1909; netmax_ai_provider.py:407-416 | Arbitrary history read can reach an AI endpoint | History allowlist, redaction, explicit outbound consent | M |
| F-003 | High | Security/privilege | desktop/netmax-mcp-server.mjs:189-192; desktop/bridge/engine_bridge.py:254-275 | Predictable temp path plus ordinary write permits symlink/TOCTOU replacement | Private temp dir; O_EXCL/O_NOFOLLOW; atomic rename | M |
| F-004 | High | Security/correctness | netmax_ai.py:684-702; netmax.py:942-944,996-999 | AI can replace the hard shaping ceiling with invalid/unbounded pace | Validate and reapply hard cap after AI | S |
| F-005 | High | Reliability/safety | netmax_shape.py:142-150 | Partial pf setup failure can leave system-wide state changed | Transactional apply and rollback | M |
| F-006 | Medium | Reliability/race | netmax_shape.py:28-29,153-160 | Concurrent runs share and blindly flush one anchor/pipe | Single-flight lock and owner cleanup | M |
| F-007 | Medium | Security/SSRF | desktop/netmax-mcp-server.mjs:496; netmax_fetch.py:99-104 | No explicit HTTP(S), redirect, or private-target policy | URL policy and bounded redirects | M |
| F-008 | Medium | Security/privacy | netmax_ai_provider.py:177-188,202-206 | Loopback detection is substring matching | Exact hostname/IP parsing | S |
| F-009 | Medium | Security/SSRF | desktop/netmax-mcp-server.mjs:335-349 | Fleet fetch can probe arbitrary configured URLs and forward token | Peer allowlist and rebinding-safe resolution | M |
| F-010 | Medium | Availability/performance | desktop/netmax-mcp-server.mjs:611-658 | One call can run 21,600 seconds x 50 streams plus probes | Global budgets, semaphore, quotas | M |
| F-011 | Medium | Distribution/ops | desktop/scripts/verify_phase0.sh:17,64,73,89; verify_phase1.sh:27,91,100 | Gates fail in a normal checkout due environment assumptions | Project interpreter/cache preflight | S |
| F-012 | Medium | Supply chain/CI | .github/workflows/ci.yml:20,23,69,72; requirements-ci.txt:2-7 | No audit/SAST gates; mutable action tags; ranged Python deps | Lock/pin and add audit/SBOM jobs | M |
| F-013 | Medium | Build/test quality | plugins/vscode/package.json:45-47; missing package-lock.json | Package test script targets nonexistent path | Fix script and lock policy | S |
| F-014 | Medium | Threat model/ops | docs/THREAT-MODEL.md:22-27; desktop/netmax-mcp-server.mjs:592-603,948-989 | Threat model denies current HTTP/root surfaces | Update threat model and operator docs | S |
| F-015 | High | Distribution | desktop/scripts/build_app.sh:123-131 | Public bundle is explicitly ad-hoc signed | Developer ID, hardened runtime, notarization | L |
| F-016 | Medium | Distribution/correctness | .github/workflows/ci.yml:139-145; desktop/scripts/build_app.sh:36-53 | CI does not verify universal output | Build both architectures and assert lipo | M |
| F-017 | Medium | Correctness/UX | DashboardCardsView.swift:630,1325-1385 | Active AI card displays randomized fabricated metrics | Remove or wire to real data | S/M |
| F-018 | Low | UX/conversion | landing/index.html:934-960,1811-1822 | Static analytics and fake success toasts are presented as real | Remove or label demo | S |
| F-019 | Low | Code quality/release | APIIntegration.swift:9-16; CloudSync.swift:9-16; DatabaseBackup.swift:9-17; PluginSystem.swift:9-21; SocialSharing.swift:10-26 | Untracked Swift stubs have no callers | Delete or implement behind tests/flags | S |
| F-020 | Low | Supply chain | desktop/package-lock.json:2-9; desktop/package.json:1,5 | Lock root identity/version is stale | Regenerate and assert consistency | S |
| F-021 | Low | UX/security | UpdateChecker.swift:113-115; SettingsView.swift:706-708 | Update response controls browser URL without allowlisting | Fixed release origin only | S |
| F-022 | Medium | Reliability/performance | plugins/vscode/extension.js:31-34,48-51; plugins/vscode/media/trends.js:43-64 | VS Code history command synchronously loads and parses unbounded history | Async reads with strict byte, row, and record-size limits | M |
| F-023 | Medium | Distribution/reproducibility | desktop/scripts/build_app.sh:32,87,107-110 | Bundle embeds wall-clock build metadata, making same-commit outputs differ | Honor a fixed `SOURCE_DATE_EPOCH` in reproducible builds | S |

## 4. Verified finding details

### F-001 — arbitrary MCP download output path

Evidence:

~~~text
desktop/netmax-mcp-server.mjs:496-505
url: z.string().url()
output: z.string().optional().describe("Output filename (default: derived from URL)")
if (output) args.push(output);
return runTool("download_file", () => runEngineDirect(["fetch", ...args]));

netmax_fetch.py:379-386
if out_path.exists() or out_path.is_symlink():
    ...
    out_path.unlink()
out_fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
~~~

Scenario: an MCP caller can choose a user-owned path and cause an existing regular file to be unlinked/replaced. Symlink checks do not make arbitrary output authority safe.

Fix: app-owned download root, descriptor-verified path, traversal rejection, explicit safe-replace operation, and retained O_NOFOLLOW/O_EXCL/0600.

### F-002 — arbitrary history read and possible AI exfiltration

Evidence:

~~~text
desktop/netmax-mcp-server.mjs:776-786
history_path: z.string().optional().describe("history JSONL to replay")
if (history_path !== undefined) args.push("--history", String(history_path));
return runTool("ai_analyze", () => runEngineDirect(args));

netmax.py:1230-1232,1267-1269,1905-1909
if text.startswith("@"):
    path = Path(text[1:]).expanduser()
    text = path.read_text(encoding="utf-8")
rows = netmax_history.load_and_normalize(path_spec)
history_rows = (_load_history(args.history, ...) if args.history else None)

netmax_ai_provider.py:407-416
active.base,
data=json.dumps(payload).encode("utf-8"),
with urlopen(request, timeout=timeout) as response:
    body = json.loads(response.read().decode("utf-8"))
~~~

Scenario: a caller names any readable JSONL file; its content can be placed in a provider request. Fix with history-directory allowlisting, symlink/size/row limits, redaction, and explicit consent for non-loopback providers. Treat history text as untrusted prompt data.

### F-003 — unsafe JSON envelope materialization

Evidence:

~~~text
desktop/netmax-mcp-server.mjs:189-192
const tmpFile = join(tmpdir(), `netmax-mcp-${Date.now()}-${Math.random().toString(36).slice(2)}.json`);
execFile(PYTHON, [BRIDGE, "run", mode, ...args, "--json-out", tmpFile], ...)

desktop/bridge/engine_bridge.py:254-275
target = Path(path)
target.write_text(json.dumps(payload), encoding="utf-8")
~~~

Scenario: a local process can race the predictable temporary name with a symlink/replacement. With the documented root requirement for strict shaping, this can become a privileged write primitive. Fix private mkdtemp, O_CREAT|O_EXCL|O_NOFOLLOW, 0600, fsync, and atomic rename.

### F-004 — AI governor bypasses hard ceiling

Evidence:

~~~text
netmax_ai.py:693-695
pace_bps = raw.get("pace_bps")
if pace_bps is not None:
    pace_bps = float(pace_bps)

netmax.py:942-944,996-999
per_stream_bps = min(per_stream_bps, pace_ceiling_bps / streams)
if decision.pace_bps is not None:
    per_stream_bps = decision.pace_bps / max(streams, 1)
~~~

Scenario: a compromised provider, prompt injection, NaN, or Infinity can produce a non-finite/over-ceiling value. Apply finite/range validation and reapply the cap after every AI update; test invalid values.

### F-005 — partial pf setup can leave changed state

Evidence:

~~~text
netmax_shape.py:142-150
run(["pfctl", "-e"])  # no-op when already enabled; returncode ignored
if run(["pfctl", "-f", main_path]).returncode != 0:
    raise ShapeError("pf refused the merged ruleset — nothing installed")
if run(["dnctl", "pipe", str(PIPE_NO), "config", "bw", rate]).returncode != 0:
    raise ShapeError(...)
~~~

Scenario: if enabling succeeds and a later step fails, apply raises before returning state, so normal remove() cannot run. Restore exact pre-state in rollback logic and add failure-injection tests.

### F-006 — global shaping ownership race

Evidence:

~~~text
netmax_shape.py:28-29
PIPE_NO = 10
ANCHOR = "netmax"

netmax_shape.py:153-160
run(["pfctl", "-a", ANCHOR, "-F", "all"])
run(["dnctl", "pipe", str(PIPE_NO), "delete"])
~~~

Scenario: overlapping calls can tear down each other’s anchor/pipe and disable pf using stale state. Add a system lock, owner token, and owner-scoped cleanup.

### F-007 — downloader URL policy gap

Evidence:

~~~text
desktop/netmax-mcp-server.mjs:496
url: z.string().url()

netmax_fetch.py:99-104
req = Request(url, headers=headers or {})
return urlopen(req, timeout=30)
~~~

Scenario: schemes, redirects, and private targets are delegated to urllib rather than constrained by product policy. Allow only documented HTTP(S), validate redirects, reject private/link-local targets by default, and bound response size.

### F-008 — spoofable custom AI “local” detection

Evidence:

~~~text
netmax_ai_provider.py:177-188,202-206
local = _is_loopback(base)
requires_key=not local or bool(key)
lowered = url.lower()
return any(host in lowered for host in ("127.0.0.1", "localhost", "[::1]", "0.0.0.0"))
~~~

Scenario: https://127.0.0.1.attacker.example/... is treated as local and may not require a key. Parse exact hostname/IP and make no-key local operation explicit.

### F-009 — fleet SSRF/token forwarding

Evidence:

~~~text
desktop/netmax-mcp-server.mjs:335-349
url: entry.slice(i + 1).trim()
const headers = token ? { authorization: `Bearer ${token}` } : {};
const r = await fetch(p.url.replace(/\/$/, "") + "/", { headers, signal: ctrl.signal });
~~~

Scenario: operator-config control can turn this into internal probing and shared-token disclosure. Validate hosts/schemes, block private/link-local destinations unless explicitly enabled, prevent DNS rebinding, and use per-peer credentials.

### F-010 — unbounded concurrent resource use

Evidence:

~~~text
desktop/netmax-mcp-server.mjs:611-614
speedSeconds: z.number().int().min(5).max(21600)
speedStreams: z.number().int().min(1).max(50)

desktop/netmax-mcp-server.mjs:619-658
// Speed test (boost), DNS ranking, and optionally WiFi + eco-bloat all
// execute in parallel
const results = await Promise.all(tasks);
~~~

Scenario: a token holder can occupy the server for six hours with 50 streams plus probes. Add global semaphore, per-client quota, stream-seconds budget, cancellation, and a bounded absolute duration.

### F-011 — verification gates are not reproducible

Evidence:

~~~text
desktop/scripts/verify_phase0.sh:17
PY="${NETMAX_PYTHON:-python3}"

desktop/scripts/verify_phase0.sh:64,73,89
swift build -c release
"$PY" -m pytest -q
"$PY" -m pytest "$BRIDGE_DIR/test_engine_bridge.py" -q
~~~

Observed output:

~~~text
===== PHASE 0 GATE: FAIL (5 passed / 3 failed) =====
failed: a b c
/opt/homebrew/opt/python@3.14/bin/python3.14: No module named pytest
~~~

Fix project interpreter/cache preflight and use the same command in CI and release gates.

### F-012 — CI lacks the requested security baseline

Evidence:

~~~text
.github/workflows/ci.yml:20,23,69,72
uses: actions/checkout@v4
uses: actions/setup-python@v5
uses: actions/setup-node@v4

requirements-ci.txt:2-7
pytest>=8,<9
pytest-asyncio>=0.24,<1
pytest-xdist>=3,<4
aiosqlite>=0.20,<1
matplotlib>=3.8,<4
ruff>=0.8,<1
~~~

No workflow step runs pip-audit, npm audit, Bandit, Semgrep, SBOM generation, or signature verification. Fix by hashing/locking dependencies, pinning action SHAs, and failing on Critical/High audit findings.

### F-013 — VS Code test script fails before running tests; lockfile is missing

Evidence:

~~~text
plugins/vscode/package.json:45-47
"test": "node --test test/"

cd plugins/vscode && npm test
Error: Cannot find module '/Users/user/netmax-app/plugins/vscode/test'
code: 'MODULE_NOT_FOUND'
~~~

`plugins/vscode/test/trends.test.js` exists, but Node 22 does not accept the directory path in this script as a test entry, so zero tests run. `plugins/vscode/package-lock.json` is also absent, and CI bypasses this script. Point the script at `test/*.test.js`, add the matching lockfile, and run `npm test` in CI.

### F-014 — threat model is stale

Evidence:

~~~text
docs/THREAT-MODEL.md:24-27
- No server component. No accounts. No telemetry. No analytics.
- No inbound network surface: the app listens on nothing.
  There is no root, no daemon beyond a per-user LaunchAgent.

desktop/netmax-mcp-server.mjs:592-603
"REQUIRES the MCP server to run as root"

desktop/netmax-mcp-server.mjs:948-989
const host = process.env.NETMAX_HOST || "127.0.0.1";
if (!LOOPBACK.has(host) && !token) ... process.exit(2);
~~~

Scenario: deployment and incident response use the wrong trust boundaries. Update threat model, privacy claims, operator guidance, and abuse cases together.

### F-015 — ad-hoc signing is not a trusted public release

Evidence:

~~~text
desktop/scripts/build_app.sh:123-125
# --- 4. Ad-hoc sign (deep) ---
log "codesign -s - --force --deep (AD-HOC: no Apple signing identities on this machine)"
codesign -s - --force --deep "$APP"
~~~

Scenario: users lack Developer ID/notarization assurance and may hit Gatekeeper warnings. Use Developer ID Application, hardened runtime, notarization/stapling, ticket verification, and checksums.

### F-016 — universal build is not verified in CI

Evidence:

~~~text
.github/workflows/ci.yml:139-145
BIN_PATH=$(swift build -c release --show-bin-path)
swift build -c release

desktop/scripts/build_app.sh:36-40
# UNIVERSAL build (arm64 + x86_64).
swift build -c release --arch arm64 --arch x86_64
~~~

Scenario: CI can pass while the shipped binary is single-architecture. Build both architectures, assert lipo output, and exercise the real bundle script.

### F-017 — dashboard shows randomized data as AI

Evidence:

~~~text
DashboardCardsView.swift:630
PredictiveShaperView()

DashboardCardsView.swift:1339-1363,1381-1385
Text("AI-Powered")
Text("... Mbps")
Text("...% confidence")
// Simulate AI prediction
recommendedSpeed = 85.5 + Double.random(in: -10...10)
confidence = 0.75 + Double.random(in: 0...0.2)
prediction = "Based on historical data, expect speeds around ..."
~~~

Scenario: users can act on an ungrounded recommendation. Remove until wired to real history/engine data, or label as demo and show provenance/sample/freshness.

### F-018 — landing page has fake analytics/actions

Evidence:

~~~text
landing/index.html:943-956
<div class="analytics-value">142</div>
<div class="analytics-value">99.2%</div>
<div class="analytics-value">42.7</div>
<div class="analytics-value">12ms</div>

landing/index.html:1817-1822
showToast('Data export started!', 'success');
showToast('Restore complete!', 'success');
~~~

Scenario: prospective users see fabricated personal metrics and success confirmation without an operation. Remove, label as demo, or implement real state.

### F-019 — untracked Swift feature stubs

Evidence:

~~~text
APIIntegration.swift:13-15
print("API request: ...")
completion(nil)

DatabaseBackup.swift:10-17
print("Creating database backup")
return nil
~~~

The same pattern exists in CloudSync.swift, PluginSystem.swift, and SocialSharing.swift; search found each symbol only in its own file. Delete until scoped or implement behind flags/tests.

### F-020 — stale npm lock identity/version

Evidence:

~~~text
desktop/package.json:1,5
"name": "@netmax/mcp-server"
"version": "1.0.7"

desktop/package-lock.json:2-9
"name": "netmax-mcp-server",
"version": "1.0.0"
~~~

Scenario: release/review tooling sees a different package identity/version. Regenerate and assert consistency.

### F-021 — update checker opens API-controlled URL

Evidence:

~~~text
UpdateChecker.swift:113-115
let html = obj["html_url"] as? String ?? releasesPageURL
return compare(... htmlURL: html, ...)

SettingsView.swift:706-708
if let s = outcome.htmlURL, let u = URL(string: s) {
    NSWorkspace.shared.open(u)
}
~~~

Scenario: compromised repository metadata can send a user to phishing. Construct the fixed release URL locally or allow only exact GitHub HTTPS URLs.

### F-022 — VS Code history loading is synchronous and unbounded

Evidence:

~~~text
plugins/vscode/extension.js:31-34
const out = execFileSync(
  'sqlite3', ['-json', db,
    'SELECT ts, mode, result_raw FROM history ORDER BY ts ASC, id ASC;'],
  { timeout: 10000, maxBuffer: 32 * 1024 * 1024 });

plugins/vscode/extension.js:48-51
if (fs.existsSync(jsonl)) {
  const rows = trends.parseSwiftJsonl(fs.readFileSync(jsonl, 'utf-8'));
  return { rows, source: 'history.jsonl' };
}

plugins/vscode/media/trends.js:43-45,64
function parseSwiftJsonl(text) {
  const rows = [];
  for (const line of String(text || '').split('\n')) {
    ...
  return rows.sort((a, b) => a.t - b.t);
}
~~~

The SQLite query has no row limit and blocks the extension host for up to 10 seconds; the JSONL path reads the entire file synchronously, splits every line, retains every parsed row, and sorts the full result.

Scenario: as local history grows or contains an unusually large/corrupt record, opening the trends command can freeze VS Code, consume excessive extension-host memory, or terminate the extension host. This is a local availability/reliability issue; it does not imply remote code execution.

Fix: make history I/O asynchronous; query only the newest 3,000 SQLite rows and cap each result payload at 4 KiB; cap JSONL scanning at 10 MiB and each record at 64 KiB while retaining at most 3,000 valid rows; show a clear limit/error state. Test exact-limit and over-limit fixtures without touching a user's real history.

### F-023 — wall-clock metadata prevents reproducible app bundles

Evidence:

~~~text
desktop/scripts/build_app.sh:32
APP_BUILD="$(date -u '+%Y%m%d')"

desktop/scripts/build_app.sh:87,107-110
BUILD_DATE="$(date -u '+%Y-%m-%d %H:%M UTC')"
<key>CFBundleVersion</key>
<string>${APP_BUILD}</string>
<key>NetMaxBuildDate</key>
<string>${BUILD_DATE}</string>
~~~

Scenario: two builds of the same source commit at different times embed different `Info.plist` values, so the planned clean-build SHA-256 comparison fails even when executable code and dependencies are identical.

Fix: make the build script honor a validated `SOURCE_DATE_EPOCH` for both fields. Preserve current-time behavior for ordinary local builds; the reproducibility harness supplies the source commit timestamp and verifies both bundles use identical metadata.

## 5. Controls verified as present

- History privacy code hashes network identifiers with a stored salt and applies restrictive permissions.
- Support bundles redact selected fields and avoid full raw history by default.
- The bridge scrubs Python startup/path environment and invokes subprocesses with argv.
- The downloader rejects pre-placed symlinks/non-files and creates downloaded files 0600; F-001 is the remaining path authority/replacement issue.
- HTTP binds to loopback by default and refuses off-loopback startup without a bearer token.
- Ruff, 1007 Python tests plus 5 subtests, bridge self-tests, MCP syntax, and Swift tests passed.

## 6. Suspected / not promoted

No unverified vulnerability is promoted to the ranked table. Bandit and Semgrep are not installed. pip-audit and desktop npm audit could not reach advisory services, and VS Code npm audit has no lockfile. These are verification gaps, not clean results. Runtime exploitability of conditional SSRF/race scenarios should be confirmed after fixes with an isolated harness.

## 7. Domain scorecard

| Domain | Score | Justification |
|---|---:|---|
| Security | 5/10 | Good argv/env/symlink/bearer foundations, but MCP inputs cross filesystem, network, root, and AI boundaries without complete policy. |
| Privacy | 5/10 | Local history protections are thoughtful, but arbitrary history/provider submission are not constrained at MCP. |
| Reliability | 5/10 | Strong tests, but shaping rollback and concurrent ownership have failure-state gaps. |
| Correctness | 5/10 | Core tests pass, while AI pacing and randomized UI make ungrounded claims. |
| Performance | 6/10 | Parallel diagnostics is intentional, but resource budgets are caller-controlled and extreme. |
| Code quality | 6/10 | Ruff/tests are green; mirrors, stubs, stale metadata, and docs drift increase risk. |
| UX/UI | 5/10 | Accessibility hooks exist, but fake prediction/landing claims undermine trust; WCAG/VoiceOver is unmeasured. |
| Distribution/ops | 4/10 | Basic CI exists, but audit gates, reproducible verification, universal release checks, and notarization are incomplete. |

## Areas checked

Python engine/mirrors, AI/provider, fetch/upload/shape/watch/export, Node MCP stdio/HTTP/fleet/Slack, bridge, Swift package/tests/history/privacy/bundle/update, Tk GUI, landing page, VS Code plugin, manifests/locks, GitHub Actions, build/sign/verify scripts, threat-model/MCP docs, and available lint/test/build/audit commands.
