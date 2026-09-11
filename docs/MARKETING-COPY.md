# Marketing copy kit — Fiverr gig + Polar funding goal

Status: 2026-09-11. Copy-paste ready. Everything below is honest (no fake reviews, no
overclaiming): it sells the *skill you demonstrably have* — you wired 7 harnesses this week.

---

## 1. Fiverr gig — "I'll set up MCP servers in your coding harness"

### Listing fields

| Field | Value |
|---|---|
| **Title** | I will set up and configure MCP servers for Claude, Cursor, Codex or Gemini |
| **Category** | Programming & Tech → AI Development (or "AI Integrations" if available) |
| **Subcategory** | AI Agents / AI Tools Integration |
| **Skills** | `mcp`, `claude code`, `cursor`, `codex`, `ai agents`, `python`, `node.js` |
| **Search tags** | mcp server setup, claude mcp, cursor mcp, ai agent integration |
| **Price** | From **$25** |

### Description

> I configure Model Context Protocol (MCP) servers in the coding tools you actually use, so your
> AI agents can reach your tools, databases, and APIs directly.
>
> **What you get:**
> - MCP server installed and verified in **Claude Code, Cursor, Codex, Gemini, or VS Code**
> - Working `tools/list` — I prove every tool loads before I hand it over
> - Config files written for your OS (macOS / Windows / Linux)
> - A 1-page setup note per harness so you can reproduce it
>
> **About me:** I'm a full-stack developer who built and published my own MCP server
> (`@netmax/mcp-server`, MIT, 14 tools) — this is not my first rodeo.
>
> **What MCP servers can do (a few examples):** pull network diagnostics, run shell commands,
> query your Postgres/SQLite, search Notion, trigger CI, fetch APIs with retry logic.
>
> If your use case isn't listed, message me — if it's reachable over stdio or HTTP, I can wire it.

### Packages

| Package | Price | Includes | Delivery |
|---|---|---|---|
| **Basic — 1 harness** | **$25** | 1 MCP server in 1 harness, install + verify | 2 days |
| **Standard — 3 harnesses** | **$45** | 3 servers OR 1 server × 3 harnesses, configs + note | 3 days |
| **Premium — Custom build** | **$75** | Custom MCP server written to your spec (Node or Python), packaged for npx, install notes | 5 days |

### FAQ (copy-paste)

- **Which tools do you support?** Claude Code, Cursor, Codex CLI, Gemini CLI, LM Studio, VS Code
  (Continue), and anything with a `mcpServers` JSON/TOML config.
- **Do I need to give you access?** No — you run a one-time `npx` command; I walk you through it
  and read only the config/verification output.
- **What if it breaks after delivery?** 3 days of free follow-up on the same delivery.
- **Why is this a thing?** Because AI agents are only as useful as the tools you give them —
  that's literally what MCP does.

---

## 2. Polar funding goal — "Fund NetMax's Apple Developer account"

Polar (polar.sh) lets open-source projects state a funding goal. This goal is **$99**, it is real,
and it unblocks a concrete, explainable deliverable (notarization). Link the goal from the repo
README + the npm package description + the landing page.

| Field | Value |
|---|---|
| **Goal name** | Fund the Apple Developer account (notarized NetMax v1.0) |
| **Amount** | **$99** |
| **Type** | One-time goal (not recurring) |

### Goal description

> NetMax is a local-first network diagnostics tool for AI coding agents — an MIT-licensed Python
> engine, a published npm MCP server (`@netmax/mcp-server`, 14 tools), and a macOS menu-bar app.
>
> The macOS app is currently ad-hoc signed because Apple's Developer Program costs **$99/yr**, and
> this project is pre-revenue. Notarization removes the "unidentified developer" warning for every
> user who installs the DMG.
>
> **This goal funds exactly that: the $99/year Apple Developer account.** When it's funded, the
> build gets notarized, the release is re-signed in place, and every backer is listed in
> THANKS.md (name or handle, your choice). Founding Licenses (paid beta keys) are a separate offer
> on the landing page — this goal is for people who'd rather donate than buy.
>
> **Transparency:** if the goal is overfunded, the excess goes to the notarization renewal fee for
> year 2. If the project dies before renewal, unspent funds go to the next backer-approved
> deliverable.

### Reward tiers (simple)

| Tier | Amount | Reward |
|---|---|---|
| Supporter | $5 | Shout-out in THANKS.md |
| Patron | $20 | THANKS.md + priority access to the notarized build |
| Sponsor | $50 | THANKS.md + sponsor link in the desktop app's About dialog |

---

## 3. Where each thing goes (checklist)

- [ ] Fiverr gig live → paste the Homebrew line + npm link in your gig's "About"
- [ ] Polar goal created → add badge to `README.md` + `desktop/README.md` + landing page footer
- [ ] Landing page buy-button URL (`__LEMONSQUEEZY_BUY_URL__`) → real Lemon Squeezy checkout URL
- [ ] Landing page refund email (`netmax@proton.me`) → your real support address

## 4. The honest rule that keeps all of this clean

No fake reviews, no astroturfed testimonials, no "97% satisfaction" invented numbers. If you use a
testimonial it must be real (screenshot-able). This matches NetMax's core positioning, and it's
also just the durable way to sell software.