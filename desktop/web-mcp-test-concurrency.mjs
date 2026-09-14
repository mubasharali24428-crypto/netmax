import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

const PORT = process.argv[2] || "8813";
const results = [];
const check = (name, ok, detail = "") => { results.push({ name, ok, detail }); console.log((ok ? "PASS" : "FAIL") + "  " + name + (detail ? "  — " + detail : "")); };

function mkClient(tag) {
  const c = new Client({ name: "netmax-e2e-r2-" + tag, version: "1.0.0" });
  return { c, t: new StreamableHTTPClientTransport(new URL(`http://127.0.0.1:${PORT}/mcp`)) };
}

try {
  // A) fresh connect + sequential calls on ONE client (stateless across POSTs)
  const A = mkClient("A");
  await A.c.connect(A.t);
  check("A connect", true);

  for (const [tool, needle] of [["dns_ranking", "STATUS: OK"], ["wifi_info", "STATUS: OK"], ["session_info", "STATUS: OK"], ["eco_bloat", null]]) {
    const r = await A.c.callTool({ name: tool, arguments: {} });
    const text = r.content?.[0]?.text || "";
    const ok = r.isError !== true && (needle ? text.includes(needle) : true);
    check(`A sequential ${tool}`, ok, text.split("\n").slice(0, 2).join(" ").slice(0, 60));
  }

  const tools = await A.c.listTools();
  check("A listTools after calls", tools.tools.length === 14, tools.tools.length + " tools");

  // B) CONCURRENT second client while A stays connected (stateless: fresh transport per request)
  const B = mkClient("B");
  await B.c.connect(B.t);
  const [dnsB, wifiA] = await Promise.all([
    B.c.callTool({ name: "dns_ranking", arguments: {} }),
    A.c.callTool({ name: "wifi_info", arguments: {} }),
  ]);
  check("B concurrent connect+call", dnsB.isError !== true && (dnsB.content?.[0]?.text || "").includes("STATUS: OK"), "B dns while A wifi in flight");
  check("A concurrent call", wifiA.isError !== true, "A wifi while B dns in flight");

  await A.c.close().catch(() => {});
  await B.c.close().catch(() => {});

  // C) brand-new client AFTER both closed (server keeps serving — no leaked state)
  const C = mkClient("C");
  await C.c.connect(C.t);
  const rC = await C.c.callTool({ name: "session_info", arguments: {} });
  check("C fresh client after A+B closed", rC.isError !== true, "server healthy post-churn");
  await C.c.close().catch(() => {});

  const allOk = results.every(r => r.ok);
  console.log("\nROUND2 VERDICT: " + (allOk ? "ALL PASS" : "FAILURES PRESENT"));
  process.exitCode = allOk ? 0 : 1;
} catch (e) {
  check("FATAL: " + e.message, false, e.stack?.split("\n")[1] || "");
  process.exitCode = 1;
}
