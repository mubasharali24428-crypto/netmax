// Transport concurrency smoke: parallel clients × parallel session_info calls.
// Loopback-only, no measurement tools — fully local, deterministic, CI-safe.
// The full parallel_diagnostics e2e stays manual (web-mcp-test-concurrency.mjs:
// needs live network + macOS WiFi). Usage: node web-mcp-smoke.mjs [port].
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

const PORT = process.argv[2] || "8808";
const results = [];
const check = (name, ok, detail = "") => { results.push({ name, ok }); console.log((ok ? "PASS" : "FAIL") + "  " + name + (detail ? "  — " + detail : "")); };

const mkClient = async (tag) => {
  const c = new Client({ name: "netmax-smoke-" + tag, version: "1.0.0" });
  await c.connect(new StreamableHTTPClientTransport(new URL(`http://127.0.0.1:${PORT}/mcp`)));
  return c;
};

try {
  const clients = await Promise.all([mkClient("a"), mkClient("b"), mkClient("c")]);
  check("3 concurrent connects", true);
  const calls = [];
  for (const c of clients) for (let i = 0; i < 4; i++) calls.push(c.callTool({ name: "session_info", arguments: {} }));
  const res = await Promise.all(calls);
  check("12 parallel session_info", res.every((r) => r.isError !== true), res.length + " responses, 0 errors");
  const tools = await clients[0].listTools();
  check("listTools == 15", tools.tools.length === 15, tools.tools.length + " tools");
  check("parallel_diagnostics registered", tools.tools.some((t) => t.name === "parallel_diagnostics"));
  await Promise.all(clients.map((c) => c.close().catch(() => {})));
  const allOk = results.every((r) => r.ok);
  console.log("\nSMOKE VERDICT: " + (allOk ? "ALL PASS" : "FAILURES PRESENT"));
  process.exitCode = allOk ? 0 : 1;
} catch (e) {
  check("FATAL: " + e.message, false);
  process.exitCode = 1;
}
