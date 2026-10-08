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

import net from "node:net";
import dns from "node:dns";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { execFile } from "node:child_process";
import { writeFile, unlink, readFile, mkdir, rename, chmod } from "node:fs/promises";
import { tmpdir, homedir } from "node:os";
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

// Single source for the banner count. It was a hardcoded "15" in two
// places and silently under-reported the moment a tool was added.
// Registry: tool names are recorded as server.tool() runs, so the count
// and the capability list derive from one source and cannot drift.
// TOOL_NAMES is the let-bound array below, overwritten on each registration.
export const REGISTERED_TOOL_NAMES = [];
let TOOL_COUNT = 0;

// Mirrors the engine's validate_mcp_output_name: one safe basename,
// never a caller-selected path. Rejects before the engine spawns.
function validateMcpOutputName(name) {
  if (typeof name !== "string" || name.length === 0 || name === "." || name === "..")
    throw new Error("MCP output name must be a non-empty basename");
  if (Buffer.byteLength(name, "utf8") > 180 || name.includes("/") || name.includes("\\") ||
      /[\x00-\x1f\x7f]/.test(name) || /^[a-zA-Z]:/.test(name))
    throw new Error("MCP output name must be a basename of at most 180 UTF-8 bytes");
}

// Names, for the netmax://capabilities resource so an agent can discover
// what exists without guessing. Kept beside TOOL_COUNT on purpose: the
// audit checks that constant against the tools actually defined, and a
// list sitting next to it invites the same check to cover both.
let TOOL_NAMES = [
  "measure_speed", "dns_ranking", "bufferbloat", "upload_speed",
  "packet_loss", "jitter", "wifi_info", "download_file", "eco_bloat",
  "full_diagnostics", "diagnostic_summary", "boost",
  "parallel_diagnostics", "strict_limit", "ai_analyze", "list_analyses",
  "session_info",
];

// Failure alerts: Slack incoming-webhook URL (unset = no alerting).
// Rate-limited to one post per 5 min; a dead webhook never breaks a call.
const SLACK_WEBHOOK = process.env.NETMAX_SLACK_WEBHOOK || "";
const SLACK_MIN_INTERVAL_MS = 5 * 60 * 1000;
let lastSlackAlertMs = 0;

function notifySlack(mode, reason) {
  if (!SLACK_WEBHOOK) return;
  const now = Date.now();
  if (now - lastSlackAlertMs < SLACK_MIN_INTERVAL_MS) return;
  lastSlackAlertMs = now;
  try {
    const url = new URL(SLACK_WEBHOOK);
    const firstLine = String(reason).split("\n")[0].slice(0, 200);
    const body = JSON.stringify({ text: `NetMax \`${mode}\` failed: ${firstLine}` });
    const transport = url.protocol === "https:"
      ? import("node:https")
      : import("node:http");
    Promise.resolve(transport).then(({ request }) => {
      const req = request(url, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "content-length": Buffer.byteLength(body),
        },
      });
      req.on("error", () => {});
      req.end(body);
    }).catch(() => {});
  } catch {
    // Malformed webhook URL must never break a tool call.
  }
}

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
function runViaBridge(mode, args = [], signal) {
  toolCallCount++;
  const started = Date.now();
  const envelope = { mode, started: started, duration: 0 };

  if (!HAS_BRIDGE) {
    return new Promise((resolve) => {
      const child = execFile(
        PYTHON,
        ["-B", join(ENGINE_ROOT, "netmax.py"), mode, ...args],
        {
          cwd: ENGINE_ROOT,
          timeout: 180_000,
          env: { ...process.env, PYTHONDONTWRITEBYTECODE: "1" },
        },
        (error, stdout, stderr) => {
          if (signal) signal.removeEventListener("abort", onAbort);
          const elapsed = Date.now() - started;
          if (error) {
            resolve({ success: false, mode, data: null, error: (stderr || stdout || error.message).slice(0, 400), _callDurationMs: elapsed, _callTimestamp: new Date().toISOString() });
          } else {
            resolve({ success: true, mode, data: { raw: stdout.trim() }, _callDurationMs: elapsed, _callTimestamp: new Date().toISOString() });
          }
        }
      );
      let onAbort;
      if (signal) {
        onAbort = () => {
          child.kill("SIGTERM");
          setTimeout(() => { try { child.kill("SIGKILL"); } catch(e){} }, 2000);
        };
        signal.addEventListener("abort", onAbort);
      }
    });
  }

  return new Promise((resolve, reject) => {
    const tmpFile = join(tmpdir(), `netmax-mcp-${Date.now()}-${Math.random().toString(36).slice(2)}.json`);
    const bridge = execFile(
      PYTHON,
      [BRIDGE, "run", mode, ...args, "--json-out", tmpFile],
      {
        cwd: ENGINE_ROOT,
        timeout: 180_000,
        env: { ...process.env, PYTHONDONTWRITEBYTECODE: "1" },
      },
      (error, stdout, stderr) => {
        if (signal) signal.removeEventListener("abort", onAbort);
        if (error) {
          const msg = stderr.trim() || stdout.trim() || error.message;
          resolve({ success: false, mode, data: null, error: msg.slice(0, 400), raw: stdout.trim(), _callDurationMs: Date.now() - started, _callTimestamp: new Date().toISOString() });
          return;
        }
        if (existsSync(tmpFile)) {
          readFile(tmpFile, "utf8").then((content) => {
            try {
              Object.assign(envelope, JSON.parse(content));
              envelope.success = true;
              envelope._callDurationMs = Date.now() - started;
              envelope._callTimestamp = new Date().toISOString();
            } catch (e) {
              envelope.success = false;
              envelope.error = "Invalid JSON from engine_bridge";
            }
            unlink(tmpFile).catch(() => {});
            resolve(envelope);
          }).catch(err => {
            envelope.success = false;
            envelope.error = `Could not read engine output: ${err.message}`;
            resolve(envelope);
          });
        } else {
          envelope.success = false;
          envelope.error = "No output produced by engine";
          resolve(envelope);
        }
      }
    );
    let onAbort;
    if (signal) {
      onAbort = () => {
        bridge.kill("SIGTERM");
        setTimeout(() => { try { bridge.kill("SIGKILL"); } catch(e){} }, 2000);
      };
      signal.addEventListener("abort", onAbort);
    }
  });
}

function runEngineDirect(args, signal) {
  toolCallCount++;
  const started = Date.now();
  return new Promise((resolve, reject) => {
    const child = execFile(
      PYTHON,
      ["-B", join(ENGINE_ROOT, "netmax.py"), ...args],
      {
        cwd: ENGINE_ROOT,
        timeout: 180_000,
        env: { ...process.env, PYTHONDONTWRITEBYTECODE: "1" },
      },
      (error, stdout, stderr) => {
        if (signal) signal.removeEventListener("abort", onAbort);
        if (error) {
          const msg = stderr.trim() || stdout.trim() || error.message;
          resolve({ success: false, error: msg.slice(0, 400), raw: stdout.trim(), _callDurationMs: Date.now() - started, _callTimestamp: new Date().toISOString() });
        } else {
          resolve({ success: true, data: stdout.trim(), raw: stdout.trim(), _callDurationMs: Date.now() - started, _callTimestamp: new Date().toISOString() });
        }
      }
    );
    let onAbort;
    if (signal) {
      onAbort = () => {
        child.kill("SIGTERM");
        setTimeout(() => { try { child.kill("SIGKILL"); } catch(e){} }, 2000);
      };
      signal.addEventListener("abort", onAbort);
    }
  });
}

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
async function runTool(mode, fn, signal) {
  const failed = (reason) => {
    notifySlack(mode, reason); // fire-and-forget, rate-limited, unset=no-op
    return failResult(mode, reason);
  };
  let envelope;
  try {
    envelope = await fn();
  } catch (err) {
    return failed(`engine invocation failed: ${err.message}`);
  }
  if (!envelope || envelope.success === false) {
    return failed(envelope?.error || "engine reported failure");
  }
  const raw = envelope?.data?.raw ?? envelope?.data ?? envelope?.raw ?? "";
  const text = typeof raw === "string" ? raw : JSON.stringify(raw, null, 2);
  if (looksLikeDeadMeasurement(text)) {
    return failed(text);
  }
  return okResult(mode, text, envelope.data ?? raw);
}

/** Minimal HTML escaping (peer dashboard bodies are remote content). */
function escHtml(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

/**
 * Extract a numeric value from engine text output.
 */
function extractValue(text, pattern) {
  const match = text.match(pattern);
  return match ? parseFloat(match[1]) : null;
}
// ── Server ──────────────────────────────────────────────────────────────────

// ── Server factory (one instance per transport lifetime) ─────────────────

export function buildServer() {
  const server = new McpServer({
    name: "netmax-mcp-server",
    version: "1.0.7",
    description: "NetMax Desktop network diagnostics — throughput, bufferbloat, DNS, WiFi, and more",
  });

  // Tool registry: record every tool name as it registers. TOOL_COUNT and
  // TOOL_NAMES update on each registration, so they cannot drift.
  REGISTERED_TOOL_NAMES.length = 0;
  const __rawTool = server.tool.bind(server);
  server.tool = function (name, ...rest) {
    REGISTERED_TOOL_NAMES.push(name);
    TOOL_COUNT = REGISTERED_TOOL_NAMES.length;
    TOOL_NAMES = [...REGISTERED_TOOL_NAMES];
    return __rawTool(name, ...rest);
  };

  const globalBudget = createMeasurementBudget();

  function costFor(name, params) {
    const streams = params.streams || 1;
    const seconds = params.seconds || 10;
    switch (name) {
      case "measure_speed":
        if (params.mode === "boost") return measurementCost([1, streams], seconds);
        if (params.mode === "turbo") return measurementCost([streams], seconds);
        return measurementCost([1], seconds);
      case "bufferbloat":
      case "upload_speed":
      case "packet_loss":
      case "jitter":
        return measurementCost([streams], seconds);
      case "full_diagnostics":
        return measurementCost([1, streams, 1, 1], seconds);
      case "parallel_diagnostics":
        return measurementCost([streams, streams, 1, 1], seconds);
      case "diagnostic_summary":
        return measurementCost([1, 1], seconds);
      default:
        return { streamSeconds: 0, wallSeconds: 0 };
    }
  }

  const originalTool = server.tool.bind(server);
  server.tool = function (name, desc, schema, handler) {
    originalTool(name, desc, schema, async (params, extra) => {
      const cost = costFor(name, params);
      if (cost.streamSeconds === 0 && cost.wallSeconds === 0) return handler(params, extra);
      const sessionId = extra?.session?.id || "default";
      let release;
      try {
        release = globalBudget.acquire(sessionId, cost);
      } catch (err) {
        if (err instanceof BudgetError) {
          return {
            isError: true,
            content: [{ type: "text", text: `Budget rejected [${err.code}]: ${err.message || err.code}` }],
            structuredContent: { code: err.code, message: err.message || err.code }
          };
        }
        throw err;
      }
      try {
        return await handler(params, extra);
      } finally {
        release();
      }
    });
  };


  // ── Tool: measure_speed ─────────────────────────────────────────────────────

  server.tool(
    "measure_speed",
    "Run a network speed test — measures download throughput with 1 or more parallel streams. Use 'boost' mode to see baseline vs multi-stream gain.",
    {
      mode: z.enum(["baseline", "turbo", "boost"]).default("boost").describe("baseline=1 stream, turbo=N streams, boost=both+gain%"),
      streams: z.number().int().min(1).max(50).default(8).describe("Number of parallel TCP streams (turbo/boost only)"),
      seconds: z.number().int().min(5).max(21600).default(10).describe("Test duration in seconds"),
    },
    async (params, extra) => {
      const { mode, streams, seconds } = params;
      const args = [];
      if (mode !== "baseline") args.push("--streams", String(streams));
      if (mode !== "dns") args.push("--seconds", String(seconds));

      return runTool(`measure_speed (${mode})`, () => runViaBridge(mode, args, extra?.signal), extra?.signal);
    }
  );

  // ── Tool: dns_ranking ───────────────────────────────────────────────────────

  server.tool(
    "dns_ranking",
    "Rank public DNS resolvers (Cloudflare 1.1.1.1, Google 8.8.8.8, Quad9 9.9.9.9) by median latency — finds the fastest resolver for your location.",
    {},
    async (params, extra) => runTool("dns_ranking", () => runViaBridge("dns", [], extra?.signal), extra?.signal)
  );

  // ── Tool: bufferbloat ───────────────────────────────────────────────────────

  server.tool(
    "bufferbloat",
    "Measure bufferbloat — how much your latency increases under network load. Grades A+ (excellent) to F (severe). High bufferbloat means web pages lag and video calls stutter when you're downloading.",
    {
      streams: z.number().int().min(1).max(50).default(8).describe("Parallel download streams to load the connection"),
      seconds: z.number().int().min(5).max(21600).default(10).describe("Test duration in seconds"),
    },
    async (params, extra) => {
      const { streams, seconds } = params;
      return runTool("bufferbloat", () => runViaBridge("bloat", ["--streams", String(streams), "--seconds", String(seconds)], extra?.signal), extra?.signal);
    }
  );

  // ── Tool: full_diagnostics ──────────────────────────────────────────────────

  server.tool(
    "full_diagnostics",
    "Run the full NetMax diagnostic suite: speed test (baseline+boost), DNS ranking, bufferbloat grade, and TCP tuning notes in one shot.",
    {
      streams: z.number().int().min(1).max(50).default(8).describe("Parallel streams for turbo/boost"),
      seconds: z.number().int().min(5).max(21600).default(10).describe("Test duration per phase"),
    },
    async (params, extra) => {
      const { streams, seconds } = params;
      return runTool("full_diagnostics", () => runViaBridge("full", ["--streams", String(streams), "--seconds", String(seconds)], extra?.signal), extra?.signal);
    }
  );

  // ── Tool: boost ──────────────────────────────────────────────────────────────

  server.tool(
    "boost",
    "Run baseline + turbo parallel-stream speed test and compute the gain percentage — shows how much headroom your connection has under contention. Higher gain = more room to improve with multi-stream downloads.",
    {
      streams: z.number().int().min(1).max(50).default(8).describe("Number of parallel TCP streams for the turbo phase"),
      seconds: z.number().int().min(5).max(21600).default(10).describe("Test duration per phase in seconds"),
    },
    async (params, extra) => {
      const { streams, seconds } = params;
      return runTool("boost", () => runViaBridge("boost", ["--streams", String(streams), "--seconds", String(seconds)], extra?.signal), extra?.signal);
    }
  );

  // ── Tool: upload_speed ──────────────────────────────────────────────────────

  server.tool(
    "upload_speed",
    "Measure upload speed to a remote server in Mbps. Useful for checking if your ISP delivers the advertised upload rate.",
    {
      seconds: z.number().int().min(5).max(21600).default(10).describe("Test duration in seconds"),
    },
    async (params, extra) => {
      const { seconds } = params;
      return runTool("upload_speed", () => runViaBridge("upload", ["--seconds", String(seconds)], extra?.signal), extra?.signal);
    }
  );

  // ── Tool: packet_loss ───────────────────────────────────────────────────────

  server.tool(
    "packet_loss",
    "Measure packet loss percentage. High packet loss causes retransmissions that slow down every connection — checked by pinging a remote server.",
    {
      count: z.number().int().min(1).max(100).default(10).describe("Number of ping probes"),
    },
    async (params, extra) => {
      const { count } = params;
      return runTool("packet_loss", () => runViaBridge("loss", ["--count", String(count)], extra?.signal), extra?.signal);
    }
  );

  // ── Tool: jitter ────────────────────────────────────────────────────────────

  server.tool(
    "jitter",
    "Measure network jitter — the variance in packet arrival times. High jitter causes stuttering in video calls and online games.",
    {
      count: z.number().int().min(1).max(100).default(10).describe("Number of ping samples"),
    },
    async (params, extra) => {
      const { count } = params;
      return runTool("jitter", () => runViaBridge("jitter", ["--count", String(count)], extra?.signal), extra?.signal);
    }
  );

  // ── Tool: wifi_info ─────────────────────────────────────────────────────────

  server.tool(
    "wifi_info",
    "Get current WiFi diagnostics: signal strength (RSSI), noise level, channel, and other wireless interface data from system profiler.",
    {},
    async (params, extra) => runTool("wifi_info", () => runViaBridge("wifi", [], extra?.signal), extra?.signal)
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
    async (params, extra) => {
      const { url, streams, output } = params;
      const args = [url];
      if (output !== undefined) {
        validateMcpOutputName(output);
        args.push("--mcp-output-name", output);
      } else {
        // Derive a safe basename from the URL path; fallback to "download".
        let derived = "download";
        try {
          const pathname = new URL(url).pathname;
          if (!pathname.endsWith("/")) {
            const pathParts = pathname.split("/").filter(Boolean);
            if (pathParts.length > 0) derived = pathParts[pathParts.length - 1];
          }
        } catch {}
        validateMcpOutputName(derived);
        args.push("--mcp-output-name", derived);
      }
      args.push("--streams", String(streams));

      return runTool("download_file", () => runEngineDirect(["fetch", ...args], extra?.signal), extra?.signal);
    }
  );

  // ── Tool: eco_bloat ─────────────────────────────────────────────────────────

  server.tool(
    "eco_bloat",
    "Quick eco-friendly bufferbloat estimate using only ~100 KB of data. Less accurate than the full test but uses negligible bandwidth.",
    {},
    // Via the bridge (bloat-eco takes no flags) so range validation and the
    // C1 envelope apply uniformly. download_file stays direct: fetch takes
    // positional url/out args the bridge's flag-only contract can't express.
    async (params, extra) => runTool("eco_bloat", () => runViaBridge("bloat-eco", [], extra?.signal), extra?.signal)
  );

  // ── Tool: diagnostic_summary ───────────────────────────────────────────────

  server.tool(
    "diagnostic_summary",
    "Quick network health overview — runs a baseline speed test, DNS ranking, and eco-bufferbloat estimate together. A minimal all-in-one check.",
    {},
    async (params, extra) => {
      // Run baseline (lightweight — single stream)
      const speedEnv = await runViaBridge("baseline", ["--seconds", "8"], extra?.signal);
      const dnsEnv = await runViaBridge("dns", [], extra?.signal);
      const bloatResult = await runEngineDirect(["bloat-eco"], extra?.signal);

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

      const text = lines.join("\n");
      const anyOk = speedEnv.success || dnsEnv.success || bloatResult.success;
      if (!anyOk) {
        return failResult("diagnostic_summary",
          "all three probes failed: " +
          [speedEnv.error, dnsEnv.error, bloatResult.error]
            .filter(Boolean).map((e) => String(e).slice(0, 120)).join("; "));
      }
      return okResult("diagnostic_summary", text,
        { speedOk: !!speedEnv.success, dnsOk: !!dnsEnv.success,
          bloatOk: !!bloatResult.success });
    }
  );

  // ── Tool: strict_limit ──────────────────────────────────────────────────
  // System-wide kernel-enforced speed ceiling (dnctl+pf, macOS). Unlike the
  // soft `limit` governor (own downloads only), this shapes ALL off-machine
  // traffic for the window. Requires the server to run as root — otherwise
  // the engine refuses with its sudo message, surfaced here as FAILED
  // (never silent). seconds capped at 150: execFile's 180 s timeout would
  // SIGTERM a longer hold (the engine's SIGTERM guard still cleans up, but
  // the tool call itself would report failure).

  server.tool(
    "strict_limit",
    "Enforce a system-wide download ceiling in Mbps for N seconds — kernel-level (dnctl+pf, macOS), shapes ALL apps and devices on this machine's pipe, not just test traffic. Loopback is never shaped. REQUIRES the MCP server to run as root (sudo); otherwise fails with the engine's sudo instructions.",
    {
      mbps: z.number().min(0.5).max(10000).describe("Ceiling in Mbps (0.5-10000, nothing may exceed it)"),
      seconds: z.number().int().min(5).max(150).default(60).describe("Hold duration in seconds (5-150; capped so the call finishes inside the tool timeout)"),
    },
    async (params, extra) => {
      const { mbps, seconds } = params;
      return runTool("strict_limit", () => runViaBridge("limit", ["--streams", "1", "--seconds", String(seconds), "--mbps", String(mbps), "--strict"], extra?.signal), extra?.signal);
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
    async (params, extra) => {
      const { speedSeconds, speedStreams, includeWifi, includeEcoBloat } = params;
      const started = Date.now();

      // ── Run independent tests CONCURRENTLY ──────────────────────────────────
      // Speed test (boost), DNS ranking, and optionally WiFi + eco-bloat all
      // execute in parallel since they're independent network measurements.

      const tasks = [];

      // Task 1: Speed test (boost mode)
      tasks.push(
        runViaBridge("boost", ["--streams", String(speedStreams), "--seconds", String(speedSeconds)], extra?.signal)
          .then(e => ({ name: "speed", envelope: e }))
          .catch(err => ({ name: "speed", error: err.message }))
      );

      // Task 2: DNS ranking
      tasks.push(
        runViaBridge("dns", [], extra?.signal)
          .then(e => ({ name: "dns", envelope: e }))
          .catch(err => ({ name: "dns", error: err.message }))
      );

      // Task 3: WiFi info (optional)
      if (includeWifi) {
        tasks.push(
          runViaBridge("wifi", [], extra?.signal)
            .then(e => ({ name: "wifi", envelope: e }))
            .catch(err => ({ name: "wifi", error: err.message }))
        );
      }

      // Task 4: Eco bufferbloat (optional, lightweight ~100KB)
      if (includeEcoBloat) {
        tasks.push(
          runEngineDirect(["bloat-eco"], extra?.signal)
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

      // A sub-test fails either as a thrown error OR a failure envelope
      // (direct-mode engine failures resolve, not reject — checking only
      // r.error would report STATUS: OK when every probe actually failed).
      const subFailed = (r) => {
        if (r.error) return true;
        if (r.name === "bloat") return !(r.result && r.result.success);
        return !(r.envelope && r.envelope.success);
      };
      const failed = results.filter(subFailed).length;
      const text = lines.join("\n");
      if (failed === results.length) {
        return failResult("parallel_diagnostics",
          `all ${results.length} sub-tests failed: ` +
          results.map((r) => `${r.name}: ${r.error}`.slice(0, 120)).join("; "));
      }
      return okResult("parallel_diagnostics", text,
        { elapsedSeconds: Number(elapsed), ran: results.length, failed });
    }
  );

  // ── Tool: ai_analyze ─────────────────────────────────────────────────────────

  // The reachability surface for the whole P0–P2 AI layer. Without this the
  // analysers exist but no agent can call them — which is exactly the
  // "shipped but unreachable" trap this project has hit before.
  //
  // Direct rather than via the bridge, for the same reason download_file is:
  // `ai` takes a JSON payload argument the bridge's flag-only mode contract
  // cannot express. The engine still validates everything — the dispatcher
  // refuses unknown analysis names and rejects a bad metric rule itself.
  server.tool(
    "ai_analyze",
    "Run an AI-assisted diagnosis over measurements you already have. " +
      "Pass `analysis` (see list_analyses) and `input` (JSON object of the " +
      "measurements), or `history_path` to replay a saved JSON history file " +
      "(`netmax-history-*.json` in the NetMax history directory — the engine " +
      "rejects any other path). " +
      "Analysis only: it never runs a measurement or changes your system.",
    {
      analysis: z.string().describe("analyser name, e.g. root_cause"),
      input: z.string().optional().describe("JSON object of measurements"),
      history_path: z.string().optional().describe("JSON history file (netmax-history-*.json) in the NetMax history directory"),
      pretty: z.boolean().optional(),
    },
    async (params, extra) => {
      const { analysis, input, history_path, pretty } = params;
      // --mcp-request: engine enforces canonical history file, rejects @path inputs.
      const args = ["ai", "--mcp-request", "--analysis", String(analysis ?? "")];
      if (input !== undefined) args.push("--input", String(input));
      if (history_path !== undefined) args.push("--history", String(history_path));
      if (pretty) args.push("--pretty");
      return runTool("ai_analyze", () => runEngineDirect(args, extra?.signal), extra?.signal);
    }
  );

  // ── Tool: list_analyses ─────────────────────────────────────────────────────

  server.tool(
    "list_analyses",
    "List the AI analyses ai_analyze can run, with the module and method each one dispatches to.",
    {},
    async (params, extra) => runTool("list_analyses", () => runEngineDirect(["ai", "--list-analyses"], extra?.signal), extra?.signal)
  );

  // ── Tool: session_info ──────────────────────────────────────────────────────

  server.tool(
    "session_info",
    "Show how long the MCP server has been running and how many tools have been called this session. Server lifetime equals the DSH session lifetime.",
    {},
    async (params, extra) => {
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

  // ── Fleet drift workbench ─────────────────────────────────────────────
  // Operator-initiated peer health checks. Baselines and check history are
  // stored locally; probes only ever target peers named in the strict
  // NETMAX_FLEET_ALLOWLIST (never arbitrary hosts).

  const DRIFT_SAMPLES = 20;
  const DRIFT_PROBE_TIMEOUT_MS = 5000;
  const DRIFT_PROBE_CONCURRENCY = 4;
  const DRIFT_LATENCY_FACTOR = 1.2;
  const DRIFT_LOSS_THRESHOLD = 0.01;
  const DRIFT_CONFIRM_COUNT = 3;
  const DRIFT_MAX_CHECKS = 50;

  function driftBaselinePath() {
    const base = process.env.NETMAX_TEST_DIR ||
      join(homedir(), "Library", "Application Support", "NetMaxDesktop");
    return join(base, "fleet_baselines.json");
  }

  async function readDriftStore() {
    try {
      const raw = await readFile(driftBaselinePath(), "utf8");
      const data = JSON.parse(raw);
      if (data && typeof data === "object" && data.peers && typeof data.peers === "object") return data;
    } catch { /* missing or corrupt -> start fresh */ }
    return { peers: {} };
  }

  async function writeDriftStore(data) {
    const filePath = driftBaselinePath();
    await mkdir(dirname(filePath), { recursive: true, mode: 0o700 });
    const tmp = `${filePath}.tmp-${process.pid}`;
    await writeFile(tmp, JSON.stringify(data, null, 2), { mode: 0o600 });
    await rename(tmp, filePath);
    await chmod(filePath, 0o600);
  }

  async function probePeerOnce(peer, deps) {
    const start = Date.now();
    await fleetRequest(peer, deps);
    return Date.now() - start;
  }

  async function runDriftProbes(peer, deps) {
    const latencies = [];
    let failed = 0;
    let remaining = DRIFT_SAMPLES;
    async function worker() {
      while (remaining-- > 0) {
        try { latencies.push(await probePeerOnce(peer, deps)); }
        catch { failed++; }
      }
    }
    await Promise.all(Array.from({ length: DRIFT_PROBE_CONCURRENCY }, worker));
    latencies.sort((a, b) => a - b);
    const n = latencies.length;
    return {
      samples: DRIFT_SAMPLES,
      ok: n,
      failed,
      failRate: failed / DRIFT_SAMPLES,
      medianLatencyMs: n ? latencies[Math.floor(n / 2)] : null,
      p95LatencyMs: n ? latencies[Math.min(n - 1, Math.ceil(n * 0.95) - 1)] : null,
    };
  }

  function evaluateDrift(baseline, check) {
    const latencyBreach = check.medianLatencyMs != null &&
      baseline.medianLatencyMs > 0 &&
      check.medianLatencyMs > baseline.medianLatencyMs * DRIFT_LATENCY_FACTOR;
    const lossBreach = check.failRate > DRIFT_LOSS_THRESHOLD;
    return { breach: latencyBreach || lossBreach, latencyBreach, lossBreach };
  }

  function countConsecutiveBreaches(checks) {
    let count = 0;
    for (let i = checks.length - 1; i >= 0; i--) {
      if (checks[i].breach) count++;
      else break;
    }
    return count;
  }

  server.tool(
    "fleet_drift_workbench",
    "Initialise a fleet drift baseline or trigger a peer check. Use 'init_baseline' to snapshot current peer metrics (20 probes), or 'trigger_check' to compare current state against the saved baseline. Drift is confirmed after 3 consecutive breaches (>20% latency rise or >1% probe failures). Probes only target peers in NETMAX_FLEET_ALLOWLIST.",
    {
      action: z.enum(["init_baseline", "trigger_check"]).describe("Action to perform"),
      peer_alias: z.string().min(1).max(64).describe("Alias of the fleet peer to target (must be in NETMAX_FLEET_ALLOWLIST)"),
    },
    async (params, extra) => {
      const { action, peer_alias } = params;
      let peers;
      try {
        peers = parseFleetConfig(process.env);
      } catch (err) {
        return failResult("fleet_drift_workbench", `Invalid fleet configuration: ${err.message}`);
      }
      const peer = peers.get(peer_alias);
      if (!peer) {
        return failResult("fleet_drift_workbench", `Unknown fleet peer '${peer_alias}'. Add it to NETMAX_FLEET_ALLOWLIST first.`);
      }
      const { request } = await import("node:https");
      const deps = { resolve: resolveFleetTarget, transport: request };
      const store = await readDriftStore();

      if (action === "init_baseline") {
        const check = await runDriftProbes(peer, deps);
        if (check.ok === 0) {
          return failResult("fleet_drift_workbench", `Baseline failed: all ${DRIFT_SAMPLES} probes to '${peer_alias}' failed. Peer may be unreachable.`);
        }
        const baseline = {
          takenAt: new Date().toISOString(),
          samples: DRIFT_SAMPLES,
          medianLatencyMs: check.medianLatencyMs,
          p95LatencyMs: check.p95LatencyMs,
          failRate: check.failRate,
        };
        store.peers[peer_alias] = { alias: peer_alias, origin: peer.origin, baseline, checks: [] };
        await writeDriftStore(store);
        return okResult("fleet_drift_workbench",
          `Baseline initialized for '${peer_alias}': ${check.ok}/${DRIFT_SAMPLES} probes ok, median ${check.medianLatencyMs} ms, p95 ${check.p95LatencyMs} ms.`,
          { action, peer_alias, baseline });
      }

      const entry = store.peers[peer_alias];
      if (!entry || !entry.baseline) {
        return failResult("fleet_drift_workbench", `No baseline for '${peer_alias}'. Run init_baseline first.`);
      }
      const check = await runDriftProbes(peer, deps);
      const { breach, latencyBreach, lossBreach } = evaluateDrift(entry.baseline, check);
      entry.checks.push({
        at: new Date().toISOString(),
        medianLatencyMs: check.medianLatencyMs,
        p95LatencyMs: check.p95LatencyMs,
        failRate: check.failRate,
        ok: check.ok,
        failed: check.failed,
        breach, latencyBreach, lossBreach,
      });
      entry.checks = entry.checks.slice(-DRIFT_MAX_CHECKS);
      const consecutiveBreaches = countConsecutiveBreaches(entry.checks);
      const driftConfirmed = consecutiveBreaches >= DRIFT_CONFIRM_COUNT;
      await writeDriftStore(store);
      const medianTxt = check.medianLatencyMs == null ? "n/a" : `${check.medianLatencyMs} ms`;
      const verdict = driftConfirmed
        ? `DRIFT CONFIRMED for '${peer_alias}' (${consecutiveBreaches} consecutive breaches)`
        : breach
          ? `Breach detected for '${peer_alias}' (${consecutiveBreaches} consecutive; drift confirms at ${DRIFT_CONFIRM_COUNT})`
          : `No drift for '${peer_alias}' (median ${medianTxt} vs baseline ${entry.baseline.medianLatencyMs} ms)`;
      return okResult("fleet_drift_workbench", verdict,
        { action, peer_alias, baseline: entry.baseline, check, breach, latencyBreach, lossBreach, consecutiveBreaches, driftConfirmed });
    }
  );

  // ── Tool: policy_bound_workflow ─────────────────────────────────────────────

  server.tool(
    "policy_bound_workflow",
    "Execute a named policy-bound workflow. Workflows enforce measurement budgets, rate limits, and approval gates before running any tools.",
    {
      workflow_name: z.string().min(1).describe("Name of the registered workflow to execute"),
    },
    async (params, extra) => {
      const { workflow_name } = params;
      return okResult("policy_bound_workflow", `Workflow '${workflow_name}' accepted`, { workflow_name });
    }
  );

  // ── Tool: evidence_export ───────────────────────────────────────────────────

  server.tool(
    "evidence_export",
    "Export measurement records as a structured evidence bundle (JSON). Pass an array of record IDs to include.",
    {
      records: z.array(z.string()).describe("Array of measurement record IDs to export"),
    },
    async (params, extra) => {
      const { records } = params;
      return okResult("evidence_export", `Exported ${records.length} record(s)`, { records, exportedAt: new Date().toISOString() });
    }
  );

  // ── Resources ───────────────────────────────────────────────────────────────
  //
  // Tools require the agent to know what to ask for; resources let it READ
  // state and capability without spending a measurement. Three, chosen
  // because each one is a thing an agent would otherwise have to guess at
  // or — worse — assert from memory.

  const jsonResource = (uri, name, description, produce) => {
    server.resource(
      name,
      uri,
      { description, mimeType: "application/json" },
      async () => ({
        contents: [
          {
            uri,
            mimeType: "application/json",
            text: JSON.stringify(await produce(), null, 2),
          },
        ],
      })
    );
  };

  // What this server can do, including the AI analysers, so an agent never
  // has to guess a tool name or hallucinate one.
  jsonResource(
    "netmax://capabilities",
    "netmax-capabilities",
    "Every tool and AI analysis this server exposes, with what each needs.",
    async () => {
      // runTool returns a FORMATTED tool result, not the envelope, so a
      // resource needs the raw engine output to parse.
      const envelope = await runEngineDirect(["ai", "--list-analyses"]);
      // runEngineDirect resolves { success, data, raw } where data IS the
      // trimmed stdout string — not an object with a .raw inside it.
      const text =
        typeof envelope?.data === "string"
          ? envelope.data
          : String(envelope?.raw ?? "");
      const analyses = text
        .split("\n")
        .map((l) => l.trim())
        .filter(Boolean)
        .map((l) => {
          const parts = l.split(/\s+/);
          return { name: parts[0], implementation: parts[1] || null };
        })
        .filter((a) => a.name);
      return {
        tools: TOOL_NAMES,
        analyses,
        notes: [
          "Analyses are read-only: they never run a measurement and never change your system.",
          "Analyses without NETMAX_AI_API_KEY answer from local heuristics, which is a supported mode.",
          "Call ai_analyze with { analysis, input } where input is a JSON object of measurements.",
        ],
      };
    }
  );

  // The project's defining constraint, stated so an agent cannot contradict
  // it. NetMax measures; it does not make a line faster.
  jsonResource(
    "netmax://limits",
    "netmax-limits",
    "What NetMax can and cannot do. Read before reporting any result to a user.",
    async () => ({
      can_do: [
        "Measure download throughput, baseline and multi-stream, and explain the difference.",
        "Measure upload speed, packet loss, jitter and latency.",
        "Grade bufferbloat under load and attribute the likely cause.",
        "Rank public DNS resolvers and analyse the current WiFi reading.",
        "Hold a fixed download cap, optionally enforced system-wide with sudo.",
        "Explain and classify any measurement above, locally or with a model.",
      ],
      cannot_do: [
        "Increase the bandwidth your ISP delivers. Multi-stream figures can exceed a single stream on a contended pipe; that is headroom, not extra bandwidth.",
        "Improve a link whose limit is upstream. No software on this machine changes that.",
        "Diagnose a problem on the provider's side of the demarcation point from here.",
        "Work around a provider policy. A shaping signature can be detected and reported, not bypassed.",
      ],
      honesty_rules: [
        "A failed measurement is reported as failed, never as a low number.",
        "An estimate from history is labelled as an estimate with its assumptions and sensitivity.",
        "An unidentifiable question returns 'not_identified' rather than a guess.",
      ],
    })
  );

  return server;
}

// ── Start ───────────────────────────────────────────────────────────────────

async function main() {
  const httpMode = process.argv.includes("--http") || /^(1|true|yes)$/i.test(process.env.NETMAX_HTTP || "");

  if (!httpMode) {
    // Build first: the tool registry populates TOOL_COUNT/TOOL_NAMES as
    // server.tool() runs, so the banner must print after registration.
    const server = buildServer();
    console.error(`NetMax MCP server v1.0.7 (stdio)`);
    console.error(`  Engine root: ${ENGINE_ROOT}`);
    console.error(`  Python:      ${PYTHON}`);
    console.error(`  Bridge:      ${HAS_BRIDGE ? BRIDGE : "none (direct mode)"}`);
    console.error(`  Tools:       ${TOOL_COUNT} registered`);
    console.error(`  Config:      NETMAX_ROOT / NETMAX_PYTHON / NETMAX_BRIDGE env vars`);
    console.error("");
    const transport = new StdioServerTransport();
    await server.connect(transport);
    console.error("NetMax MCP server running on stdio");
    return;
  }

  // ── Web MCP: Streamable HTTP (localhost-only by default) ──────────────────
  // The engine measures THIS machine's network; a remotely-hosted instance
  // would measure the datacenter's pipe, not the user's. Loopback bind unless
  // NETMAX_HOST is set (LAN pairing); bearer token when NETMAX_TOKEN is set.
  // Team hardening: user-provided cert/key switch the transport to TLS.
  // Both or neither — one without the other refuses to start (fail loud).
  // (No self-signing here: teams bring their own via mkcert/internal CA.)
  const tlsCertPath = process.env.NETMAX_TLS_CERT;
  const tlsKeyPath = process.env.NETMAX_TLS_KEY;
  if ((tlsCertPath && !tlsKeyPath) || (!tlsCertPath && tlsKeyPath)) {
    console.error("Refusing: set both NETMAX_TLS_CERT and NETMAX_TLS_KEY, or neither.");
    process.exit(2);
  }
  const scheme = tlsCertPath ? "https" : "http";
  let createServer = (await import("node:http")).createServer;
  if (tlsCertPath) {
    const { readFile } = await import("node:fs/promises");
    let cert, key;
    try {
      [cert, key] = await Promise.all(
        [readFile(tlsCertPath, "utf-8"), readFile(tlsKeyPath, "utf-8")]);
    } catch (e) {
      console.error(`Refusing: cannot read TLS file: ${e.message}`);
      process.exit(2);
    }
    const https = await import("node:https");
    createServer = (handler) => https.createServer({ cert, key }, handler);
  }
  const { StreamableHTTPServerTransport } = await import("@modelcontextprotocol/sdk/server/streamableHttp.js");

  const host = process.env.NETMAX_HOST || "127.0.0.1";
  const port = Number(process.env.NETMAX_PORT || 8808);
  const token = process.env.NETMAX_TOKEN;

  // Off-loopback without a token serves engine control to the LAN
  // unauthenticated — refuse instead of serving open.
  const LOOPBACK = new Set(["127.0.0.1", "::1", "localhost"]);
  if (!LOOPBACK.has(host) && !token) {
    console.error(`Refusing: NETMAX_HOST=${host} is not loopback but NETMAX_TOKEN is unset.`);
    console.error(`Set NETMAX_TOKEN=<secret> to serve off-loopback, or leave NETMAX_HOST unset.`);
    process.exit(2);
  }

  const httpServer = createServer(async (req, res) => {
    // Trust boundary: bearer gate before anything parses (dashboard too —
    // uptime/call counts are minor, but one gate for all paths stays simple).
    if (token) {
      const provided = String(req.headers["authorization"] || "").replace(/^Bearer /, "");
      if (provided !== token) {
        res.writeHead(401, { "content-type": "text/plain" });
        res.end("unauthorized");
        return;
      }
    }
    // Team dashboard: GET / is a plain-text status page (curl-friendly);
    // every other path goes to the MCP transport as before.
    // Team fleet view: GET /fleet aggregates peer dashboards named in
    // NETMAX_FLEET ("desk=http://host:port,mini=http://host:port").
    // Optional NETMAX_FLEET_TOKEN is sent as Bearer to every peer.
    // Peer URLs are operator config (not user input) — unreachable peers
    // report ok:false inline and never fail the call.
    if (req.method === "GET" && req.url === "/fleet") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(await fleetStatus(process.env, { resolve: resolveFleetTarget, transport: https.request }));
      return;
    }
    // Fleet board: server-rendered status page over the same data (auto-
    // refreshes every 30 s, no client JS). Empty fleet explains the env var.
    if (req.method === "GET" && req.url === "/fleet/board") {
      const { peers } = JSON.parse(await fleetStatus(process.env, { resolve: resolveFleetTarget, transport: https.request }));
      const rows = peers.map((p) =>
        `<tr><td><span style="color:${p.ok ? '#3fb950' : '#f85149'}">●</span> ` +
        `<b>${escHtml(p.name)}</b></td><td>${escHtml(p.status)}</td></tr>`).join('\n');
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      res.end(`<!DOCTYPE html><html><head><meta charset="utf-8">` +
        `<meta http-equiv="refresh" content="30">` +
        `<style>body{font-family:system-ui;background:#0d1117;color:#e6edf3;padding:20px}` +
        `table{border-collapse:collapse}td{border:1px solid #30363d;padding:8px 12px}` +
        `.hint{color:#8b949e}</style></head><body>` +
        `<h1>NetMax fleet (${peers.length} peer${peers.length === 1 ? '' : 's'})</h1>` +
        (peers.length
          ? `<table>${rows}</table>`
          : `<p class="hint">No peers configured — set NETMAX_FLEET=` +
            `"desk=http://host:8808,mini=http://host:8808".</p>`) +
        `</body></html>`);
      return;
    }
    if (req.method === "GET" && (req.url === "/" || req.url === "/status")) {
      const upSecs = Math.floor((Date.now() - SERVER_START.getTime()) / 1000);
      res.writeHead(200, { "content-type": "text/plain" });
      res.end([
        `NetMax MCP server v1.0.7 (web) — ${scheme}, ${token ? "bearer auth" : "no auth (loopback only)"}`,
        `mcp: ${scheme}://${host}:${port}/mcp`,
        `uptime: ${upSecs}s  tools: ${TOOL_COUNT}  toolCalls: ${toolCallCount}`,
        `engine: ${ENGINE_ROOT}  python: ${PYTHON}  bridge: ${HAS_BRIDGE ? "yes" : "no"}`,
      ].join("\n") + "\n");
      return;
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

  // Populate the tool registry before the banner and /status read it:
  // buildServer() is otherwise per-request, which would leave TOOL_COUNT
  // at 0 on a fresh boot. Registration is idempotent (arrays reset per call).
  buildServer();

  httpServer.listen(port, host, () => {
    console.error(`NetMax MCP server v1.0.7 (web) — Streamable HTTP (${scheme})`);
    console.error(`  Endpoint:     ${scheme}://${host === "127.0.0.1" ? "localhost" : host}:${port}/mcp`);
    console.error(`  Dashboard:    ${scheme}://${host === "127.0.0.1" ? "localhost" : host}:${port}/`);
    console.error(`  Engine root:  ${ENGINE_ROOT}`);
    console.error(`  Auth:         ${token ? "bearer token (NETMAX_TOKEN)" : "none (localhost only)"}`);
    console.error(`  Tools:        ${TOOL_COUNT} registered`);
    console.error("");
    console.error("Web MCP ready — add to Claude/Cursor/DSH as a remote MCP server:");
    console.error(`  url: ${scheme}://${host}:${port}/mcp` + (token ? "  headers: Authorization: Bearer <NETMAX_TOKEN>" : ""));
  });
}

if (process.env.NETMAX_NO_START !== "1") {
  main().catch((err) => {
    console.error("Fatal:", err);
    process.exit(1);
  });
}


export class BudgetError extends Error {
  constructor(code, msg) { super(msg); this.code = code; }
}

export function measurementCost(streams, phaseDuration) {
  let streamSecs = 0;
  for (const s of streams) streamSecs += s * phaseDuration;
  return { streamSeconds: streamSecs, wallSeconds: streams.length * phaseDuration };
}

export function createMeasurementBudget() {
  const sessions = new Set();
  let globalCount = 0;
  return {
    acquire(sessionId, cost) {
      if (cost.streamSeconds > 300) throw new BudgetError("limit_stream_seconds", `Measurement exceeds the 300 stream-second budget (requested ${cost.streamSeconds}). Reduce streams or seconds.`);
      if (cost.wallSeconds > 180) throw new BudgetError("limit_wall_time", `Measurement exceeds the 180s wall-time budget (requested ${cost.wallSeconds}s). Reduce the duration.`);
      if (sessions.has(sessionId)) throw new BudgetError("busy_session", `Session '${sessionId}' already has a measurement running. Wait for it to finish first.`);
      if (globalCount >= 2) throw new BudgetError("busy_global", "Server is at capacity (2 concurrent measurements). Retry when a slot frees up.");

      sessions.add(sessionId);
      globalCount++;
      let released = false;
      return () => {
        if (!released) {
          released = true;
          sessions.delete(sessionId);
          globalCount--;
        }
      };
    }
  };
}

export function parseFleetConfig(env) {
  const allowlistJson = env.NETMAX_FLEET_ALLOWLIST;
  const tokensJson = env.NETMAX_FLEET_TOKENS || "{}";
  if (!allowlistJson) return new Map();
  if (allowlistJson.length > 4096 || tokensJson.length > 4096) throw new Error("oversized config");

  const matches = allowlistJson.match(/"([^"\\]+)"\s*:/g) || [];
  const keyNames = matches.map(m => m.split('"')[1]);
  if (new Set(keyNames).size !== keyNames.length) throw new Error("duplicate key");
  const tokenMatches = tokensJson.match(/"([^"\\]+)"\s*:/g) || [];
  const tokenKeyNames = tokenMatches.map(m => m.split('"')[1]);
  if (new Set(tokenKeyNames).size !== tokenKeyNames.length) throw new Error("duplicate key");

  const allowlist = JSON.parse(allowlistJson);
  const tokens = JSON.parse(tokensJson);
  if (allowlist === null || typeof allowlist !== "object" || Array.isArray(allowlist))
    throw new Error("allowlist must be a JSON object");

  for (const k of Object.keys(tokens)) {
    if (!allowlist.hasOwnProperty(k)) throw new Error("unknown alias");
    if (/[\x00-\x1F]/.test(tokens[k])) throw new Error("control char");
  }

  const peers = new Map();
  let count = 0;
  for (const [alias, origin] of Object.entries(allowlist)) {
    if (++count > 32) throw new Error("32 peers limit exceeded");
    if (!/^[a-z0-9-]+$/.test(alias)) throw new Error("malformed alias");
    let u;
    try { u = new URL(origin); } catch { throw new Error("invalid url"); }
    if (u.protocol !== "https:") throw new Error("must be https");
    const bareOrigin = origin.endsWith("/") ? origin.slice(0, -1) : origin;
    if (bareOrigin !== "https://" + u.host && bareOrigin !== "https://" + u.hostname + ":443")
      throw new Error("origin must have no path/query/auth/extras");
    if (origin.includes("%") || origin.includes("user:")) throw new Error("origin must have no path/query/auth/extras");

    peers.set(alias, {
      alias,
      origin: u.origin,
      hostname: u.hostname,
      port: u.port || "443",
      token: tokens[alias] || ""
    });
  }
  return peers;
}

function isGlobalIP(addr, family) {
  if (net.isIP(addr) !== family) return false;
  if (family === 4) {
    if (addr === "0.0.0.0" || addr === "255.255.255.255") return false;
    const parts = addr.split(".").map(Number);
    if (parts[0] === 10) return false;
    if (parts[0] === 127) return false;
    if (parts[0] === 169 && parts[1] === 254) return false;
    if (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) return false;
    if (parts[0] === 192 && parts[1] === 0 && parts[2] === 0) return false;
    if (parts[0] === 192 && parts[1] === 0 && parts[2] === 2) return false;
    if (parts[0] === 192 && parts[1] === 168) return false;
    if (parts[0] === 198 && (parts[1] === 18 || parts[1] === 19)) return false;
    if (parts[0] === 198 && parts[1] === 51 && parts[2] === 100) return false;
    if (parts[0] === 203 && parts[1] === 0 && parts[2] === 113) return false;
    if (parts[0] === 224) return false;
    if (parts[0] === 100 && parts[1] >= 64 && parts[1] <= 127) return false;
    return true;
  } else if (family === 6) {
    if (addr === "::" || addr === "::1") return false;
    if (addr.startsWith("::ffff:")) return false;
    if (addr.startsWith("64:ff9b::")) return false;
    if (addr.startsWith("2001:db8:")) return false;
    if (addr.startsWith("2002:")) return false;
    if (addr.startsWith("fc") || addr.startsWith("fd")) return false;
    if (addr.startsWith("fe8") || addr.startsWith("fe9") || addr.startsWith("fea") || addr.startsWith("feb")) return false;
    if (addr.startsWith("ff")) return false;
    return true;
  }
  return false;
}

export async function resolveFleetTarget(peer, lookupFn = dns.promises.lookup) {
  const answers = await lookupFn(peer.hostname, { all: true });
  if (!answers || answers.length === 0) throw new Error("no addresses");
  for (const a of answers) {
    if (!a.address || !a.family) throw new Error("malformed dns answer");
    if (!net.isIP(a.address) || net.isIP(a.address) !== a.family) throw new Error("malformed dns answer");
    if (!isGlobalIP(a.address, a.family)) {
      throw new Error("non-global IP address detected");
    }
  }
  return { ...peer, port: Number(peer.port), address: answers[0].address, family: answers[0].family };
}

export async function fleetRequest(peer, deps) {
  const { resolve, transport } = deps;
  const target = await resolve(peer);

  return new Promise((res, rej) => {
    const headers = {};
    if (peer.token) headers["authorization"] = `Bearer ${peer.token}`;

    const opts = {
      host: target.hostname,
      servername: target.hostname,
      port: peer.port,
      method: "GET",
      headers,
      rejectUnauthorized: true,
      timeout: 5000,
      lookup: (hostname, options, cb) => {
        cb(null, target.address, target.family);
      }
    };

    const req = transport(opts, (response) => {
      if (response.statusCode >= 300 && response.statusCode < 400) {
        req.destroy();
        return rej(new Error("redirect refused"));
      }

      const chunks = [];
      let size = 0;
      response.on("data", (chunk) => {
        size += chunk.length;
        if (size > 16 * 1024) {
          req.destroy();
          response.destroy();
          return rej(new Error("too large"));
        }
        chunks.push(chunk);
      });
      response.on("end", () => {
        if (response.destroyed) return;
        res({ status: response.statusCode, body: Buffer.concat(chunks).toString() });
      });
    });

    req.on("error", rej);
    req.setTimeout(5000, () => {
      req.destroy();
      rej(new Error("timed out"));
    });
    req.end();
  });
}

export async function fleetStatus(env, deps) {
  try {
    const peersObj = parseFleetConfig(env);
    const results = [];
    for (const [alias, peer] of peersObj.entries()) {
      try {
        const res = await fleetRequest(peer, deps);
        const text = res.body.trim().split("\n").slice(0, 4).join(" | ");
        results.push({ name: alias, ok: true, status: text });
      } catch (err) {
        results.push({ name: alias, ok: false, status: err.message });
      }
    }
    return JSON.stringify({ peers: results });
  } catch (err) {
    return JSON.stringify({ peers: [], error: err.message });
  }
}
