#!/usr/bin/env node

/**
 * NetMax MCP Server - exposes NetMaxDesktop network diagnostics as MCP tools.
 *
 * Zero changes to the app.  Calls the Python engine scripts directly (same
 * scripts the Swift GUI uses via engine_bridge.py).  Runs as a stdio MCP
 * server, intended to be wired into any MCP-compatible harness.
 *
 * Usage: node netmax-mcp-server.mjs
 *
 * Wire into your MCP client (Claude Code, Cursor, DSH, VS Code, etc):
 *
 *   stdio transport:
 *     command: node
 *     args: ['/path/to/netmax-mcp-server.mjs']
 *     cwd: '/path/to/netmax-app'
 *
 *   Or via npx:
 *     command: npx
 *     args: ['-y', '@netmax/mcp-server']
 *
 * Configuration (optional env vars):
 *   NETMAX_ROOT     - Path to the netmax app directory (default: auto-detected)
 *   NETMAX_PYTHON   - Python interpreter to use (default: /usr/bin/python3)
 *   NETMAX_BRIDGE   - Path to engine_bridge.py (default: <NETMAX_ROOT>/desktop/bridge/engine_bridge.py)
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { execFile } from "node:child_process";
import { writeFile, unlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { existsSync } from "node:fs";
import { mkdtemp } from "node:fs/promises";

// ── Config ──────────────────────────────────────────────────────────────────

// Resolve the netmax app directory (NETMAX_ROOT env > auto-detect > cwd).
// Auto-detection: walk up from this script's location looking for netmax.py.
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

function resolveEngineRoot() {
  const envRoot = process.env.NETMAX_ROOT;
  if (envRoot) return envRoot;

  // Bundled engine: <script_dir>/engine/netmax.py
  const bundled = join(__dirname, "engine", "netmax.py");
  if (existsSync(bundled)) return join(__dirname, "engine");

  // Walk up from script directory looking for netmax.py
  let dir = __dirname;
  for (let i = 0; i < 5; i++) {
    if (existsSync(join(dir, "netmax.py"))) return dir;
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }

  // Fallback to cwd
  console.error("netmax.py not found — set NETMAX_ROOT to point at the engine directory");
  return process.cwd();
}

const ENGINE_ROOT = resolveEngineRoot();
const PYTHON = process.env.NETMAX_PYTHON || "/usr/bin/python3";
// Bridge: explicit env > bundled > in-repo > direct mode
const BRIDGE = (() => {
  if (process.env.NETMAX_BRIDGE) return process.env.NETMAX_BRIDGE;
  const bundledBr = join(ENGINE_ROOT, "engine_bridge.py");
  if (existsSync(bundledBr)) return bundledBr;
  const repoBr = join(dirname(ENGINE_ROOT), "desktop", "bridge", "engine_bridge.py");
  if (existsSync(repoBr)) return repoBr;
  return null;  // no bridge — call netmax.py directly
})();
const HAS_BRIDGE = BRIDGE !== null;

// For modes that the bridge supports, we use the bridge (same as the Swift GUI).
// For modes the bridge doesn't wrap, we call netmax.py directly.
const BRIDGE_MODES = new Set([
  "baseline", "turbo", "boost", "dns", "bloat", "full",
  "upload", "loss", "jitter", "wifi",
]);

// ── Server state ────────────────────────────────────────────────────────────

const SERVER_START = new Date();
let toolCallCount = 0;

// ── Helpers ─────────────────────────────────────────────────────────────────

function timeout(ms) {
  return new Promise((_, reject) =>
    setTimeout(() => reject(new Error(`Timed out after ${ms}ms`)), ms)
  );
}

/**
 * Run the engine — prefers engine_bridge.py, falls back to direct netmax.py call.
 * Returns {success, mode, data, error}  (bridge mode) or {success, data} (direct).
 */
function runViaBridge(mode, args = []) {
  toolCallCount++;
  const started = Date.now();
  const envelope = { mode, started: started, duration: 0 };

  // No bridge available — call netmax.py directly like runEngineDirect does
  if (!HAS_BRIDGE) {
    return new Promise((resolve) => {
      execFile(
        PYTHON,
        ["-B", join(ENGINE_ROOT, "netmax.py"), mode, ...args],
        {
          cwd: ENGINE_ROOT,
          timeout: 180_000,
          env: { ...process.env, PYTHONDONTWRITEBYTECODE: "1" },
        },
        (error, stdout, stderr) => {
          const elapsed = Date.now() - started;
          if (error) {
            resolve({ success: false, mode, data: null,
              error: (stderr || stdout || error.message).slice(0, 400),
              _callDurationMs: elapsed, _callTimestamp: new Date().toISOString() });
          } else {
            resolve({ success: true, mode, data: { raw: stdout.trim() },
              _callDurationMs: elapsed, _callTimestamp: new Date().toISOString() });
          }
        }
      );
    });
  }

  // Bridge available: use engine_bridge.py for structured JSON output
  return new Promise((resolve, reject) => {
    const tmpFile = join(tmpdir(), `netmax-mcp-${Date.now()}-${Math.random().toString(36).slice(2)}.json`);
    execFile(
      PYTHON,
      [BRIDGE, "run", mode, ...args, "--json-out", tmpFile],
      {
        cwd: ENGINE_ROOT,
        timeout: 180_000,  // 3 min
        env: { ...process.env, PYTHONDONTWRITEBYTECODE: "1" },
      },
      async (error, stdout, stderr) => {
        try {
          // Read the JSON envelope from the temp file
          const { readFile } = await import("node:fs/promises");
          const raw = await readFile(tmpFile, "utf-8");
          const envelope = JSON.parse(raw);
          envelope._callDurationMs = Date.now() - started;
          envelope._callTimestamp = new Date().toISOString();
          // Clean up
          try { await unlink(tmpFile); } catch {}
          resolve(envelope);
        } catch (parseErr) {
          try { await unlink(tmpFile); } catch {}
          reject(new Error(`Bridge JSON read failed: ${parseErr.message}. stderr: ${stderr.slice(-400)}`));
        }
      }
    );
  });
}

/**
 * Run netmax.py directly for advanced modes. Returns parsed stdout as text.
 */
function runEngineDirect(args) {
  toolCallCount++;
  const started = Date.now();
  return new Promise((resolve, reject) => {
    execFile(
      PYTHON,
      ["-B", join(ENGINE_ROOT, "netmax.py"), ...args],
      {
        cwd: ENGINE_ROOT,
        timeout: 180_000,
        env: { ...process.env, PYTHONDONTWRITEBYTECODE: "1" },
      },
      (error, stdout, stderr) => {
        if (error) {
          // Some errors (like DNS timeouts) are expected engine behavior
          const msg = stderr.trim() || stdout.trim() || error.message;
          resolve({ success: false, error: msg.slice(0, 400), raw: stdout.trim(), _callDurationMs: Date.now() - started, _callTimestamp: new Date().toISOString() });
        } else {
          resolve({ success: true, data: stdout.trim(), raw: stdout.trim(), _callDurationMs: Date.now() - started, _callTimestamp: new Date().toISOString() });
        }
      }
    );
  });
}

/**
 * Extract a numeric value from engine text output.
 */
function extractValue(text, pattern) {
  const match = text.match(pattern);
  return match ? parseFloat(match[1]) : null;
}

// ── UX-FIX response shaping (P0) ─────────────────────────────────────────────
//
// Contract for every tool result, success or failure:
//   1. First text line is always STATUS: OK or STATUS: FAILED — agents can
//      branch on line one without regex-ing prose.
//   2. structuredContent carries machine-readable fields (status, mode,
//      durationMs, data) so harnesses that read it skip parsing text.
//   3. A failed run ALWAYS sets isError:true — clients ignore prose, but
//      isError is surfaced as a tool error by every major harness.

/** True when an engine success envelope actually contains a dead reading. */
function looksLikeDeadMeasurement(text) {
  return /connection dropped mid-measurement|measurement unreliable/i.test(text);
}

/**
 * Shape a successful tool result: STATUS header, human text, structured copy.
 * mode names the measurement; data is the machine-readable payload.
 */
function okResult(mode, text, data = {}) {
  return {
    content: [{ type: "text", text: `STATUS: OK\n${text}` }],
    structuredContent: {
      status: "OK",
      mode,
      durationMs: data?._callDurationMs ?? null,
      timestamp: data?._callTimestamp ?? new Date().toISOString(),
      data,
    },
  };
}

/** Shape a failed tool result with isError set (see contract above). */
function failResult(mode, reason) {
  return {
    content: [{ type: "text", text: `STATUS: FAILED\n${reason}` }],
    structuredContent: {
      status: "FAILED",
      mode,
      durationMs: null,
      timestamp: new Date().toISOString(),
      error: String(reason).slice(0, 600),
    },
    isError: true,
  };
}

/**
 * Wrap a bridge/direct engine call into the shaped contract.
 * Handles: envelope failure, engine-error text, dead-measurement prose.
 */
async function runTool(mode, fn) {
  let envelope;
  try {
    envelope = await fn();
  } catch (err) {
    return failResult(mode, `engine invocation failed: ${err.message}`);
  }
  if (!envelope || envelope.success === false) {
    return failResult(mode, envelope?.error || "engine reported failure");
  }
  const raw = envelope?.data?.raw ?? envelope?.data ?? envelope?.raw ?? "";
  const text = typeof raw === "string" ? raw : JSON.stringify(raw, null, 2);
  if (looksLikeDeadMeasurement(text)) {
    return failResult(mode, text);
  }
  return okResult(mode, text, envelope.data ?? raw);
}

// ── Server ──────────────────────────────────────────────────────────────────

// ── Server factory (one instance per transport lifetime) ─────────────────

function buildServer() {
  const server = new McpServer({
    name: "netmax-mcp-server",
    version: "1.0.5",
    description: "NetMax Desktop network diagnostics — throughput, bufferbloat, DNS, WiFi, and more",
  });

  // ── Tool: measure_speed ─────────────────────────────────────────────────────

  server.tool(
    "measure_speed",
    "Run a network speed test — measures download throughput with 1 or more parallel streams. Use 'boost' mode to see baseline vs multi-stream gain.",
    {
      mode: z.enum(["baseline", "turbo", "boost"]).default("boost").describe("baseline=1 stream, turbo=N streams, boost=both+gain%"),
      streams: z.number().int().min(1).max(50).default(8).describe("Number of parallel TCP streams (turbo/boost only)"),
      seconds: z.number().int().min(5).max(21600).default(10).describe("Test duration in seconds"),
    },
    async ({ mode, streams, seconds }) => {
      const args = [];
      if (mode !== "baseline") args.push("--streams", String(streams));
      if (mode !== "dns") args.push("--seconds", String(seconds));

      return runTool(`measure_speed (${mode})`, () => runViaBridge(mode, args));
    }
  );

  // ── Tool: dns_ranking ───────────────────────────────────────────────────────

  server.tool(
    "dns_ranking",
    "Rank public DNS resolvers (Cloudflare 1.1.1.1, Google 8.8.8.8, Quad9 9.9.9.9) by median latency — finds the fastest resolver for your location.",
    {},
    async () => runTool("dns_ranking", () => runViaBridge("dns"))
  );

  // ── Tool: bufferbloat ───────────────────────────────────────────────────────

  server.tool(
    "bufferbloat",
    "Measure bufferbloat — how much your latency increases under network load. Grades A+ (excellent) to F (severe). High bufferbloat means web pages lag and video calls stutter when you're downloading.",
    {
      streams: z.number().int().min(1).max(50).default(8).describe("Parallel download streams to load the connection"),
      seconds: z.number().int().min(5).max(21600).default(10).describe("Test duration in seconds"),
    },
    async ({ streams, seconds }) =>
      runTool("bufferbloat", () =>
        runViaBridge("bloat", ["--streams", String(streams), "--seconds", String(seconds)]))
  );

  // ── Tool: full_diagnostics ──────────────────────────────────────────────────

  server.tool(
    "full_diagnostics",
    "Run the full NetMax diagnostic suite: speed test (baseline+boost), DNS ranking, bufferbloat grade, and TCP tuning notes in one shot.",
    {
      streams: z.number().int().min(1).max(50).default(8).describe("Parallel streams for turbo/boost"),
      seconds: z.number().int().min(5).max(21600).default(10).describe("Test duration per phase"),
    },
    async ({ streams, seconds }) =>
      runTool("full_diagnostics", () =>
        runViaBridge("full", ["--streams", String(streams), "--seconds", String(seconds)]))
  );

  // ── Tool: boost ──────────────────────────────────────────────────────────────

  server.tool(
    "boost",
    "Run baseline + turbo parallel-stream speed test and compute the gain percentage — shows how much headroom your connection has under contention. Higher gain = more room to improve with multi-stream downloads.",
    {
      streams: z.number().int().min(1).max(50).default(8).describe("Number of parallel TCP streams for the turbo phase"),
      seconds: z.number().int().min(5).max(21600).default(10).describe("Test duration per phase in seconds"),
    },
    async ({ streams, seconds }) =>
      runTool("boost", () =>
        runViaBridge("boost", ["--streams", String(streams), "--seconds", String(seconds)]))
  );

  // ── Tool: upload_speed ──────────────────────────────────────────────────────

  server.tool(
    "upload_speed",
    "Measure upload speed to a remote server in Mbps. Useful for checking if your ISP delivers the advertised upload rate.",
    {
      seconds: z.number().int().min(5).max(21600).default(10).describe("Test duration in seconds"),
    },
    async ({ seconds }) =>
      runTool("upload_speed", () => runViaBridge("upload", ["--seconds", String(seconds)]))
  );

  // ── Tool: packet_loss ───────────────────────────────────────────────────────

  server.tool(
    "packet_loss",
    "Measure packet loss percentage. High packet loss causes retransmissions that slow down every connection — checked by pinging a remote server.",
    {
      count: z.number().int().min(1).max(100).default(10).describe("Number of ping probes"),
    },
    async ({ count }) =>
      runTool("packet_loss", () => runViaBridge("loss", ["--count", String(count)]))
  );

  // ── Tool: jitter ────────────────────────────────────────────────────────────

  server.tool(
    "jitter",
    "Measure network jitter — the variance in packet arrival times. High jitter causes stuttering in video calls and online games.",
    {
      count: z.number().int().min(1).max(100).default(10).describe("Number of ping samples"),
    },
    async ({ count }) =>
      runTool("jitter", () => runViaBridge("jitter", ["--count", String(count)]))
  );

  // ── Tool: wifi_info ─────────────────────────────────────────────────────────

  server.tool(
    "wifi_info",
    "Get current WiFi diagnostics: signal strength (RSSI), noise level, channel, and other wireless interface data from system profiler.",
    {},
    async () => runTool("wifi_info", () => runViaBridge("wifi"))
  );

  // ── Tool: download_file (multi-stream accelerator) ─────────────────────────

  server.tool(
    "download_file",
    "Accelerated file download using multi-stream chunking — splits a ranged HTTP resource into N parallel byte-range chunks for faster transfers.",
    {
      url: z.string().url().describe("URL of the file to download"),
      streams: z.number().int().min(1).max(50).default(8).describe("Number of parallel download streams"),
      output: z.string().optional().describe("Output filename (default: derived from URL)"),
    },
    async ({ url, streams, output }) => {
      const args = [url];
      if (output) args.push(output);
      args.push("--streams", String(streams));

      return runTool("download_file", () => runEngineDirect(["fetch", ...args]));
    }
  );

  // ── Tool: eco_bloat ─────────────────────────────────────────────────────────

  server.tool(
    "eco_bloat",
    "Quick eco-friendly bufferbloat estimate using only ~100 KB of data. Less accurate than the full test but uses negligible bandwidth.",
    {},
    async () => runTool("eco_bloat", () => runEngineDirect(["bloat-eco"]))
  );

  // ── Tool: diagnostic_summary ───────────────────────────────────────────────

  server.tool(
    "diagnostic_summary",
    "Quick network health overview — runs a baseline speed test, DNS ranking, and eco-bufferbloat estimate together. A minimal all-in-one check.",
    {},
    async () => {
      // Run baseline (lightweight — single stream)
      const speedEnv = await runViaBridge("baseline", ["--seconds", "8"]);
      const dnsEnv = await runViaBridge("dns");
      const bloatResult = await runEngineDirect(["bloat-eco"]);

      const lines = [];
      lines.push("=== NetMax Quick Diagnostic Summary ===");
      lines.push("");

      if (speedEnv.success) {
        const raw = (speedEnv.data?.raw || speedEnv.data || "");
        const mbps = extractValue(raw, /([\d.]+)\s*Mbps/);
        if (mbps !== null) {
          lines.push(`Throughput:  ${mbps.toFixed(1)} Mbps (single-stream)`);
        } else {
          lines.push("Throughput:  " + raw.split("\n").filter(Boolean)[0] || "see below");
          lines.push(raw);
        }
      } else {
        lines.push("Throughput:  Failed — " + (speedEnv.error || "unknown"));
      }
      lines.push("");

      if (dnsEnv.success) {
        const raw = (dnsEnv.data?.raw || dnsEnv.data || "");
        lines.push("DNS Ranking:");
        const dnsLines = typeof raw === "string" ? raw.split("\n").filter(l => l.match(/\d\.|fastest|switching/i)) : [];
        lines.push(...(dnsLines.length ? dnsLines : [raw]));
      } else {
        lines.push("DNS Ranking: Failed");
      }
      lines.push("");

      if (bloatResult.success) {
        lines.push("Bufferbloat:");
        lines.push(bloatResult.data);
      } else {
        lines.push("Bufferbloat: Failed — " + (bloatResult.error || "unknown"));
      }
      lines.push("");

      return {
        content: [{
          type: "text",
          text: lines.join("\n"),
        }],
      };
    }
  );

  // ── Tool: parallel_diagnostics ─────────────────────────────────────────────

  server.tool(
    "parallel_diagnostics",
    "Run multiple independent network tests (speed, DNS, bloat, WiFi) CONCURRENTLY in a single tool call. Faster than running them one by one. Returns results from all tests.",
    {
      speedSeconds: z.number().int().min(5).max(21600).default(10).describe("Duration for the speed test phase"),
      speedStreams: z.number().int().min(1).max(50).default(8).describe("Streams for turbo/boost speed test"),
      includeWifi: z.boolean().default(false).describe("Also fetch WiFi info (RSSI/noise/channel)"),
      includeEcoBloat: z.boolean().default(true).describe("Include lightweight eco-bufferbloat estimate"),
    },
    async ({ speedSeconds, speedStreams, includeWifi, includeEcoBloat }) => {
      const started = Date.now();

      // ── Run independent tests CONCURRENTLY ──────────────────────────────────
      // Speed test (boost), DNS ranking, and optionally WiFi + eco-bloat all
      // execute in parallel since they're independent network measurements.

      const tasks = [];

      // Task 1: Speed test (boost mode)
      tasks.push(
        runViaBridge("boost", ["--streams", String(speedStreams), "--seconds", String(speedSeconds)])
          .then(e => ({ name: "speed", envelope: e }))
          .catch(err => ({ name: "speed", error: err.message }))
      );

      // Task 2: DNS ranking
      tasks.push(
        runViaBridge("dns", [])
          .then(e => ({ name: "dns", envelope: e }))
          .catch(err => ({ name: "dns", error: err.message }))
      );

      // Task 3: WiFi info (optional)
      if (includeWifi) {
        tasks.push(
          runViaBridge("wifi", [])
            .then(e => ({ name: "wifi", envelope: e }))
            .catch(err => ({ name: "wifi", error: err.message }))
        );
      }

      // Task 4: Eco bufferbloat (optional, lightweight ~100KB)
      if (includeEcoBloat) {
        tasks.push(
          runEngineDirect(["bloat-eco"])
            .then(r => ({ name: "bloat", result: r }))
            .catch(err => ({ name: "bloat", error: err.message }))
        );
      }

      // Wait for ALL tests to finish concurrently
      const results = await Promise.all(tasks);

      const elapsed = ((Date.now() - started) / 1000).toFixed(1);
      const lines = [];
      lines.push("=== Parallel Diagnostics ===");
      lines.push(`Completed ${results.length} tests in ${elapsed}s`);
      lines.push("");

      for (const result of results) {
        if (result.error) {
          lines.push(`[FAIL] ${result.name}: ${result.error}`);
          lines.push("");
          continue;
        }

        if (result.name === "speed") {
          const raw = result.envelope.data?.raw || result.envelope.data || "";
          if (result.envelope.success && typeof raw === "string") {
            lines.push("── Speed Test ──────────────");
            // Extract the key lines from the engine output
            const speedLines = raw.split("\n").filter(l =>
              l.includes("Mbps") || l.includes("single-stream") ||
              l.includes("multi-stream") || l.includes("headroom") ||
              l.includes("already reach")
            );
            lines.push(...(speedLines.length ? speedLines : [raw]));
          } else {
            lines.push("── Speed Test ──────────────");
            lines.push("Failed or no data");
          }
          lines.push("");
        }

        if (result.name === "dns") {
          const raw = result.envelope.data?.raw || result.envelope.data || "";
          if (result.envelope.success && typeof raw === "string") {
            lines.push("── DNS Ranking ─────────────");
            const dnsLines = raw.split("\n").filter(l =>
              l.match(/\d+\.\s/) || l.includes("fastest") || l.includes("switching")
            );
            lines.push(...(dnsLines.length ? dnsLines : [raw]));
          } else {
            lines.push("── DNS Ranking ─────────────");
            lines.push("Failed or no data");
          }
          lines.push("");
        }

        if (result.name === "wifi") {
          const raw = result.envelope.data?.raw || result.envelope.data || "";
          if (result.envelope.success && typeof raw === "string") {
            lines.push("── WiFi Info ───────────────");
            const wifiLines = raw.split("\n").filter(l => l.includes(":"));
            lines.push(...(wifiLines.length ? wifiLines : [raw]));
          } else {
            lines.push("── WiFi Info ───────────────");
            lines.push("Failed or no data");
          }
          lines.push("");
        }

        if (result.name === "bloat") {
          if (result.result?.success) {
            lines.push("── Bufferbloat ─────────────");
            lines.push(result.result.data);
          } else {
            lines.push("── Bufferbloat ─────────────");
            lines.push(result.result?.error || "Failed");
          }
          lines.push("");
        }
      }

      lines.push(`Total time: ${elapsed}s (tests ran in parallel where possible)`);
      if (results.length >= 2) {
        lines.push("Note: Speed and DNS ran concurrently since they are independent.");
        if (includeWifi) lines.push("WiFi info was gathered in parallel with network tests.");
      }

      return {
        content: [{
          type: "text",
          text: lines.join("\n"),
        }],
      };
    }
  );

  // ── Tool: session_info ──────────────────────────────────────────────────────

  server.tool(
    "session_info",
    "Show how long the MCP server has been running and how many tools have been called this session. Server lifetime equals the DSH session lifetime.",
    {},
    async () => {
      const uptime = Date.now() - SERVER_START.getTime();
      const seconds = Math.floor(uptime / 1000);
      const minutes = Math.floor(seconds / 60);
      const hours = Math.floor(minutes / 60);

      let uptimeStr;
      if (hours > 0) uptimeStr = `${hours}h ${minutes % 60}m ${seconds % 60}s`;
      else if (minutes > 0) uptimeStr = `${minutes}m ${seconds % 60}s`;
      else uptimeStr = `${seconds}s`;

      return okResult("session_info", [
        "=== MCP Server Session Info ===",
        "",
        `Server started:  ${SERVER_START.toISOString()}`,
        `Uptime:          ${uptimeStr}`,
        `Tool calls:      ${toolCallCount}`,
        `Server process:  PID ${process.pid}`,
        `Node version:    ${process.version}`,
        `Platform:        ${process.platform} ${process.arch}`,
      ].join("\n"), {
        serverStarted: SERVER_START.toISOString(),
        uptimeSeconds: seconds,
        toolCalls: toolCallCount,
        pid: process.pid,
        node: process.version,
        platform: `${process.platform} ${process.arch}`,
      });
    }
  );
  return server;
}

// ── Start ───────────────────────────────────────────────────────────────────

async function main() {
  const httpMode = process.argv.includes("--http") || /^(1|true|yes)$/i.test(process.env.NETMAX_HTTP || "");

  if (!httpMode) {
    console.error(`NetMax MCP server v1.0.5 (stdio)`);
    console.error(`  Engine root: ${ENGINE_ROOT}`);
    console.error(`  Python:      ${PYTHON}`);
    console.error(`  Bridge:      ${HAS_BRIDGE ? BRIDGE : "none (direct mode)"}`);
    console.error(`  Tools:       14 registered`);
    console.error(`  Config:      NETMAX_ROOT / NETMAX_PYTHON / NETMAX_BRIDGE env vars`);
    console.error("");
    const transport = new StdioServerTransport();
    await buildServer().connect(transport);
    console.error("NetMax MCP server running on stdio");
    return;
  }

  // ── Web MCP: Streamable HTTP (localhost-only by default) ──────────────────
  // The engine measures THIS machine's network; a remotely-hosted instance
  // would measure the datacenter's pipe, not the user's. Loopback bind unless
  // NETMAX_HOST is set (LAN pairing); bearer token when NETMAX_TOKEN is set.
  const { createServer } = await import("node:http");
  const { StreamableHTTPServerTransport } = await import("@modelcontextprotocol/sdk/server/streamableHttp.js");

  const host = process.env.NETMAX_HOST || "127.0.0.1";
  const port = Number(process.env.NETMAX_PORT || 8808);
  const token = process.env.NETMAX_TOKEN;

  const httpServer = createServer(async (req, res) => {
    // Trust boundary: bearer gate before anything parses.
    if (token) {
      const provided = String(req.headers["authorization"] || "").replace(/^Bearer /, "");
      if (provided !== token) {
        res.writeHead(401, { "content-type": "text/plain" });
        res.end("unauthorized");
        return;
      }
    }
    try {
      // Stateless: fresh transport per request (official SDK pattern).
      const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
      transport.onerror = (e) => console.error("[http] transport error:", e.message);
      const srv = buildServer();
      await srv.connect(transport);
      res.on("close", () => { transport.close(); });
      await transport.handleRequest(req, res);
    } catch (e) {
      console.error("[http] request error:", e.message);
      if (!res.headersSent) res.writeHead(500);
      res.end("internal error");
    }
  });

  httpServer.listen(port, host, () => {
    console.error(`NetMax MCP server v1.0.5 (web) — Streamable HTTP`);
    console.error(`  Endpoint:     http://${host === "127.0.0.1" ? "localhost" : host}:${port}/mcp`);
    console.error(`  Engine root:  ${ENGINE_ROOT}`);
    console.error(`  Auth:         ${token ? "bearer token (NETMAX_TOKEN)" : "none (localhost only)"}`);
    console.error(`  Tools:        14 registered`);
    console.error("");
    console.error("Web MCP ready — add to Claude/Cursor/DSH as a remote MCP server:");
    console.error(`  url: http://${host}:${port}/mcp` + (token ? "  headers: Authorization: Bearer <NETMAX_TOKEN>" : ""));
  });
}

main().catch((err) => {
  console.error("Fatal:", err);
  process.exit(1);
});
