import assert from "node:assert/strict";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const desktop = dirname(fileURLToPath(import.meta.url));
const engine = join(desktop, "engine");
const serverPath = join(desktop, "netmax-mcp-server.mjs");
const python = join(dirname(desktop), ".venv", "bin", "python3");

test("ai_analyze stays local when remote consent is false", async (t) => {
  const work = await mkdtemp(join(tmpdir(), "netmax-mcp-ai-egress-"));
  const wrapper = join(work, "python-deny-egress.py");
  const attemptedRequest = join(work, "provider-request-attempted");
  await writeFile(wrapper, `#!${python}
import os
import runpy
import sys

engine = os.environ["NETMAX_TEST_ENGINE"]
sys.path.insert(0, engine)
import netmax_ai_provider

netmax_ai_provider._read_remote_ai_consent = lambda: False

def record_provider_request(*_args, **_kwargs):
    with open(os.environ["NETMAX_TEST_PROVIDER_MARKER"], "w") as marker:
        marker.write("attempted")
    raise AssertionError("remote provider transport must not be reached")

netmax_ai_provider.urlopen = record_provider_request
args = sys.argv[1:]
if args and args[0] == "-B":
    args = args[1:]
target, *engine_args = args
sys.argv = [target, *engine_args]
runpy.run_path(target, run_name="__main__")
`);
  await chmod(wrapper, 0o700);

  const client = new Client({ name: "netmax-ai-egress-test", version: "1.0.0" });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverPath],
    cwd: desktop,
    env: {
      ...process.env,
      NETMAX_PYTHON: wrapper,
      NETMAX_TEST_ENGINE: engine,
      NETMAX_TEST_PROVIDER_MARKER: attemptedRequest,
      NETMAX_AI_API_KEY: "test-secret-not-for-egress",
      NETMAX_AI_BASE: "https://provider.example/v1/chat/completions",
      NETMAX_ALLOW_REMOTE_AI: "1",
      NETMAX_SLACK_WEBHOOK: "",
    },
    stderr: "pipe",
  });
  await client.connect(transport);
  t.after(async () => {
    await client.close().catch(() => {});
    await rm(work, { recursive: true, force: true });
  });

  const { tools } = await client.listTools();
  const aiTool = tools.find((tool) => tool.name === "ai_analyze");
  assert.ok(aiTool);
  assert.deepEqual(Object.keys(aiTool.inputSchema.properties).sort(), [
    "analysis", "history_path", "input", "pretty",
  ]);

  const result = await client.callTool({
    name: "ai_analyze",
    arguments: {
      analysis: "explain",
      input: JSON.stringify({ mbps: 40 }),
    },
  });
  assert.equal(result.isError, undefined);
  assert.match(result.content[0].text, /"source": "local"/);
  await assert.rejects(readFile(attemptedRequest));
});
