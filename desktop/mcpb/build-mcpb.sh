#!/bin/bash
# Build the NetMax MCP Bundle (.mcpb) for Smithery / Claude Desktop.
# Usage: ./desktop/mcpb/build-mcpb.sh   (from anywhere; paths are relative to repo)
set -euo pipefail

DESKTOP="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$DESKTOP/.." && pwd)"
VERSION="$(python3 -c "import json;print(json.load(open('$DESKTOP/package.json'))['version'])")"
STAGE="$(mktemp -d /tmp/netmax-mcpb.XXXXXX)"

echo "== Staging bundle (v$VERSION) in $STAGE =="
cp "$DESKTOP/netmax-mcp-server.mjs" "$DESKTOP/package.json" "$STAGE/"
cp "$DESKTOP/README.md" "$STAGE/" 2>/dev/null || true
cp "$DESKTOP/MCP-README.md" "$STAGE/" 2>/dev/null || true
mkdir -p "$STAGE/engine" "$STAGE/bridge"
cp "$DESKTOP"/engine/*.py "$STAGE/engine/"
cp "$DESKTOP/bridge/engine_bridge.py" "$STAGE/bridge/"
cp "$DESKTOP/mcpb/manifest.json" "$STAGE/manifest.json"

echo "== Vendoring production dependencies =="
(cd "$STAGE" && npm install --omit=dev --omit=peer --silent)

echo "== Packing =="
npx -y @anthropic-ai/mcpb pack "$STAGE" "$DESKTOP/netmax-$VERSION.mcpb"
rm -rf "$STAGE"
echo "== Done: $DESKTOP/netmax-$VERSION.mcpb =="
