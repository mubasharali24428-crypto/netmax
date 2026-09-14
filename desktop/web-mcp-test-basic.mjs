import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

const PORT = process.argv[2] || "8812";
const label = process.argv[3] || "round";

const client = new Client({ name: "netmax-e2e-test", version: "1.0.0" });
const transport = new StreamableHTTPClientTransport(new URL(`http://127.0.0.1:${PORT}/mcp`));

const results = [];
const check = (name, ok, detail = "") => results.push({ name, ok, detail });

try {
  await client.connect(transport);
  check("client.connect (StreamableHTTP)", true);

  const ver = client.getServerVersion();
  check("serverVersion", !!ver?.version, `v${ver?.version} (${ver?.name})`);

  const tools = await client.listTools();
  check("listTools", tools.tools.length === 14, `${tools.tools.length} tools (expect 14)`);
  const names = tools.tools.map(t => t.name).sort().join(",");

  const dns = await client.callTool({ name: "dns_ranking", arguments: {} });
  const text = dns.content?.[0]?.text || "";
  check("callTool dns_ranking", dns.isError !== true && text.includes("STATUS: OK"), text.split("\n")[1]?.slice(0, 70) || "");

  const wifi = await client.callTool({ name: "wifi_info", arguments: {} });
  const wtext = wifi.content?.[0]?.text || "";
  check("callTool wifi_info", wifi.isError !== true, wtext.split("\n").slice(0, 3).join(" | ").slice(0, 80));

  console.log(JSON.stringify({ label, results, toolNames: names }, null, 1));
} catch (e) {
  results.push({ name: "FATAL", ok: false, detail: e.message });
  console.log(JSON.stringify({ label, results }, null, 1));
  process.exitCode = 1;
} finally {
  await client.close().catch(() => {});
}
