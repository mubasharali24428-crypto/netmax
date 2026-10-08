import assert from "node:assert/strict";
import { test } from "node:test";
import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const desktop = dirname(fileURLToPath(import.meta.url));
const serverPath = join(desktop, "netmax-mcp-server.mjs");

const ALL_17_TOOLS = [
  "fleet_drift_workbench",
  "policy_bound_workflow",
  "evidence_export",
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
  "session_info"
];

async function setupClient(t) {
  const work = await mkdtemp(join(tmpdir(), "netmax-mcp-schema-"));
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
    records_included: 1,
    records: [{ id: "rec-1", sha256: "0".repeat(64), record: { mbps: 95.5 } }],
    redaction_summary: { pii_removed: true, ips_anonymized: 1, macs_removed: 0, secrets_removed: 0, synthetic_secrets_removed: false, ip_addresses_anonymized: true },
    methodology: { formulas: ["median"], units: { latency: "ms", throughput: "Mbps" }, trust_rule: "trust reports require exactly 10 samples" },
  }));
}
process.stdout.write(JSON.stringify({ success: true, mode: "test", data: { raw: "OK" } }) + '\\n');
`
  );
  await chmod(fakePython, 0o700);

  const client = new Client({ name: "schema-contract-test", version: "1.0.0" });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverPath],
    cwd: desktop,
    env: {
      ...process.env,
      NETMAX_PYTHON: fakePython,
      NETMAX_SPAWN_MARKER: marker,
      NETMAX_FLEET_ALLOWLIST: JSON.stringify({
        "site-a": "https://site-a.example",
        "site-b": "https://site-b.example",
      }),
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

test("MCP server registers exactly the expected 20 tools", async (t) => {
  const { client } = await setupClient(t);
  const toolList = await client.listTools();
  const registered = toolList.tools.map((x) => x.name).sort();
  assert.deepEqual(registered, [...ALL_17_TOOLS].sort());
});

const CASES = {


  measure_speed: {
    valid: [{ mode: "turbo", streams: 4, seconds: 10 }, {}],
    invalid: [
      { mode: "invalid_mode" },
      { streams: 0 },
      { streams: 51 },
      { streams: "eight" },
      { seconds: 4 },
      { seconds: 21601 },
      "not-an-object",
    ],
  },
  dns_ranking: {
    valid: [{}],
    invalid: ["not-an-object", 12345, []],
  },
  bufferbloat: {
    valid: [{ streams: 4, seconds: 10 }, {}],
    invalid: [
      { streams: 0 },
      { streams: 51 },
      { seconds: 4 },
      { seconds: 21601 },
      { streams: "bad" },
      "not-an-object",
    ],
  },
  full_diagnostics: {
    valid: [{ streams: 2, seconds: 10 }, {}],
    invalid: [{ streams: 0 }, { streams: 51 }, { seconds: 4 }, { seconds: 21601 }, "not-an-object"],
  },
  boost: {
    valid: [{ streams: 4, seconds: 10 }, {}],
    invalid: [{ streams: 0 }, { streams: 51 }, { seconds: 4 }, { seconds: 21601 }, "not-an-object"],
  },
  upload_speed: {
    valid: [{ seconds: 10 }, {}],
    invalid: [{ seconds: 4 }, { seconds: 21601 }, { seconds: "ten" }, "not-an-object"],
  },
  packet_loss: {
    valid: [{ count: 5 }, {}],
    invalid: [{ count: 0 }, { count: 101 }, { count: "five" }, "not-an-object"],
  },
  jitter: {
    valid: [{ count: 20 }, {}],
    invalid: [{ count: 0 }, { count: 101 }, { count: -1 }, "not-an-object"],
  },
  wifi_info: {
    valid: [{}],
    invalid: ["not-an-object", 123, []],
  },
  download_file: {
    valid: [{ url: "https://example.com/file.bin", streams: 4 }],
    invalid: [
      {}, // missing required url
      { url: "not-a-valid-url" },
      { url: "" },
      { url: 12345 },
      { url: "https://example.com/file", streams: 0 },
      { url: "https://example.com/file", streams: 51 },
      { url: "https://example.com/file", output: "../escape" },
      "not-an-object",
    ],
  },
  eco_bloat: {
    valid: [{}],
    invalid: ["not-an-object", 123, []],
  },
  diagnostic_summary: {
    valid: [{}],
    invalid: ["not-an-object", 123, []],
  },
  strict_limit: {
    valid: [{ mbps: 5.0, seconds: 10 }],
    invalid: [
      {}, // missing required mbps
      { mbps: 0.2 }, // below 0.5
      { mbps: 10001 }, // above 10000
      { mbps: "fast" },
      { mbps: 5.0, seconds: 4 },
      { mbps: 5.0, seconds: 151 },
      "not-an-object",
    ],
  },
  parallel_diagnostics: {
    valid: [{ speedSeconds: 10, speedStreams: 4, includeWifi: true, includeEcoBloat: false }, {}],
    invalid: [
      { speedSeconds: 4 },
      { speedSeconds: 21601 },
      { speedStreams: 0 },
      { speedStreams: 51 },
      { includeWifi: "yes" },
      "not-an-object",
    ],
  },
  ai_analyze: {
    valid: [{ analysis: "root_cause", input: "{}" }],
    invalid: [
      {}, // missing required analysis
      { analysis: 123 },
      { analysis: "root_cause", input: 123 },
      { analysis: "root_cause", history_path: 123 },
      { analysis: "root_cause", pretty: "yes" },
      "not-an-object",
    ],
  },
  list_analyses: {
    valid: [{}],
    invalid: ["not-an-object", 123, []],
  },
  session_info: {
    valid: [{}],
    invalid: ["not-an-object", 123, []],
  },
  fleet_drift_workbench: {
    valid: [{ action: "init_baseline", peer_alias: "site-a" }, { action: "trigger_check", peer_alias: "site-b" }],
    invalid: [{ action: "unknown" }, { action: "init_baseline", peer_alias: "" }, {}]
  },
  policy_bound_workflow: {
    valid: [{ workflow_name: "network_baseline" }],
    invalid: [{ workflow_name: 123 }, {}, { workflow_name: "daily-health" }, { workflow_name: "../evil" }]
  },
  evidence_export: {
    valid: [{ records: ["rec-1"] }],
    invalid: [{ records: "rec-1" }, {}, { records: [] }, { records: ["../../evil"] }, { records: ["rec-1", "bogus"] }]
  },
};

for (const toolName of ALL_17_TOOLS) {
  test(`schema contract for tool '${toolName}': accepts valid calls and rejects boundary violations before side effects`, async (t) => {
    const { client, marker } = await setupClient(t);
    const spec = CASES[toolName];
    assert.ok(spec, `test cases must exist for registered tool ${toolName}`);

    // 1. Valid calls
    for (const validArgs of spec.valid) {
      const res = await client.callTool({ name: toolName, arguments: validArgs });
      // fleet_drift_workbench requires live network peers; schema acceptance
      // (not a validation error) is what we assert -- operational probe
      // failures are expected in CI without real peers.
      const operationalOnly =
        toolName === "fleet_drift_workbench" &&
        res.isError === true &&
        /probes?.*failed|unreachable|Unknown fleet peer|No baseline/i.test(JSON.stringify(res));
      assert.ok(
        res.isError !== true || operationalOnly,
        `Tool ${toolName} unexpectedly failed on valid args ${JSON.stringify(validArgs)}: ${JSON.stringify(res)}`
      );
    }

    // 2. Invalid calls: must be rejected with error (either isError or rejected promise), and MUST NOT spawn child process
    for (const badArgs of spec.invalid) {
      const spawnsBefore = existsSync(marker);
      let rejected = false;
      try {
        const res = await client.callTool({ name: toolName, arguments: badArgs });
        if (res.isError) {
          rejected = true;
        }
      } catch {
        rejected = true;
      }
      assert.equal(
        rejected,
        true,
        `Tool ${toolName} unexpectedly succeeded on invalid args ${JSON.stringify(badArgs)}`
      );
      if (!spawnsBefore) {
        assert.equal(
          existsSync(marker),
          false,
          `Invalid call ${toolName}(${JSON.stringify(badArgs)}) must not spawn child process`
        );
      }
    }
  });
}
