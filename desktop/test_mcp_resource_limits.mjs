import assert from "node:assert/strict";
import { test } from "node:test";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { BudgetError, createMeasurementBudget, measurementCost } from "./netmax-mcp-server.mjs";

const desktop = dirname(fileURLToPath(import.meta.url));
const serverPath = join(desktop, "netmax-mcp-server.mjs");

// ── Unit: exact boundaries ──────────────────────────────────────────────────
const codeOf = (fn) => { try { fn(); } catch (e) { assert.ok(e instanceof BudgetError); return e.code; } return null; };

test("stream-second boundary: 300 accepted, 301 rejected", () => {
  const b = createMeasurementBudget();
  b.acquire("s", { streamSeconds: 300, wallSeconds: 10 })();
  assert.equal(codeOf(() => b.acquire("s", { streamSeconds: 301, wallSeconds: 10 })), "limit_stream_seconds");
});

test("wall-time boundary: 180 accepted, 181 rejected", () => {
  const b = createMeasurementBudget();
  b.acquire("s", { streamSeconds: 1, wallSeconds: 180 })();
  assert.equal(codeOf(() => b.acquire("s", { streamSeconds: 1, wallSeconds: 181 })), "limit_wall_time");
});

test("global concurrency: 2 accepted, 3rd rejected, release frees a slot", () => {
  const b = createMeasurementBudget();
  const cost = { streamSeconds: 1, wallSeconds: 1 };
  const r1 = b.acquire("a", cost); b.acquire("b", cost);
  assert.equal(codeOf(() => b.acquire("c", cost)), "busy_global");
  r1(); r1(); // idempotent
  b.acquire("c", cost);
  assert.equal(codeOf(() => b.acquire("d", cost)), "busy_global");
});

test("per-session concurrency: 1 accepted, 2nd rejected before global is consumed", () => {
  const b = createMeasurementBudget();
  const cost = { streamSeconds: 1, wallSeconds: 1 };
  const r = b.acquire("a", cost);
  assert.equal(codeOf(() => b.acquire("a", cost)), "busy_session");
  b.acquire("b", cost); // proves the rejected attempt did not leak a global slot
  r();
  b.acquire("a", cost);
});

test("cost model sums streams across sequential phases", () => {
  assert.deepEqual(measurementCost([1, 8], 10), { streamSeconds: 90, wallSeconds: 20 });
  assert.deepEqual(measurementCost([8], 10), { streamSeconds: 80, wallSeconds: 10 });
});

// ── Integration over real stdio MCP ─────────────────────────────────────────
async function harness(t, script) {
  const work = await mkdtemp(join(tmpdir(), "netmax-mcp-limits-"));
  const fake = join(work, "fake-python");
  await writeFile(fake, `#!${process.execPath}\n${script}`);
  await chmod(fake, 0o700);
  const env = { ...process.env, NETMAX_PYTHON: fake, NETMAX_TEST_DIR: work };
  const client = new Client({ name: "limits-test", version: "1.0.0" });
  await client.connect(new StdioClientTransport({ command: process.execPath, args: [serverPath], cwd: desktop, env, stderr: "pipe" }));
  t.after(async () => { await client.close().catch(() => {}); await rm(work, { recursive: true, force: true }); });
  return { client, work };
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const alive = (pid) => { try { process.kill(pid, 0); return true; } catch { return false; } };

const SPAWN_MARK = `
const fs = require('node:fs'), path = require('node:path');
fs.appendFileSync(path.join(process.env.NETMAX_TEST_DIR, 'spawns.log'), process.pid + '\\n');
`;

test("over-budget calls are rejected with a stable code and spawn nothing", async (t) => {
  const { client, work } = await harness(t, SPAWN_MARK + "process.stdout.write('ok');");
  for (const [name, args, code] of [
    ["measure_speed", { mode: "boost", streams: 50, seconds: 10 }, "limit_stream_seconds"],
    ["bufferbloat", { streams: 1, seconds: 181 }, "limit_wall_time"],
    ["upload_speed", { seconds: 301 }, "limit_stream_seconds"],
  ]) {
    const r = await client.callTool({ name, arguments: args });
    assert.equal(r.isError, true, name);
    assert.equal(r.structuredContent.code, code, name);
  }
  assert.equal(existsSync(join(work, "spawns.log")), false, "rejections must not spawn");
});

test("a second measurement in one session is rejected busy_session without spawning", async (t) => {
  const { client, work } = await harness(t, SPAWN_MARK + "setInterval(() => {}, 1000);");
  const ac = new AbortController();
  const first = client.callTool({ name: "upload_speed", arguments: { seconds: 5 } }, undefined, { signal: ac.signal }).catch(() => {});
  for (let i = 0; i < 50 && !existsSync(join(work, "spawns.log")); i++) await sleep(100);
  const second = await client.callTool({ name: "upload_speed", arguments: { seconds: 5 } });
  assert.equal(second.isError, true);
  assert.equal(second.structuredContent.code, "busy_session");
  assert.equal((await readFile(join(work, "spawns.log"), "utf8")).trim().split("\n").length, 1);
  ac.abort();
  await first;
});

test("cancellation SIGTERMs then SIGKILLs a stubborn child within 2 seconds", async (t) => {
  const { client, work } = await harness(t, SPAWN_MARK + "process.on('SIGTERM', () => {}); setInterval(() => {}, 1000);");
  const ac = new AbortController();
  const call = client.callTool({ name: "upload_speed", arguments: { seconds: 5 } }, undefined, { signal: ac.signal }).catch(() => {});
  for (let i = 0; i < 50 && !existsSync(join(work, "spawns.log")); i++) await sleep(100);
  const pid = Number((await readFile(join(work, "spawns.log"), "utf8")).trim().split("\n")[0]);
  assert.ok(alive(pid));
  const t0 = Date.now();
  ac.abort();
  while (alive(pid) && Date.now() - t0 < 5000) await sleep(50);
  const elapsed = Date.now() - t0;
  await call;
  assert.equal(alive(pid), false, "child must be reaped");
  assert.ok(elapsed <= 2500, `reaped in ${elapsed}ms`);
  const after = await client.callTool({ name: "upload_speed", arguments: { seconds: 5 } }, undefined, { signal: AbortSignal.timeout(300) }).catch(() => null);
  assert.notEqual(after?.structuredContent?.code, "busy_session", "slot must be released after cancellation");
});
