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
- Go to **https://smithery.ai/new** → **Sign in** (GitHub or Google) → complete the publish flow.
- NetMax is a **local stdio** server, so Smithery's **"Local (MCPB Bundle)"** path applies
  (not the URL path, which is for hosted Streamable-HTTP servers).
- **CLI (advanced):**
  ```
  smithery auth login
  smithery mcp publish ./netmax.mcpb -n <your-namespace>/netmax
  ```
- After publishing: **Settings → Verification** for the official-vendor checklist.

### 2. mcp.so
- Go to **https://mcp.so/submit**.
- Paste: **Repository URL** = `https://github.com/mubasharali24428-crypto/netmax`,
  **Name** = `NetMax MCP Server`.
- The free path is all that's needed. The **"$39 one-time"** is an optional upsell
  (instant publish + verified badge) — **do not pay** unless you specifically want the badge.

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
