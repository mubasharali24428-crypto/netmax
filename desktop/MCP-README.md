# NetMax MCP Server

Exposes NetMaxDesktop network diagnostics as MCP (Model Context Protocol) tools
that AI coding agents can call directly.

## Zero changes to your app

The MCP server calls the **same Python engine scripts** that the Swift GUI uses
via `engine_bridge.py`. Your app, its data, its running state, its daemons —
**nothing is modified**.

## 11 Tools exposed

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
## Run standalone

```bash
cd /Users/user/netmax-app/desktop
node netmax-mcp-server.mjs
```

Then connect any MCP client (Claude Code, Cursor, etc.) via stdio or HTTP.

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
                                (stdio transport)         (same netmax.py GUI uses)
```

The MCP server is a thin bridge — it translates MCP tool calls into
`engine_bridge.py run <mode>` commands, exactly like the Swift GUI does.
