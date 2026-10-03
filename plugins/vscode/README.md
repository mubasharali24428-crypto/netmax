# NetMax Trends — VS Code extension (v1, read-only + one runner)

Two commands: `NetMax: Show Trends` (history webview) and
`NetMax: Run Quick Check` (8 s baseline, result panel, not saved to
history). Zero dependencies (no `node_modules`).

## Data sources (first hit wins)

1. macOS app SQLite: `~/Library/Application Support/NetMaxDesktop/history.db`
   (queried via the system `sqlite3` CLI — no driver needed)
2. Same dir `history.jsonl` fallback (malformed lines skipped)
3. Otherwise an empty state naming what to run first

v1 never spawns the engine except through Run Quick Check, and never
touches the network itself. The runner needs an engine location:
`netmax.engineRoot` setting (folder holding `netmax.py`) or `NETMAX_ROOT`,
plus optional `netmax.pythonPath` / `NETMAX_PYTHON`.

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
