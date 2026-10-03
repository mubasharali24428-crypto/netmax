#!/bin/bash
# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title NetMax Quick Check
# @raycast.mode compact
# @raycast.packageName NetMax
# @raycast.description Baseline speed + DNS ranking via the NetMax engine
# @raycast.icon gauge.with.dots.needle.bottom.50percent

# Engine location: NETMAX_ROOT wins, else the repo checkout holding this file.
ROOT="${NETMAX_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
PY="${NETMAX_PYTHON:-/usr/bin/python3}"
if [ ! -f "$ROOT/netmax.py" ]; then
  echo "NetMax engine not found (set NETMAX_ROOT). Expected: $ROOT/netmax.py"
  exit 1
fi
"$PY" "$ROOT/netmax.py" baseline --seconds 8 2>&1 | tail -2
"$PY" "$ROOT/netmax.py" dns 2>&1 | tail -7
