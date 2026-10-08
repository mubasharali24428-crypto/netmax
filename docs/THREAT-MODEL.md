# NetMaxDesktop Threat Model

*Updated for Gate C (2026-10-07) — Comprehensive alignment with Gate B trust boundaries, privileged operations, network surfaces, and privacy controls (addressing audit finding F-014).*

---

## 1. Assets in Scope

NetMax is a local-first network measurement and diagnostic tool for macOS and AI coding agents. The assets defended, in order of priority:

1. **User Measurement History & Network Privacy** — Timestamps, test modes, throughput, latency, bloat grades, and salted SHA-256 hashed network identifiers (`nm1:`) stored in `~/Library/Application Support/NetMaxDesktop/`. Protects home and office operational patterns from unprivileged local or remote exfiltration.
2. **Machine & System Integrity** — Guarding against unauthorized code execution or privilege escalation via bundled Python scripts, scheduled LaunchAgent runs, bridge envelopes, or kernel-level traffic shaping.
3. **User Bandwidth, Disk, and Kernel Resources** — Preventing resource exhaustion, runaway upload/download transfers, uncapped temp file generation, orphaned packet filter rules, or leaked dummynet pipes.
4. **User Trust & Truthful Egress** — Ensuring outbound network traffic matches disclosed policies exactly: measurements contact only disclosed endpoints; remote AI egress is strictly opt-in and payload-bounded; fleet reporting is restricted to allowlisted HTTPS peers.

---

## 2. Architecture and Network Surface

### Local-First Architecture
NetMax operates without centralized user accounts or cloud infrastructure. Routine diagnostics (speed tests, bufferbloat grading, ping latency, jitter, WiFi metrics) run locally as the logged-in macOS user.

### Inbound Network Surface
- **Desktop UI & Menu Bar App**: Listens on no network ports or sockets.
- **MCP Server Stdio Transport**: Standard input/output communication with local agent harnesses (Claude Code, Cursor, Codex). Listens on no network ports.
- **MCP Server HTTP Transport (`--http`)**:
  - By default, binds to local loopback (`127.0.0.1:8808`), configurable via `NETMAX_PORT` and `NETMAX_HOST`.
  - When `NETMAX_HOST` is bound to any non-loopback interface (e.g. `0.0.0.0` or LAN IP), a secret bearer token configured via `NETMAX_TOKEN` is mandatory. The server strictly refuses to start off-loopback without `NETMAX_TOKEN` (process exit 2).
  - Optional TLS encryption is supported via `NETMAX_TLS_CERT` and `NETMAX_TLS_KEY` (PEM files). If only one is provided, the server aborts startup.

### Privileged Operations Surface (Root Shaping)
Kernel-level rate limiting (`netmax.py limit --strict` and MCP tool `mcp__netmax__strict_limit`) requires root privileges to manipulate macOS `dnctl` dummynet pipes and the packet filter (`pf`) anchor `netmax_strict_limit`:
- **Pre-elevation Ownership Lock (B-10)**: Before executing privileged helper logic, the engine verifies that the script file and all parent directories are owned by `root` or the invoking user and are not world-writable.
- **Exclusive Process Lock**: Acquires an exclusive `fcntl.flock` on root-owned `/var/run/netmax-shaping.lock`.
- **Atomic State Recording**: Records active PID, random session token, allocated pipe ID (in range 20000–29999), and prior `pf` enabled state into `/var/run/netmax-shaping/owner.json` (mode 0600).
- **Transactional Rollback (B-09)**: Any failure during `dnctl` pipe allocation or `pf` anchor loading triggers an immediate atomic rollback, deleting created pipes and restoring previous `pf` state.
- **Stale Owner Recovery**: On startup, if a stale lock file exists, NetMax verifies if the recorded PID is dead; if dead and markers match, it safely flushes the recorded pipe and anchor before proceeding.
- **Manual Operator Recovery**: In case of abnormal termination (e.g. SIGKILL), operators can manually clear lingering shaping rules:
  ```bash
  sudo dnctl -q pipe delete <pipe_id>
  sudo pfctl -a netmax_strict_limit -F all
  ```

### Outbound Network & Egress Boundaries
1. **Measurement Endpoints**: Speed tests and latency probes communicate exclusively with public CDNs and test endpoints over TLS. HTTP fallback is disabled.
2. **Download File Egress & Path Controls (B-01, B-06)**: The `mcp__netmax__download_file` tool requires public HTTPS URLs, resolves and validates DNS before connecting (rejecting private/loopback/link-local/metadata IPs), follows up to 5 redirects (re-validating each target), and caps downloads at exactly 1 GiB. Output files are restricted to safe authorized directories with sanitized basenames.
3. **Remote AI Provider Egress (B-03, B-05)**:
   - Off by default. Remote AI analysis can only be enabled by the user in macOS Settings (`AppPreferences.shared.allowRemoteAI`). MCP has no argument or environment override for this setting.
   - When enabled, remote AI requests discard free-form prompts and user text, sending only 11 allowlisted numeric and enumerated metric fields via pinned HTTPS transport.
   - Provider responses are capped at 1 MiB and maximum JSON depth 16.
   - Current implementation limitation: existing analyzers fall back to local rule-based evaluation (`source: local`).
4. **Fleet Reporting Egress (B-07)**:
   - Configured via `NETMAX_FLEET_ALLOWLIST` (JSON map of lowercase alias to exact HTTPS origin) and optional `NETMAX_FLEET_TOKENS`.
   - Accepts at most 32 peers. Requires exact HTTPS origins (no userinfo, path, query, or fragment).
   - Resolves DNS immediately before request; strictly rejects private, loopback, link-local, multicast, or non-global IP addresses.
   - Requests pin the resolved address with SNI/hostname verification, enforce a 5-second timeout, cap responses at 16 KiB, and disable redirects.

### Data Storage, Privacy & Retention Controls (B-02, B-13)
- **Fixed Storage Location**: All history data is confined to `~/Library/Application Support/NetMaxDesktop/` with POSIX permissions 0600. No arbitrary `history_path` parameters are accepted.
- **Dual Persistence**: `history.jsonl` acts as the primary sequential log; `history.db` acts as an isolated SQLite analytical cache.
- **Retention Archiving**: Automated retention moves records older than the configured threshold into `archive-history.jsonl` rather than silently deleting them.
- **Reversible Clear vs. Permanent Erase**:
  - "Clear history" moves active runs to `cleared-history.jsonl` with an immediate 30-second Undo banner.
  - "Erase All History…" is an explicit irreversible operation confirmed via a destructive dialog. It calls `HistoryStore.eraseAll()` to permanently remove `history.jsonl`, `history.db` (plus `-wal` and `-shm` sidecars), `archive-history.jsonl`, and `cleared-history.jsonl`, while preserving unrelated configuration and sentinel files.
- **Support Bundle Redaction (B-12)**: The diagnostic bundle tool (`netmax_bundle.py`) scrubs SSIDs, BSSIDs, passwords, API tokens, home directory usernames, and sensitive environment keys before generating a mode 0600 zip archive.

---

## 3. Adversary Model

| # | Adversary | Capability | Primary Target | Mitigations in Place |
|---|---|---|---|---|
| **A1** | Local unprivileged process | Read/write accessible user files, inspect processes | Measurement history, configuration files | Permissions 0600 on all data files; strict path validation; no sensitive data in argv |
| **A2** | Local attacker on shared Mac | Pre-create symlinks in shared dirs (`/tmp`, `/var/tmp`) | File overwrite, privilege escalation | `O_NOFOLLOW`, `O_EXCL`, private subdirectories, symlink rejection in bridge (B-04) |
| **A3** | Path & Environment Hijacker | Malicious Python or binaries on `PATH` | Engine execution tampering | Absolute `/usr/bin/python3` execution; scrubbed `PYTHONPATH`/`PYTHONHOME` (A-01, B-01) |
| **A4** | Hostile / Man-in-the-Middle Network | Intercept or manipulate measurement/fleet traffic | Falsify metrics, SSRF, DNS rebinding | Mandatory TLS verification; pinned DNS resolution rejecting non-global IPs (B-06, B-07) |
| **A5** | Malicious MCP Client / Prompt Injection | Feed hostile arguments, command injection, path traversal | Child process escape, arbitrary file write | Pre-spawn Zod/schema validation (B-11); argv token arrays; sanitized output paths; resource budgets (B-08) |
| **A6** | Local Privilege Escalation Attacker | Exploit `limit --strict` root execution | Root compromise via dummynet/pf | File ownership verification (B-10); transactional rollback (B-09); exclusive lock |

---

## 4. Trust Boundaries & Data Flow

```
┌────────────────────────────────────────────────────────┐
│               AI Coding Agent / Client                 │
│                 (Claude, Cursor, CLI)                  │
└──────────────────────────┬─────────────────────────────┘
                           │ stdio OR HTTP (loopback / LAN with NETMAX_TOKEN)
                           ▼
┌────────────────────────────────────────────────────────┐
│          MCP Server (netmax-mcp-server.mjs)            │
│  - Pre-spawn schema validation (B-11)                  │
│  - Concurrency budget: ≤2 global, ≤1 session (B-08)    │
│  - Resource limits: ≤300 stream-sec, ≤180s wall clock  │
└──────────────────────────┬─────────────────────────────┘
                           │ argv array (no shell string)
                           ▼
┌────────────────────────────────────────────────────────┐
│           Python Bridge (engine_bridge.py)             │
│  - Sanitized env (PYTHONPATH, NOUSERSITE=1)            │
│  - Race-safe temp envelopes (0600, no symlinks, B-04)  │
└──────────────────────────┬─────────────────────────────┘
                           │ validated arguments
                           ▼
┌────────────────────────────────────────────────────────┐
│            Python Engine (netmax.py & modules)         │
│  - Network measurements (curl/sockets over TLS)        │
│  - Salted SSID/BSSID hashing (nm1:)                    │
│  - Download output bounded to 1 GiB (B-06)             │
│  - Strict root shaping via pfctl + dnctl (B-09, B-10)  │
│  - Optional remote AI: strictly consent-gated (B-03)   │
└──────────────────────────┬─────────────────────────────┘
                           │ atomic append / SQLite (0600)
                           ▼
┌────────────────────────────────────────────────────────┐
│   Local Storage (~/Library/Application Support/...)    │
│  - history.jsonl & history.db (mode 0600)              │
│  - archive-history.jsonl & cleared-history.jsonl       │
│  - Permanent erase primitive (B-13)                    │
└────────────────────────────────────────────────────────┘
```

---

## 5. Resolved Audit Findings

| Finding | Vulnerability / Risk | Implementation Fix | Verification Gate |
|---|---|---|---|
| **F-001** | Arbitrary MCP download output path | Path validation and safe basename sanitization in pre-authorized directory | B-01-MCP, C-10 |
| **F-002** | Unbounded history read / path traversal | Pinned storage directory, mode 0600, fixed history path controls | B-02, B-13 |
| **F-003** | Race condition in bridge envelope creation | Private temp dir, `O_EXCL`, atomic no-replace hardlinks, symlink rejection | B-04, C-13 |
| **F-004** | Unbounded AI governor decisions | Stream and rate caps, 1 MiB response limit, depth 16 max, 1.5× ceiling | B-05 |
| **F-005** | Leaked dummynet pipes and pf rules on error | Transactional rollback of pipes and rules on failure; restoration of pf state | B-09, C-12 |
| **F-006** | Privilege escalation via non-root script write | File ownership and non-world-writable checks before root execution | B-10, C-12 |
| **F-007** | SSRF and unrestricted download URLs | Strict HTTPS parsing, DNS pinning, private IP rejection, 1 GiB cap | B-06, C-10 |
| **F-008** | SSRF and credential leaks in AI endpoints | Localhost/HTTPS validation, DNS pinning, stripped credentials/proxies | B-06, C-11 |
| **F-009** | Unrestricted fleet reporting egress | Strict JSON allowlist, HTTPS-only, DNS pinning, 16 KiB / 5s bounds | B-07 |
| **F-010** | Unbounded MCP concurrency and execution | Max 2 global jobs, max 1 session job, 300 stream-sec, 180s wall time | B-08 |
| **F-011** | Untrusted Python interpreter hijack | Enforced `/usr/bin/python3` default; strict environment scrubbing | A-01, B-01 |
| **F-012** | Insecure default permissions | POSIX 0600 enforced across all history files, DB, sidecars, and bundles | B-02, B-12 |
| **F-013** | Diagnostic bundle credential leakage | Automatic redaction of SSIDs, tokens, passwords, keys, and home paths | B-12 |
| **F-014** | Stale threat model denying HTTP/root surfaces | Complete overhaul of threat model, documenting HTTP, root, and fleet controls | **C-01 (Current)** |

---

## 6. Open Distribution Risks

- **Ad-hoc Code Signing (`F-015`)**: Public release binaries are currently built with ad-hoc signing. Production distribution requires an active Apple Developer ID, Hardened Runtime entitlements, and notarization (addressed in **C-07**).

---

## 7. Assumptions & Re-Audit Triggers

### Assumptions
- Target OS is macOS 13+ (Ventura or later) with Apple system Python 3 at `/usr/bin/python3`.
- The user account owns its `~/Library/Application Support/NetMaxDesktop/` directory and `~/Library/Preferences/`.
- Root access via `sudo` is required only for packet filter rate-limiting (`limit --strict` / `strict_limit`).

### Re-Audit Triggers
Re-run a complete threat model review whenever:
1. A new network listening port or daemon is added.
2. A new outbound destination category is introduced.
3. Apple Developer ID signing or automated update delivery (Sparkle) is enabled.
4. Remote AI adapter moves beyond local fallback to live provider requests.
