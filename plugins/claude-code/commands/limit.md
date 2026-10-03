---
description: Hold the machine at an exact download speed (soft cap)
---

Run the `boost` MCP tool first to show current headroom. Only then, if the
user confirms a target speed and duration, explain that the soft `limit`
mode paces test downloads only — for a system-wide ceiling the
`strict_limit` tool needs the server running as root (it will say so
itself if not). Never start a strict hold without explicit user
confirmation of the Mbps value: it shapes every app on the machine.
