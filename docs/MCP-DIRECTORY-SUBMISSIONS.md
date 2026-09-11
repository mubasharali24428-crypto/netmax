# MCP Directory Submissions — NetMax

**Status of this doc:** verified 2026-09-11. Everything here is a copy-paste kit for the
**browser steps only you can do** (each directory gates on a login I can't perform).

---

## Canonical metadata (paste into every form)

| Field | Value |
|---|---|
| **Name** | NetMax MCP Server |
| **npm package** | `@netmax/mcp-server` |
| **GitHub** | https://github.com/mubasharali24428-crypto/netmax |
| **Tagline** | 14 network-diagnostic tools for AI coding agents |
| **Description** | NetMax gives AI coding agents real network measurements — speed test, DNS ranking, bufferbloat, WiFi signal, jitter, packet loss, and multi-stream download. Local-first, honest limits (never promises more than your ISP cap). |
| **Tags** | `mcp`, `network`, `diagnostics`, `speed-test`, `dns`, `bufferbloat`, `wifi`, `ai`, `coding` |
| **Transport** | stdio |
| **Install** | `npx -y @netmax/mcp-server` |
| **License** | MIT |
| **Runtime** | Node ≥ 18 **plus** Python 3.10+ and `curl` |

---

## The four directories

| # | Directory | URL | Mechanism | Login needed? | Cost |
|---|---|---|---|---|---|
| 1 | **Smithery** | https://smithery.ai/new | Web publish flow (sign in first) | ✅ Yes (GitHub/Google) | Free |
| 2 | **mcp.so** | https://mcp.so/submit | Repository-URL form | Likely (Sign In) | Free — **skip the $39 upsell** |
| 3 | **Glama** | https://glama.ai/mcp/servers → **Add Server** | Web "Add Server" | Likely | Free |
| 4 | **pulse.mcp.so** | https://pulse.mcp.so | ⚠️ **Unreachable — treat as defunct** | — | — |

> **Note:** the URL `smithery.ai/register-server` is **404** — do not use it. The real entry point is
> https://smithery.ai/new (or the **Publish** button on the homepage).

### 1. Smithery
- NetMax is a **local stdio** server, so Smithery's **"Local (MCPB Bundle)"** path applies
  (not the URL path, which is for hosted Streamable-HTTP servers).
- **The bundle is ready and smoke-tested.** Build it with:
  ```
  ./desktop/mcpb/build-mcpb.sh      # → desktop/netmax-<version>.mcpb (manifest in desktop/mcpb/)
  ```
  Current artifact: `desktop/netmax-1.0.3.mcpb` (3.1 MB, manifest valid, `initialize` +
  `tools/list` = 14 tools verified via MCPB unpack round-trip on 2026-09-11).
- **CLI publish (verified syntax):**
  ```
  npx -y @smithery/cli auth login                              # interactive device flow
  npx -y @smithery/cli namespace                               # check your namespace
  npx -y @smithery/cli mcp publish ./desktop/netmax-1.0.3.mcpb -n <your-namespace>/netmax
  ```
- Web alternative: **https://smithery.ai/new** → Sign in → "Local (MCPB Bundle)" → upload the `.mcpb`.
- After publishing: **Settings → Verification** for the official-vendor checklist.
- Note: `smithery.ai/register-server` is **404** — do not use it.

### 2. mcp.so — ✅ DONE (2026-09-11)
- Submitted **free** via GitHub issue: https://github.com/chatmcp/mcpso/issues/4063
  ("MCP server: NetMax MCP Server", title format: `Add MCP server: <name>`).
- The `$39` panel on `mcp.so/submit` is only an upsell (instant publish + verified badge +
  dofollow link). No payment was made — the GitHub issue is the official free path.

### 3. Glama
- Go to **https://glama.ai/mcp/servers** and click **Add Server**.
- **Verified 2026-09-11:** a Glama search for `netmax` returns only *NetMap* and *Netmex* — **NetMax is
  not yet indexed**, so this step is required (Glama does not pick it up automatically).

### 4. pulse.mcp.so
- **Unreachable** — both `https://pulse.mcp.so` and `https://pulse.mcp.so/servers` fail to load.
- Treat as defunct and drop it from the list.

---

## Bonus — official MCP Registry (the canonical upstream)

Many aggregators ingest the official registry, so publishing there is the highest-leverage single
step. The required artifacts are **already in this repo**:
- `desktop/package.json` → `"mcpName": "io.github.mubasharali24428-crypto/netmax"`
- `server.json` (repo root) → the registry manifest

Publish (per https://modelcontextprotocol.io/registry/quickstart):
```
mcp-publisher login github     # device-code flow (interactive)
mcp-publisher publish
```
The `mcpName` in `package.json` **must match** `name` in `server.json`, and the published npm package
must contain `mcpName` — so publish the npm package (already done at v1.0.3) before the registry step.
