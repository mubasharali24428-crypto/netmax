# NetMax Landing Page Claims & Call-to-Action (CTA) Audit

**Task:** C-01 (Align threat model and operator/privacy documentation)  
**Document:** `docs/product/landing-claims.md`  
**Target:** `landing/index.html` (commit baseline `cec92de`)  
**Prerequisites:** Gate B (B-01 through B-13) complete  
**Direct Gate D Dependencies:** D-04-DEMO, D-04-TESTIMONIALS, D-04-SUBSCRIPTION, D-04-OPERATIONS, D-04-CONSENT, D-04-LEGAL, D-04-TEST  

---

## 1. Executive Summary

This inventory audits every visible product claim, headline, metric, testimonial, legal assertion, and call-to-action (CTA) present in `landing/index.html`. 

To establish absolute truthfulness and eliminate deceptive patterns (per audit finding `F-018` and Gate D specifications):
1. **Real product capabilities, install commands, verified external links, and the genuine $29 Founding License are kept (`KEEP`).**
2. **Fabricated social proof, simulated live analytics, fake operational status, unsupported recurring subscription tiers, simulated cookie tracking, and dead legal fragment links are marked for immediate removal (`REMOVE`).**
3. **Interactive preview elements are marked to be frozen and labeled as illustrative samples (`FREEZE / LABEL DEMO`).**

---

## 2. External Destinations Verification

Each external target referenced in `landing/index.html` was verified against live repository and package registry metadata:

| Destination URL / Identifier | Context / Location | Evidence & Verification Status | Verdict |
| :--- | :--- | :--- | :---: |
| `https://github.com/mubasharali24428-crypto/netmax` | Header badge, footer | Official upstream Git repository; active tracking branch | **KEEP** |
| `https://github.com/mubasharali24428-crypto/netmax/releases` | Install section DMG download | Official GitHub releases page for compiled DMG builds | **KEEP** |
| `https://github.com/mubasharali24428-crypto/netmax/blob/main/LICENSE` | Footer license link | Points directly to MIT license file in repository root | **KEEP** |
| `https://www.npmjs.com/package/@netmax/mcp-server` | Hero & footer npm link | Verified published npm package (package.json v1.0.7) | **KEEP** |
| `https://mubasharali03.gumroad.com/l/yzkuez` | Pricing section buy CTA | Active Gumroad product link for NetMax Founding License ($29) | **KEEP** |
| `brew tap mubasharali24428-crypto/netmax && brew install --cask netmax` | Install section code block | Homebrew tap and cask formula configuration | **KEEP** |
| `npx -y @netmax/mcp-server` | Hero & install code block | Verified npx command executing published MCP server package | **KEEP** |
| `mubasharalikhowaja@proton.me` | Footer contact / refunds | Dedicated developer support email for refund requests | **KEEP** |

---

## 3. Inventory of Visible Claims & Headlines

| # | Section / Element | Exact Text / Claim | Evidence & Implementation Reality | Verdict | Implementation Assignment |
| :- | :--- | :--- | :--- | :-: | :--- |
| **1** | Hero (`<section class="hero">`) | *"Network diagnostics for AI coding agents."* | Core project architecture; MCP server exposes 17 diagnostic tools to Claude, Cursor, Codex, etc. | **KEEP** | Retain |
| **2** | Hero subhead | *"Honest bandwidth maximizer for macOS. Measures single-stream throughput, parallel TCP fairness, ranks DNS, grades bufferbloat."* | Matches verified engine modes: `baseline`, `turbo`, `dns`, `bloat`. Accurately cites TCP fairness. | **KEEP** | Retain |
| **3** | Feature Card | *"Local-first: Everything runs on your machine. No cloud, no accounts, no telemetry. Your measurements never leave your Mac."* | Matches threat model. Measurements stay local; optional remote AI requires explicit user toggle in Desktop Settings (`allowRemoteAI`) and sends only 11 safe metrics. | **KEEP** | Retain (Clarified in threat model) |
| **4** | Feature Card | *"Honest limits: NetMax grades against your real ISP cap. It won't tell you '1 Gbps' on a 100 Mbps plan — ever."* | Core design philosophy; engine explicitly reports bottleneck limits and dropouts rather than inflating rates. | **KEEP** | Retain |
| **5** | Feature Card | *"Agent-native: Your AI agent calls the tools directly in your terminal workflow. The menu bar keeps watch between commands."* | MCP server runs via stdio or HTTP; menu bar application monitors WiFi and schedule events. | **KEEP** | Retain |
| **6** | Feature Card | *"Zero bloat: 32 KB Node.js server + 76 KB Python engine — pure stdlib, no dependencies, no Docker, no containers."* | Verified: `netmax-mcp-server.mjs` is lightweight JS; Python engine uses standard library + system curl/ping. | **KEEP** | Retain |
| **7** | Tools section | *"15 tools"* / Tool chips | Understates current count: MCP server exposes **17 tools** (`measure_speed`, `dns_ranking`, `bufferbloat`, `upload_speed`, `packet_loss`, `jitter`, `wifi_info`, `download_file`, `eco_bloat`, `full_diagnostics`, `diagnostic_summary`, `boost`, `parallel_diagnostics`, `session_info`, `strict_limit`, `ai_analyze`, `list_analyses`). | **REVISE** | Update count from 15 to 17 tools |
| **8** | FAQ (`#faq`) | *"Is this a scam? No. 15 tools, 480 passing tests, MIT-licensed engine, published npm package..."* | Test count is outdated (current test suite has >1,000 passing tests across engine, bridge, store, and MCP suites). | **REVISE** | Update tool count to 17 and test count to current suite |
| **9** | Pricing (`#buy`) | *"The Founding License — $29. One-time payment. Pro tier access. Funds the Apple Developer account that notarizes the build..."* | Matches Gumroad listing and documented release roadmap (F-015 / C-07). Transparently states notarization status. | **KEEP** | Retain |
| **10** | Live Dashboard Preview (`#dashboard-preview`) | Live simulated charts, throughput counters, and animated progress bars | Data is synthetically generated via `setInterval` in frontend JS; misleadingly appears as active local measurement. | **FREEZE / LABEL DEMO** | **D-04-DEMO**: Freeze animations, clearly label as *"Illustrative Sample Preview"*, remove timers. |
| **11** | Testimonials (`#testimonials`) | Quotes from *"Alex K., Network Engineer"*, *"Sarah M., DevOps Lead"*, *"James R., Solo Dev"* | Unattributed fabricated social proof violating truthfulness standards (`F-018`). | **REMOVE** | **D-04-TESTIMONIALS**: Remove entire `#testimonials` section. |
| **12** | Subscription Plans (`#subscription`) | Tiered pricing cards: *"Free ($0/mo)"*, *"Pro ($9/mo)"*, *"Team ($29/mo)"* with *"Start Free Trial"* and *"Contact Sales"* buttons | Fabricated tiers. Product is sold solely as a $29 one-time Founding License on Gumroad; there is no recurring billing or trial backend. | **REMOVE** | **D-04-SUBSCRIPTION**: Remove entire `#subscription` section. |
| **13** | Usage Analytics (`#analytics`) | *"142 Total Tests Run"*, *"99.2% Uptime"*, *"42.7 Avg Throughput"*, *"12ms Avg Latency"* | Hardcoded synthetic metrics presented as the visitor's real performance. | **REMOVE** | **D-04-OPERATIONS**: Remove entire `#analytics` section. |
| **14** | Operational Status | *"All systems operational — Last checked: Today at..."* | Fake status badge for a local-first utility that operates without central cloud infrastructure. | **REMOVE** | **D-04-OPERATIONS**: Remove operational status block. |
| **15** | Backup & Recovery (`#backupRecovery`) | Buttons: *"Export My Data"*, *"Restore from Backup"*, *"View History"*, *"Rollback"* triggering success toasts | Non-operational browser buttons simulating cloud account actions that do not exist on a static website. | **REMOVE** | **D-04-OPERATIONS**: Remove `#backupRecovery` section and toast triggers. |
| **16** | Cookie Banner & Consent Panel (`#cookieBanner`, `#consentPanel`) | *"We use cookies..."* with toggles for Analytics, Marketing, Third-party data sharing | Deceptive consent UI. The static landing site does not set optional tracking or third-party marketing cookies. | **REMOVE** | **D-04-CONSENT**: Remove cookie banner and consent modal; retain standard static privacy disclosure. |
| **17** | Footer Legal Links | `#privacy`, `#terms`, `#cookies`, `#gdpr`, `#ccpa`, `#data`, `#delete` | Dead in-page anchor fragments with no corresponding sections or backend actions (e.g. no account to delete). | **REMOVE** | **D-04-LEGAL**: Remove dead fragment links; link only to valid project documentation. |
| **18** | Changelog (`#changelog`) | Entries for *"v2.0.0 — UI/UX Overhaul (January 2026)"* and *"v1.5.0 — AI Diagnostics (December 2025)"* | Inaccurate release history contradicting semver tags in `desktop/package.json` (v1.0.7) and `server.json`. | **REMOVE / REVISE** | Align with actual version tags or remove speculative dates. |

---

## 4. Calls-to-Action (CTA) Decision Matrix

| CTA Text | Container / Element | Target Action / Link | Verification Evidence | Decision |
| :--- | :--- | :--- | :--- | :---: |
| **"Get the desktop app — $29"** | Hero primary button | Anchor `#buy` | Scrolls to verified Founding License section | **KEEP** |
| **"Try the MCP server (free)"** | Hero ghost button | Anchor `#install` | Scrolls to free `npx` install instructions | **KEEP** |
| **"Start Diagnostics"** | Dashboard preview | Anchor `#install` | Will point to installation guide | **KEEP** (under D-04-DEMO) |
| **"Buy Founding License"** | Pricing card | `https://mubasharali03.gumroad.com/l/yzkuez` | Verified Gumroad purchase link | **KEEP** |
| **"Get started"** | Pricing card | Anchor `#install` | Scrolls to install section | **KEEP** |
| **"Download the DMG"** | Install section note | `https://github.com/mubasharali24428-crypto/netmax/releases` | Verified GitHub releases destination | **KEEP** |
| **"Start Free Trial"** | Pro subscription card | Button with toast handler | Non-operational simulated trial | **REMOVE** (D-04-SUBSCRIPTION) |
| **"Contact Sales"** | Team subscription card | Button with toast handler | Non-operational simulated sales contact | **REMOVE** (D-04-SUBSCRIPTION) |
| **"Export My Data"** | Backup section | Button `#exportDataBtn` | Simulated fake export toast | **REMOVE** (D-04-OPERATIONS) |
| **"Restore from Backup"** | Backup section | Button `#restoreDataBtn` | Simulated fake restore toast | **REMOVE** (D-04-OPERATIONS) |
| **"Rollback"** | Backup section | Button `#rollbackBtn` | Simulated fake rollback toast | **REMOVE** (D-04-OPERATIONS) |
| **"Accept All" / "Reject All"** | Cookie banner | Button `#cookieAccept` / `#cookieReject` | Deceptive tracking consent controls | **REMOVE** (D-04-CONSENT) |

---

## 5. Execution Instructions for Gate D (D-04 Children)

The child tasks of Gate D must implement the verdicts above in strict serial sequence:
1. **D-04-DEMO**: Replace animated `setInterval` loop with static, frozen metrics clearly labeled *"Illustrative sample data"*.
2. **D-04-TESTIMONIALS**: Delete lines 768–786 (`#testimonials` section and styles).
3. **D-04-SUBSCRIPTION**: Delete lines 889–932 (`#subscription` section and styles).
4. **D-04-OPERATIONS**: Delete lines 934–960 (`#analytics`), lines 862–887 (`#backupRecovery`), operational status indicators, and toast handlers for deleted buttons.
5. **D-04-CONSENT**: Delete lines 806–847 (`#cookieBanner` and `#consentPanel`).
6. **D-04-LEGAL**: Remove dead footer fragment links (`#cookies`, `#gdpr`, `#ccpa`, `#data`, `#delete`).
7. **D-04-TEST**: Execute Playwright + `@axe-core/playwright` accessibility and link validation suite.
