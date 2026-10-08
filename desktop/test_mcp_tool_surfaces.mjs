// Phase 1 Task 4.3: contract test pinning every public tool-count/name surface.
// If any surface drifts from the registered tools, this test fails.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const desktop = dirname(fileURLToPath(import.meta.url));
const serverPath = join(desktop, "netmax-mcp-server.mjs");

// The pinned contract: exactly these 20 tools, in server.tool() registration order.
const EXPECTED_TOOLS = [
  "measure_speed",
  "dns_ranking",
  "bufferbloat",
  "full_diagnostics",
  "boost",
  "upload_speed",
  "packet_loss",
  "jitter",
  "wifi_info",
  "download_file",
  "eco_bloat",
  "diagnostic_summary",
  "strict_limit",
  "parallel_diagnostics",
  "ai_analyze",
  "list_analyses",
  "session_info",
  "policy_bound_workflow",
  "evidence_export",
  "fleet_drift_workbench",
];

async function fakePythonEnv(t) {
  const work = await mkdtemp(join(tmpdir(), "netmax-mcp-surfaces-"));
  const fakePython = join(work, "fake-python");
  await writeFile(
    fakePython,
    "#!/usr/bin/env node\n" +
    "process.stdout.write(JSON.stringify({ success: true, mode: \"test\", data: { raw: \"OK\" } }) + '\\n');\n"
  );
  await chmod(fakePython, 0o700);
  t.after(async () => rm(work, { recursive: true, force: true }));
  return { ...process.env, NETMAX_PYTHON: fakePython, NETMAX_SLACK_WEBHOOK: "" };
}

test("tool surfaces agree: listTools, capabilities resource, banner, HTTP status, README, package.json", async (t) => {
  const env = await fakePythonEnv(t);

  // 1. MCP listTools() reports exactly the expected tools, in order.
  const client = new Client({ name: "tool-surfaces-test", version: "1.0.0" });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverPath],
    cwd: desktop,
    env,
    stderr: "pipe",
  });
  await client.connect(transport);
  t.after(async () => client.close().catch(() => {}));

  const toolList = await client.listTools();
  const registered = toolList.tools.map((x) => x.name);
  assert.deepEqual(registered, EXPECTED_TOOLS, "listTools() must match the pinned tool list in order");

  // 2. netmax://capabilities resource reports the same tool names.
  const cap = await client.readResource({ uri: "netmax://capabilities" });
  const capTools = JSON.parse(cap.contents[0].text).tools;
  assert.deepEqual(capTools, EXPECTED_TOOLS, "capabilities resource tools must match the pinned tool list");
  await client.close().catch(() => {});

  // 3. Stdio startup banner shows the registered count.
  const banner = await new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [serverPath], { cwd: desktop, env });
    let stderr = "";
    const done = (val) => {
      child.kill();
      resolve(val);
    };
    child.stderr.on("data", (d) => {
      stderr += d.toString();
      if (stderr.includes("running on stdio")) done(stderr);
    });
    child.on("error", reject);
    setTimeout(() => done(stderr), 15000);
  });
  assert.match(banner, /Tools:\s+20 registered/, "stdio banner must show 20 registered");

  // 4. HTTP /status endpoint shows the registered count.
  const port = 18923;
  const httpChild = spawn(process.execPath, [serverPath, "--http"], {
    cwd: desktop,
    env: { ...env, NETMAX_PORT: String(port) },
  });
  t.after(async () => httpChild.kill());
  const statusBody = await new Promise((resolve, reject) => {
    let stderr = "";
    httpChild.stderr.on("data", (d) => {
      stderr += d.toString();
    });
    httpChild.on("error", reject);
    const poll = async () => {
      for (let i = 0; i < 40; i++) {
        try {
          const res = await fetch(`http://127.0.0.1:${port}/status`);
          if (res.ok) return resolve(await res.text());
        } catch {}
        await new Promise((r) => setTimeout(r, 500));
      }
      reject(new Error("HTTP server did not come up; stderr:\n" + stderr));
    };
    poll();
  });
  assert.match(statusBody, /tools: 20\b/, "HTTP /status must show 'tools: 20'");
  httpChild.kill();

  // 5. MCP-README.md states the tool count.
  const readme = await readFile(join(desktop, "MCP-README.md"), "utf8");
  assert.match(readme, /## 20 Tools exposed/, "MCP-README.md must say '## 20 Tools exposed'");

  // 6. package.json test script states the tool count.
  const pkg = JSON.parse(await readFile(join(desktop, "package.json"), "utf8"));
  assert.match(pkg.scripts.test, /20 tools ready/, "package.json test script must say '20 tools ready'");
});
