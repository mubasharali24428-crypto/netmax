# NetMax Trends — VS Code extension (v1, read-only)

`NetMax: Show Trends` opens a static webview with an SVG Mbps-over-time
chart plus the latest runs. Zero dependencies (no `node_modules`).

## Data sources (first hit wins)

1. macOS app SQLite: `~/Library/Application Support/NetMaxDesktop/history.db`
   (queried via the system `sqlite3` CLI — no driver needed)
2. Same dir `history.jsonl` fallback (malformed lines skipped)
3. Otherwise an empty state naming what to run first

v1 never spawns the engine and never touches the network.

## Install (local, no marketplace)

```bash
cp -r plugins/vscode ~/.vscode/extensions/netmax-trends-1.0.7
# then reload VS Code and run: NetMax: Show Trends
```

Match the folder version to `desktop/package.json` (a pytest guard fails
the suite on drift — see `tests/test_plugins.py`).

## Test

```bash
node --test plugins/vscode/test/trends.test.js   # explicit file form —
# bare `node --test <dir>` mis-resolves on some Node versions
```
