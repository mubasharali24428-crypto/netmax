# NetMax

> Network diagnostics for AI coding agents. Local-first, honest limits.

[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![npm](https://img.shields.io/npm/v/@netmax/mcp-server)](https://www.npmjs.com/package/@netmax/mcp-server)
[![GitHub stars](https://img.shields.io/github/stars/mubasharali24428-crypto/netmax?style=social)](https://github.com/mubasharali24428-crypto/netmax)
[![Landing page](https://img.shields.io/badge/🌐-landing%20page-2f6f4f)](https://mubasharali24428-crypto.github.io/netmax/)
[![Buy $29](https://img.shields.io/badge/💳-Founding%20License%20%2429-c0392b)](https://mubasharali03.gumroad.com/l/yzkuez)

**Website:** https://mubasharali24428-crypto.github.io/netmax/  
**npm (MCP server):** `npx -y @netmax/mcp-server`  
**macOS app:** `brew tap mubasharali24428-crypto/netmax && brew install --cask netmax`

**14 network-diagnostic tools for AI coding agents.** Run speed tests, DNS ranking, bufferbloat
grading, jitter, packet loss, WiFi diagnostics — all from inside your AI coding agent.

**Honest bandwidth maximizer for macOS.** NetMax squeezes every bit your plan
actually pays for: it measures true single-stream throughput, claims a larger
per-flow share of a *contended* WiFi pipe using N parallel TCP streams
(standard fairness, no tricks), ranks public DNS resolvers by latency, and
grades your connection's bufferbloat on the Waveform A+–F rubric.

## Honest limits — read this first

- **NetMax cannot exceed your ISP cap.** No software can — the cap is enforced
  on the provider's side. Anyone promising "10x your speed" is selling scamware.
- Gains from `turbo`/`boost` appear **only when the pipe is contended** (other
  devices are pulling traffic). On an idle line, baseline is already the plan.
- Router-side QoS caps override everything here; only the router admin or a
  plan upgrade changes those.
- Zero-throughput windows on shared WiFi are real (airtime starvation). NetMax
  reports them as dropouts rather than inventing a flattering percentage.

## MCP Server — use from any AI coding agent (free, MIT)

Install in 10 seconds — works in Claude Code, Cursor, Codex CLI, Gemini, LM Studio, and more:

```bash
npx -y @netmax/mcp-server
```

Then ask your agent to run `full_diagnostics` — it will measure your real network speed, DNS
latency, bufferbloat grade, jitter, packet loss, and WiFi quality in a single call.

**14 tools:** `measure_speed` · `dns_ranking` · `bufferbloat` · `upload_speed` ·
`packet_loss` · `jitter` · `wifi_info` · `download_file` · `eco_bloat` ·
`full_diagnostics` · `diagnostic_summary` · `boost` · `parallel_diagnostics` ·
`session_info`

### Desktop app (macOS)

```bash
brew tap mubasharali24428-crypto/netmax
brew install --cask netmax
```

Or visit the [landing page](https://mubasharali24428-crypto.github.io/netmax/) for the $29
Founding License: menu-bar app with history, scheduled tests, and anomaly detection.

---

## Install & run (Python engine — for developers)

No package install needed — it's plain Python + curl. Any Python 3.10+
works; point `NETMAX_PYTHON` at a specific interpreter if the default
`python3` lacks optional extras (matplotlib for `measure.py` charts,
Tkinter for `netmax_gui.py`):

```bash
export NETMAX_PYTHON=/path/to/python   # optional override
cd ~/netmax
$NETMAX_PYTHON netmax.py full --seconds 10      # or just: python3 netmax.py full --seconds 10
```

Requires: Python 3.10+, `curl`, and network access for live measurements.

## CLI examples

```bash
python3 netmax.py baseline --seconds 8    # single-stream Mbps
python3 netmax.py turbo --streams 6       # parallel-stream share
python3 netmax.py boost --streams 4       # baseline vs turbo, gain %
python3 netmax.py dns                     # rank resolvers by latency
python3 netmax.py bloat --seconds 12      # bufferbloat grade (A+–F)
python3 netmax.py full --seconds 10       # everything + verdict
```

### Diagnostics (v0.4)

```bash
python3 netmax.py upload --seconds 10     # upload speed (Mbps)
python3 netmax.py loss                    # packet-loss percent
python3 netmax.py jitter                  # jitter (ms)
python3 netmax.py wifi                    # RSSI / noise / channel
python3 netmax.py export --fmt csv --out out.csv
python3 netmax.py watch --interval 30     # continuous monitor
```

### GUI

```bash
python3 netmax_gui.py
```

Tkinter desktop app wrapping the CLI; each command runs in an isolated
subprocess so a failed measurement can never take down the UI.

## Tests

385 offline tests in the default suite (network fully mocked — safe to run
anywhere), plus 94 more in the engine_store / bridge suites:

```bash
cd ~/netmax
python3 -m pytest            # engine + GUI + module suites (385)
python3 -m pytest tests/test_netmax.py -v        # engine only
python3 -m pytest test_netmax_gui.py -v          # GUI only
python3 -m pytest desktop/engine_store/test_store.py -q   # SQLite layer (38)
python3 -m pytest desktop/bridge/test_engine_bridge.py -q # bridge (56)
python3 -m ruff check .       # lint gate
```

Swift offline self-checks (LicenseGate, HistoryStore, Timeline, …):

```bash
bash desktop/scripts/run_swift_selftests.sh
```

## Project structure

| Path | Role |
|---|---|
| `netmax.py` | Engine + CLI: `baseline / turbo / boost / dns / bloat / full / upload / loss / jitter / wifi / export / watch` |
| `netmax_gui.py` | Tkinter desktop app wrapping the CLI (progress bar, elapsed counter, export viewer) |
| `netmax_upload.py` | Upload-speed probe module |
| `netmetrics.py` | Packet loss, jitter, WiFi info modules |
| `netmax_export.py` | CSV/JSON export of measurement runs |
| `netmax_watch.py` | Continuous monitor loop |
| `measure.py` | Live measurement run → `results.json` + `results.png` charts + history.json |
| `tests/` | Offline pytest suites for all modules |
| `docs/FEATURE-SPECS.md` | Implementation specs for the v0.4 feature set |
| `PROJECT_LOG.md` | Build log, verified results, debugging notes |

## Implemented in v0.4

`loss`, `jitter`, `wifi`, `upload`, `export`, and `watch` are now real CLI
modes — see Diagnostics above. Remaining ideas live in docs/FEATURE-SPECS.md.
