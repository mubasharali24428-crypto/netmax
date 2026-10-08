// Phase 2 G-04: policy_bound_workflow and evidence_export are real tools, not
// canned stubs. Unknown workflow names and malformed record IDs must be
// rejected BEFORE any child process spawns. Run: node --test test_mcp_workflows.mjs
import assert from "node:assert/strict";
import { test } from "node:test";
import { chmod, mkdtemp, rm, writeFile, readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const desktop = dirname(fileURLToPath(import.meta.url));
const serverPath = join(desktop, "netmax-mcp-server.mjs");

async function setupClient(t) {
  const work = await mkdtemp(join(tmpdir(), "netmax-mcp-workflows-"));
  const marker = join(work, "spawned.log");
  const fakePython = join(work, "fake-python");
  await writeFile(
    fakePython,
    `#!/usr/bin/env node
const fs = require('node:fs');
const args = process.argv.slice(2);
fs.appendFileSync(process.env.NETMAX_SPAWN_MARKER, args.join(' ') + '\\n');
const outIdx = args.indexOf('--out');
if (args.includes('export-evidence') && outIdx !== -1) {
  fs.writeFileSync(args[outIdx + 1], JSON.stringify({
    export_version: "1.0",
    generated_at: "2026-10-08T00:00:00+00:00",
    tool: "netmax evidence_export",
    records_included: 2,
    records: [
      { id: "rec-0", sha256: "a".repeat(64), record: { mbps: 95.5, note: "REDACTED-IP" } },
      { id: "rec-1", sha256: "b".repeat(64), record: { mbps: 94.0 } },
    ],
    redaction_summary: { pii_removed: true, ips_anonymized: 1, macs_removed: 0, secrets_removed: 0, synthetic_secrets_removed: false, ip_addresses_anonymized: true },
    methodology: { formulas: ["median"], units: { latency: "ms", throughput: "Mbps" }, trust_rule: "trust reports require exactly 10 samples" },
  }));
}
process.stdout.write(JSON.stringify({ success: true, mode: "test", data: { raw: "OK" } }) + '\\n');
`
  );
  await chmod(fakePython, 0o700);

  const client = new Client({ name: "workflows-test", version: "1.0.0" });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverPath],
    cwd: desktop,
    env: {
      ...process.env,
      NETMAX_PYTHON: fakePython,
      NETMAX_SPAWN_MARKER: marker,
    },
    stderr: "pipe",
  });
  await client.connect(transport);
  t.after(async () => {
    await client.close().catch(() => {});
    await rm(work, { recursive: true, force: true });
  });
  return { client, marker };
}

async function callFails(client, name, args) {
  try {
    const res = await client.callTool({ name, arguments: args });
    return res.isError === true;
  } catch {
    return true;
  }
}

test("policy_bound_workflow rejects unknown workflow with zero spawns", async (t) => {
  const { client, marker } = await setupClient(t);
  assert.equal(await callFails(client, "policy_bound_workflow", { workflow_name: "daily-health" }), true);
  assert.equal(existsSync(marker), false, "no child process may spawn for unknown workflow");
});

test("policy_bound_workflow rejects non-string workflow name with zero spawns", async (t) => {
  const { client, marker } = await setupClient(t);
  assert.equal(await callFails(client, "policy_bound_workflow", { workflow_name: 123 }), true);
  assert.equal(existsSync(marker), false, "no child process may spawn for invalid input");
});

test("policy_bound_workflow executes network_baseline with envelope report", async (t) => {
  const { client, marker } = await setupClient(t);
  const res = await client.callTool({
    name: "policy_bound_workflow",
    arguments: { workflow_name: "network_baseline" },
  });
  assert.equal(res.isError, undefined);
  const text = res.content[0].text;
  assert.match(text, /STATUS: OK/);
  assert.match(text, /3\/3 steps OK/);
  const data = res.structuredContent.data;
  assert.equal(data.workflow_name, "network_baseline");
  assert.deepEqual(data.envelope, { max_steps: 3, max_duration_s: 600 });
  assert.equal(data.steps.length, 3);
  assert.ok(data.steps.every((s) => s.status === "OK"));
  // The three engine steps really ran through the bridge.
  const spawns = await readFile(marker, "utf8");
  assert.match(spawns, /baseline/);
  assert.match(spawns, /dns/);
  assert.match(spawns, /jitter/);
});

test("evidence_export rejects malformed record IDs with zero spawns", async (t) => {
  const { client, marker } = await setupClient(t);
  for (const bad of [["../../evil"], ["rec-1", "bogus"], [""], []]) {
    assert.equal(
      await callFails(client, "evidence_export", { records: bad }),
      true,
      `should reject ${JSON.stringify(bad)}`
    );
  }
  assert.equal(existsSync(marker), false, "no child process may spawn for invalid record IDs");
});

test("evidence_export returns a real redacted manifest", async (t) => {
  const { client } = await setupClient(t);
  const res = await client.callTool({
    name: "evidence_export",
    arguments: { records: ["rec-0", "rec-1"] },
  });
  assert.equal(res.isError, undefined);
  const text = res.content[0].text;
  assert.match(text, /STATUS: OK/);
  assert.match(text, /Exported 2 record\(s\)/);
  const manifest = res.structuredContent.data;
  assert.equal(manifest.records_included, 2);
  assert.equal(manifest.records[0].id, "rec-0");
  assert.equal(manifest.redaction_summary.pii_removed, true);
  assert.match(text, /IP\(s\) anonymized/);
});
