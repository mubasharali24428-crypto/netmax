# NetMax MCP Server

Exposes NetMaxDesktop network diagnostics as MCP (Model Context Protocol) tools
that AI coding agents can call directly.

## Zero changes to your app

The MCP server calls the **same Python engine scripts** that the Swift GUI uses
via `engine_bridge.py`. Your app, its data, its running state, its daemons —
**nothing is modified**.

## 17 Tools exposed

| Tool | What it does |
|---|---|---|
| `mcp__netmax__measure_speed` | Speed test (baseline/turbo/boost, 1-50 streams) |
| `mcp__netmax__dns_ranking` | Rank Cloudflare/Google/Quad9 by latency |
| `mcp__netmax__bufferbloat` | Grade latency-under-load A+ through F |
| `mcp__netmax__upload_speed` | Upload speed in Mbps |
| `mcp__netmax__packet_loss` | Packet loss percentage |
| `mcp__netmax__jitter` | Jitter measurement (ms) |
| `mcp__netmax__wifi_info` | RSSI, noise, channel from system profiler |
| `mcp__netmax__download_file` | Multi-stream accelerated download |
| `mcp__netmax__eco_bloat` | Lightweight bloat estimate (~100 KB) |
| `mcp__netmax__full_diagnostics` | All-in-one health check |
| `mcp__netmax__diagnostic_summary` | Quick overview (speed+DNS+bloat) |
| `mcp__netmax__boost` | Baseline + turbo + gain % headroom |
| `mcp__netmax__parallel_diagnostics` | All test concurrently in one call |
| `mcp__netmax__session_info` | Server uptime, call count, PID |
| `mcp__netmax__strict_limit` | System-wide speed ceiling via dnctl+pf (macOS, needs server as root; ≤150 s) |
| `mcp__netmax__ai_analyze` | Analyze supplied measurements; no measurement or system changes |
| `mcp__netmax__list_analyses` | List supported analysis names |

## Remote AI privacy

`ai_analyze` does not grant remote-provider consent. Remote AI is off by
default and can only be enabled in the desktop app under **Settings → Remote AI
Privacy → Allow remote AI analysis**. MCP has no argument or environment
override for this preference. When remote egress is denied, an analysis may
return a local result labeled `source: local` instead of failing the MCP call.

The provider boundary accepts only a versioned allowlist of measurement
aggregates; it does not send arbitrary prompts, raw history rows, SSID/BSSID,
hostnames, IP addresses, or paths. See the
[`remote-AI data-flow contract`](../docs/privacy/remote-ai-data-flow.md) for
the exact fields, provider metadata, local behavior, and current limitation:
existing analyzers are not yet adapted to send the approved remote payload, so
they currently use local fallback even when consent is enabled. Remote MCP
transport configuration is separate from remote-AI consent.

## Kernel traffic shaping (`strict_limit`) & recovery

The `strict_limit` tool enforces a system-wide download bandwidth ceiling via macOS
kernel packet filtering (`pf`) and dummynet pipes (`dnctl`).

- **Privilege requirement**: Controlling kernel packet filters requires the MCP
  server to execute with root privileges (`sudo`).
- **Owner locking & safety**: NetMax acquires an exclusive `fcntl.flock` on
  `/var/run/netmax-shaping.lock`, allocates an unused pipe ID (20000–29999), and
  atomically records the session in `/var/run/netmax-shaping/owner.json` (mode 0600).
- **Transactional rollback**: Failures during rule injection automatically roll back
  allocated pipes and restore prior `pf` state.
- **Manual operator recovery**: If the server process is killed abruptly (SIGKILL),
  lingering shaping rules can be manually flushed by the operator:
  ```bash
  sudo dnctl -q pipe delete <pipe_id>
  sudo pfctl -a netmax_strict_limit -F all
  ```

## Resource budgets & concurrency bounds

The MCP server enforces strict resource limits before spawning subprocesses:
- **Stream-seconds budget**: At most 300 aggregate stream-seconds per call.
- **Wall-clock timeout**: At most 180 seconds execution time per operation.
- **Concurrency bounds**: At most 2 active measurement jobs process-wide, and at
  most 1 active measurement job per MCP session. Busy responses are returned if saturated.
- **Subprocess reaping**: On request cancellation or client disconnection, the server
  sends SIGTERM, waits up to 2 seconds, and escalates to SIGKILL to prevent orphaned jobs.

## Download file controls (`download_file`)

The `download_file` tool accelerates downloads using parallel streams with strict bounds:
- **SSRF & scheme restrictions**: Accepts only public HTTPS URLs; validates DNS answers
  before connecting and rejects private, loopback, link-local, and multicast addresses.
- **Size & redirect bounds**: Bounded to at most 5 redirects and a maximum file size of 1 GiB.
- **Output path confinement**: Output paths are constrained to safe authorized directories
  with sanitized basenames. Arbitrary filesystem or system directory writes are rejected.
## Run standalone

```bash
cd /Users/user/netmax-app/desktop
node netmax-mcp-server.mjs
```

Then connect any MCP client (Claude Code, Cursor, etc.) via stdio or HTTP.

## Web MCP (Streamable HTTP) — new in 1.0.4

Same server, web transport — no stdio wiring needed. Point any MCP client
that supports remote servers (Claude, Cursor, DSH, inspectors) at a URL:

```bash
npx -y @netmax/mcp-server@latest --http          # http://127.0.0.1:8808/mcp
NETMAX_PORT=9000 npx -y @netmax/mcp-server --http # custom port
```

Client config (Claude / Cursor / DSH remote MCP):

```json
{ "url": "http://127.0.0.1:8808/mcp" }
```

- Default bind is **loopback** — the engine measures *this machine's* network,
  so hosting it remotely would measure the datacenter's pipe, not yours.
- `NETMAX_HOST=0.0.0.0` opens it to the LAN (pair with the token).
- `NETMAX_TOKEN=<secret>` requires `Authorization: Bearer <secret>` on every
  request (401 otherwise). Required when the bind is not loopback — the
  server refuses to start off-loopback without it.

## Team hardening: TLS + dashboard

- `NETMAX_TLS_CERT` + `NETMAX_TLS_KEY` (PEM paths) switch the transport to
  HTTPS — bring your own cert (mkcert / internal CA); clients must trust it.
  Set only one and the server refuses to start (exit 2).
- `GET /` (or `/status`) is a plain-text dashboard: version, transport, auth
  mode, uptime, tool count/calls, engine path. Same bearer gate as MCP.

## Team fleet view: multiple Macs, one endpoint

- `NETMAX_FLEET_ALLOWLIST='{"desk":"https://mac1:8808","mini":"https://mac2:8808"}'`
  makes `GET /fleet` return every peer's dashboard excerpt as JSON
  (`{peers:[{name, ok, status}]}`, `name` is the alias). Aliases match
  `[a-z][a-z0-9_-]{0,31}`; at most 32 peers; origins must be exact HTTPS
  origins (no credentials, path, query, or fragment). Unreachable peers
  report `ok: false` inline.
- Optional `NETMAX_FLEET_TOKENS='{"desk":"token-for-desk"}'` gives each alias
  its own bearer token; a token is only ever sent to its own peer, and a
  token for an unknown alias is a configuration error.
- Requests are HTTPS-only, resolve DNS immediately before connecting and
  refuse private/loopback/link-local/reserved addresses, pin the validated
  address with normal certificate/hostname checks, never follow redirects,
  and cap time at 5 s and body at 16 KiB. Invalid configuration makes zero
  peer requests and is reported as `error`. The legacy `NETMAX_FLEET` and
  `NETMAX_FLEET_TOKEN` variables are ignored.
- `GET /fleet/board` renders the same data as a self-refreshing status
  page (no client JS); an empty or invalid fleet explains the env var instead of 404ing.

## Failure alerts: Slack webhook

- `NETMAX_SLACK_WEBHOOK=<incoming-webhook-URL>` posts one line per FAILED
  tool call (`mode` + first error line). Unset = no alerting, zero overhead.
- Rate-limited to 1 post per 5 min (in-memory; resets on restart). A dead or
  malformed webhook never breaks a tool call — fire-and-forget by design.

## Wire into DSH

Already done! The web profile at `~/.dsh/profiles/web/cordis.patch.yml` has
the MCP client entry. After restarting DSH, the agent will have access to all
NetMax tools.

## Debug

```bash
npx @modelcontextprotocol/inspector node /Users/user/netmax-app/desktop/netmax-mcp-server.mjs
```

## Architecture

```
AI Agent (DSH)  →  MCP Client Plugin  →  netmax-mcp-server.mjs  →  Python engine
                     (stdio, or Streamable HTTP with --http)   (same netmax.py GUI uses)
```

The MCP server is a thin bridge — it translates MCP tool calls into
`engine_bridge.py run <mode>` commands, exactly like the Swift GUI does.
