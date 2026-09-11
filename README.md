# NetMax

> Network diagnostics for AI coding agents. Local-first, honest limits.
> **Website:** https://mubasharali24428-crypto.github.io/netmax/

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

## Install & run

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

68 offline tests (network fully mocked — safe to run anywhere):

```bash
cd ~/netmax
python3 -m pytest            # engine + GUI suites
python3 -m pytest tests/test_netmax.py -v        # engine only
python3 -m pytest tests/test_netmax_gui.py -v    # GUI only
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
