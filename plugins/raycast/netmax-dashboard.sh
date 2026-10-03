#!/bin/bash
# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title NetMax Dashboard
# @raycast.mode silent
# @raycast.packageName NetMax
# @raycast.description Open the local NetMax web dashboard
# @raycast.icon chart.bar.xaxis

# Opens the dashboard of a locally running NetMax --http server
# (start one with: npx -y @netmax/mcp-server --http).
PORT="${NETMAX_PORT:-8808}"
open "http://127.0.0.1:${PORT}/"
