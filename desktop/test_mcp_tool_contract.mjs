// Phase 1 Task 4 contract test: the tool inventory reported by every
// surface must agree. If a tool is added/removed/renamed in one place
// but not the others, the client sees a phantom tool (or misses a real
// one) -- a contract break. Run: node --test test_mcp_tool_contract.mjs
process.env.NETMAX_NO_START = "1";
import assert from "node:assert/strict";
import { test } from "node:test";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const serverSrc = readFileSync(join(here, "netmax-mcp-server.mjs"), "utf8");

// 1. Registry: build the server and read back the canonical tool names.
const mod = await import("./netmax-mcp-server.mjs");
mod.buildServer();
const registryNames = [...mod.REGISTERED_TOOL_NAMES].sort();
const TOOL_COUNT = mod.REGISTERED_TOOL_NAMES.length;

test("registry is non-empty and names are unique", () => {
  assert.ok(TOOL_COUNT > 0, "expected at least one registered tool");
  assert.equal(new Set(registryNames).size, TOOL_COUNT, "duplicate tool names");
});

// 2. Banner: the stdio banner must print the same count and names.
test("banner count matches the registry", () => {
  assert.ok(
    /Tools:\s+\$\{TOOL_COUNT\}/.test(serverSrc),
    "banner must print TOOL_COUNT",
  );
});

// 3. Capabilities resource: must enumerate exactly the registered tools.
test("capabilities resource enumerates the registered tools", () => {
  assert.ok(
    serverSrc.includes("tools: TOOL_NAMES"),
    "capabilities resource must serialize tools: TOOL_NAMES",
  );
});

// 4. HTTP surfaces: /status and the web banner must use the registry.
test("HTTP status uses TOOL_COUNT, not a hardcoded number", () => {
  assert.ok(
    serverSrc.includes("tools: ${TOOL_COUNT}"),
    "/status must report tools: ${TOOL_COUNT}",
  );
  assert.ok(!/tools: 15/.test(serverSrc), "no hardcoded tool count may remain");
  assert.ok(!/tools: 17/.test(serverSrc), "no hardcoded tool count may remain");
  assert.ok(!/tools: 20/.test(serverSrc), "no hardcoded tool count may remain");
});

// 5. README: the documented tool count must match the registry.
test("README tool count matches the registry", () => {
  let readme;
  try {
    readme = readFileSync(join(here, "MCP-README.md"), "utf8");
  } catch {
    readme = readFileSync(join(here, "..", "MCP-README.md"), "utf8");
  }
  const counts = [...readme.matchAll(/(\d+)\s+(?:MCP\s+)?tools?\b/gi)]
    .map((m) => parseInt(m[1], 10))
    .filter((n) => n >= TOOL_COUNT - 2 && n <= TOOL_COUNT + 2);
  assert.ok(
    counts.includes(TOOL_COUNT),
    `README must document the tool count ${TOOL_COUNT}; found near-matches: ${counts.join(", ")}`,
  );
});

// 6. The registry is the single source: rebuilding yields the same set.
test("registry is stable across rebuilds", () => {
  mod.buildServer();
  assert.deepEqual([...mod.REGISTERED_TOOL_NAMES].sort(), registryNames);
});
