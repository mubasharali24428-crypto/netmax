import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const desktop = dirname(fileURLToPath(import.meta.url));
const repo = dirname(desktop);
const serverPath = join(desktop, "netmax-mcp-server.mjs");

test("ai_analyze uses MCP history restrictions and still accepts inline JSON", async (t) => {
  const work = await mkdtemp(join(tmpdir(), "netmax-mcp-history-"));
  const secretPath = join(work, "outside.jsonl");
  await writeFile(secretPath, '{"mbps":999}\n');

  const client = new Client({ name: "netmax-history-boundary-test", version: "1.0.0" });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverPath],
    cwd: desktop,
    env: {
      ...process.env,
      NETMAX_PYTHON: join(repo, ".venv", "bin", "python3"),
      NETMAX_SLACK_WEBHOOK: "",
    },
    stderr: "pipe",
  });
  await client.connect(transport);
  t.after(async () => {
    await client.close().catch(() => {});
    await rm(work, { recursive: true, force: true });
  });

  const outsideHistory = await client.callTool({
    name: "ai_analyze",
    arguments: {
      analysis: "forecast",
      input: "{}",
      history_path: secretPath,
    },
  });
  assert.equal(outsideHistory.isError, true);
  assert.match(outsideHistory.content[0].text, /canonical NetMaxDesktop history/);

  const atPathInput = await client.callTool({
    name: "ai_analyze",
    arguments: { analysis: "forecast", input: `@${secretPath}` },
  });
  assert.equal(atPathInput.isError, true);
  assert.match(atPathInput.content[0].text, /not allowed for MCP/);

  const inline = await client.callTool({
    name: "ai_analyze",
    arguments: {
      analysis: "explain",
      input: JSON.stringify({ diagnostics: { mbps: 40 } }),
    },
  });
  assert.equal(inline.isError, undefined);
  assert.match(inline.content[0].text, /^STATUS: OK/);
});
