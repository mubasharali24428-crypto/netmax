# NetMax Claude Code plugin

Adds `/diagnose`, `/speed`, and `/limit` commands backed by the NetMax MCP
server (`npx -y @netmax/mcp-server`, 15 tools). The plugin is prompts-only —
it assumes the server from the main install matrix (`desktop/README.md`).

Install: copy `plugins/claude-code` into your Claude Code plugins directory
(see current Claude Code docs for the path — it moves between releases),
or point the plugin installer at this folder.
