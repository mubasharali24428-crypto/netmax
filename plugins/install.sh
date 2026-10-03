#!/bin/bash
# Install the NetMax MCP server entry into editor/harness JSON configs.
# Only touches the {"mcpServers": {...}} shape (Cursor, LM Studio, Claude
# Desktop) — Codex/Gemini/DSH differ, so those print manual steps instead.
# Idempotent: re-runs keep one entry and back up any pre-existing file.
# Honors $HOME (sandbox-safe for tests).
set -euo pipefail

ENTRY_KEY="netmax"
ENTRY_JSON='{"command":"npx","args":["-y","@netmax/mcp-server"]}'

merge_into() { # $1 = config path
  local cfg="$1"
  mkdir -p "$(dirname "$cfg")"
  if [ -f "$cfg" ]; then
    cp "$cfg" "$cfg.netmax-bak-$(date +%Y%m%dT%H%M%S)"
  fi
  NETMAX_CFG="$cfg" NETMAX_ENTRY="$ENTRY_JSON" NETMAX_KEY="$ENTRY_KEY" \
    python3 - "$cfg" <<'EOF'
import json, os, sys
path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, ValueError):
    data = {}
if not isinstance(data, dict):
    data = {}
servers = data.get("mcpServers")
if not isinstance(servers, dict):
    servers = {}
    data["mcpServers"] = servers
servers[os.environ["NETMAX_KEY"]] = json.loads(os.environ["NETMAX_ENTRY"])
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
EOF
  echo "wrote $cfg"
}

merge_into "$HOME/.cursor/mcp.json"
merge_into "$HOME/.lmstudio/mcp.json"
merge_into "$HOME/Library/Application Support/Claude/claude_desktop_config.json"

cat <<'EOF'

Manual steps (different config shapes — not automated):
- Codex CLI: ~/.codex/config.toml -> [mcp_servers.netmax] command="npx" args=["-y","@netmax/mcp-server"]
- Gemini: ~/.gemini/config/mcp_config.json -> add netmax to mcpServers (same entry shape as above)
- VS Code Continue: ~/.continue/config.json -> docs at desktop/README.md install matrix
EOF
