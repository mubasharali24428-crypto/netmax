---
description: Run NetMax full network diagnostics and explain the verdict
---

Run the `full_diagnostics` MCP tool (defaults are fine), then report in this shape:

- single-stream vs turbo Mbps + headroom %
- fastest DNS resolver and the margin
- bufferbloat grade in plain words (what the user will feel)
- one concrete next step (nothing if the link is healthy)

Rules: never promise more than the ISP cap (the tools report it honestly —
repeat their verdict, don't inflate it). If every probe fails, say the
network path to the test endpoints is down, not that the tools are broken.
