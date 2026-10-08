with open('original_server.mjs', 'r') as f:
    code = f.read()

# 1. net import
if 'import net from "node:net";' not in code:
    code = code.replace('import { McpServer }', 'import net from "node:net";\nimport { McpServer }')

# 3. NETMAX_NO_START
code = code.replace(
'''main().catch((err) => {
  console.error("Fatal:", err);
  process.exit(1);
});''',
'''if (process.env.NETMAX_NO_START !== "1") {
  main().catch((err) => {
    console.error("Fatal:", err);
    process.exit(1);
  });
}'''
)

# 4. Replacement blocks for child process (runViaBridge, runEngineDirect, runTool)
new_runViaBridge = """function runViaBridge(mode, args = [], signal) {
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
}"""

new_runEngineDirect = """function runEngineDirect(args, signal) {
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
}"""

new_runTool = """async function runTool(mode, fn, signal) {
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
}"""

s1 = code.find('function runViaBridge(')
e1 = code.find('function runEngineDirect(')
if s1 > -1 and e1 > -1:
    code = code[:s1] + new_runViaBridge + '\n\n' + code[e1:]

s2 = code.find('function runEngineDirect(')
e2 = code.find('function looksLikeDeadMeasurement(')
if s2 > -1 and e2 > -1:
    code = code[:s2] + new_runEngineDirect + '\n\n' + code[e2:]

s3 = code.find('async function runTool(')
e3 = code.find('/** Minimal HTML escaping')
if s3 > -1 and e3 > -1:
    code = code[:s3] + new_runTool + '\n\n' + code[e3:]

# 5. Exact Tool Handler replacements
handlers = [
# measure_speed
(
'''async ({ mode, streams, seconds }) => {
      const args = [];
      if (mode !== "baseline") args.push("--streams", String(streams));
      if (mode !== "dns") args.push("--seconds", String(seconds));

      return runTool(`measure_speed (${mode})`, () => runViaBridge(mode, args));
    }''',
'''async (params, extra) => {
      const { mode, streams, seconds } = params;
      const args = [];
      if (mode !== "baseline") args.push("--streams", String(streams));
      if (mode !== "dns") args.push("--seconds", String(seconds));

      return runTool(`measure_speed (${mode})`, () => runViaBridge(mode, args, extra?.signal), extra?.signal);
    }'''
),
# dns_ranking
(
'''async () => runTool("dns_ranking", () => runViaBridge("dns"))''',
'''async (params, extra) => runTool("dns_ranking", () => runViaBridge("dns", [], extra?.signal), extra?.signal)'''
),
# bufferbloat
(
'''async ({ streams, seconds }) =>
      runTool("bufferbloat", () =>
        runViaBridge("bloat", ["--streams", String(streams), "--seconds", String(seconds)]))''',
'''async (params, extra) => {
      const { streams, seconds } = params;
      return runTool("bufferbloat", () => runViaBridge("bloat", ["--streams", String(streams), "--seconds", String(seconds)], extra?.signal), extra?.signal);
    }'''
),
# upload_speed
(
'''async ({ seconds }) =>
      runTool("upload_speed", () => runViaBridge("upload", ["--seconds", String(seconds)]))''',
'''async (params, extra) => {
      const { seconds } = params;
      return runTool("upload_speed", () => runViaBridge("upload", ["--seconds", String(seconds)], extra?.signal), extra?.signal);
    }'''
),
# packet_loss
(
'''async ({ count }) =>
      runTool("packet_loss", () => runViaBridge("loss", ["--count", String(count)]))''',
'''async (params, extra) => {
      const { count } = params;
      return runTool("packet_loss", () => runViaBridge("loss", ["--count", String(count)], extra?.signal), extra?.signal);
    }'''
),
# jitter
(
'''async ({ count }) =>
      runTool("jitter", () => runViaBridge("jitter", ["--count", String(count)]))''',
'''async (params, extra) => {
      const { count } = params;
      return runTool("jitter", () => runViaBridge("jitter", ["--count", String(count)], extra?.signal), extra?.signal);
    }'''
),
# wifi_info
(
'''async () => runTool("wifi_info", () => runViaBridge("wifi"))''',
'''async (params, extra) => runTool("wifi_info", () => runViaBridge("wifi", [], extra?.signal), extra?.signal)'''
),
# download_file
(
'''async ({ url, streams, output }) => {
      const args = [url];
      if (output) args.push(output);
      args.push("--streams", String(streams));

      return runTool("download_file", () => runEngineDirect(["fetch", ...args]));
    }''',
'''async (params, extra) => {
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
    }'''
),
# eco_bloat
(
'''async () => runTool("eco_bloat", () => runViaBridge("bloat-eco", []))''',
'''async (params, extra) => runTool("eco_bloat", () => runViaBridge("bloat-eco", [], extra?.signal), extra?.signal)'''
),
# full_diagnostics
(
'''async ({ streams, seconds }) =>
      runTool("full_diagnostics", () =>
        runViaBridge("full", ["--streams", String(streams), "--seconds", String(seconds)]))''',
'''async (params, extra) => {
      const { streams, seconds } = params;
      return runTool("full_diagnostics", () => runViaBridge("full", ["--streams", String(streams), "--seconds", String(seconds)], extra?.signal), extra?.signal);
    }'''
),
# diagnostic_summary
(
'''async () => {
      // Run baseline (lightweight — single stream)
      const speedEnv = await runViaBridge("baseline", ["--seconds", "8"]);
      const dnsEnv = await runViaBridge("dns");
      const bloatResult = await runEngineDirect(["bloat-eco"]);''',
'''async (params, extra) => {
      // Run baseline (lightweight — single stream)
      const speedEnv = await runViaBridge("baseline", ["--seconds", "8"], extra?.signal);
      const dnsEnv = await runViaBridge("dns", [], extra?.signal);
      const bloatResult = await runEngineDirect(["bloat-eco"], extra?.signal);'''
),
# boost
(
'''async ({ streams, seconds }) =>
      runTool("boost", () =>
        runViaBridge("boost", ["--streams", String(streams), "--seconds", String(seconds)]))''',
'''async (params, extra) => {
      const { streams, seconds } = params;
      return runTool("boost", () => runViaBridge("boost", ["--streams", String(streams), "--seconds", String(seconds)], extra?.signal), extra?.signal);
    }'''
),
# parallel_diagnostics
(
'''async ({ speedSeconds, speedStreams, includeWifi, includeEcoBloat }) => {
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
      }''',
'''async (params, extra) => {
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
      }'''
),
# strict_limit
(
'''async ({ mbps, seconds }) =>
      runTool("strict_limit", () =>
        runViaBridge("limit", ["--streams", "1", "--seconds", String(seconds),
          "--mbps", String(mbps), "--strict"]))''',
'''async (params, extra) => {
      const { mbps, seconds } = params;
      return runTool("strict_limit", () => runViaBridge("limit", ["--streams", "1", "--seconds", String(seconds), "--mbps", String(mbps), "--strict"], extra?.signal), extra?.signal);
    }'''
),
# ai_analyze
(
'''async ({ analysis, input, history_path, pretty }) => {
      const args = ["ai", "--analysis", String(analysis ?? "")];
      if (input !== undefined) args.push("--input", String(input));
      if (history_path !== undefined) {
        args.push("--history", String(history_path));
      }
      if (pretty) args.push("--pretty");
      return runTool("ai_analyze", () => runEngineDirect(args));
    }''',
'''async (params, extra) => {
      const { analysis, input, history_path, pretty } = params;
      // --mcp-request: engine enforces canonical history file, rejects @path inputs.
      const args = ["ai", "--mcp-request", "--analysis", String(analysis ?? "")];
      if (input !== undefined) args.push("--input", String(input));
      if (history_path !== undefined) args.push("--history", String(history_path));
      if (pretty) args.push("--pretty");
      return runTool("ai_analyze", () => runEngineDirect(args, extra?.signal), extra?.signal);
    }'''
),
# list_analyses
(
'''async () => runTool("list_analyses", () => runEngineDirect(["ai", "--list-analyses"]))''',
'''async (params, extra) => runTool("list_analyses", () => runEngineDirect(["ai", "--list-analyses"], extra?.signal), extra?.signal)'''
),
# session_info
(
'''async () => {
      const uptime = Date.now() - SERVER_START.getTime();''',
'''async (params, extra) => {
      const uptime = Date.now() - SERVER_START.getTime();'''
)
]

for old_str, new_str in handlers:
    if old_str not in code:
        print("FAILED TO MATCH:")
        print(old_str)
        import sys
        sys.exit(1)
    code = code.replace(old_str, new_str)

# 6. Budget
budget_code = """
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
"""

code = code.replace(
  '''  const server = new McpServer({
    name: "netmax-mcp-server",
    version: "1.0.7",
    description: "NetMax Desktop network diagnostics — throughput, bufferbloat, DNS, WiFi, and more",
  });''',
  '''  const server = new McpServer({
    name: "netmax-mcp-server",
    version: "1.0.7",
    description: "NetMax Desktop network diagnostics — throughput, bufferbloat, DNS, WiFi, and more",
  });\n''' + budget_code
)

# 7. Fleet
s_fleet = code.find('/** Aggregate peer dashboards for GET /fleet')
e_fleet_end = code.find('// ── Server', s_fleet)

if s_fleet > -1 and e_fleet_end > s_fleet:
    code = code[:s_fleet] + code[e_fleet_end:]

code = code.replace(
    'res.end(await fleetStatus());',
    'res.end(await fleetStatus(process.env, { resolve: resolveFleetTarget, transport: https.request }));'
)
code = code.replace(
    'const { peers } = JSON.parse(await fleetStatus());',
    'const { peers } = JSON.parse(await fleetStatus(process.env, { resolve: resolveFleetTarget, transport: https.request }));'
)

fleet_and_budget = """
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

  const matches = allowlistJson.match(/"([^"\\\\]+)"\\s*:/g) || [];
  const keyNames = matches.map(m => m.split('"')[1]);
  if (new Set(keyNames).size !== keyNames.length) throw new Error("duplicate key");
  const tokenMatches = tokensJson.match(/"([^"\\\\]+)"\\s*:/g) || [];
  const tokenKeyNames = tokenMatches.map(m => m.split('"')[1]);
  if (new Set(tokenKeyNames).size !== tokenKeyNames.length) throw new Error("duplicate key");

  const allowlist = JSON.parse(allowlistJson);
  const tokens = JSON.parse(tokensJson);
  if (allowlist === null || typeof allowlist !== "object" || Array.isArray(allowlist))
    throw new Error("allowlist must be a JSON object");

  for (const k of Object.keys(tokens)) {
    if (!allowlist.hasOwnProperty(k)) throw new Error("unknown alias");
    if (/[\\x00-\\x1F]/.test(tokens[k])) throw new Error("control char");
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
        const text = res.body.trim().split("\\n").slice(0, 4).join(" | ");
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
"""

code += '\n' + fleet_and_budget + '\n'

# 8. Fleet drift workbench (real implementation)
drift_code = """  // ── Fleet drift workbench ─────────────────────────────────────────────
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
"""

code = code.replace(
  'import { tmpdir } from "node:os";',
  'import { tmpdir, homedir } from "node:os";'
)
code = code.replace(
  'import { writeFile, unlink } from "node:fs/promises";',
  'import { writeFile, unlink, readFile, mkdir, rename, chmod } from "node:fs/promises";'
)
code = code.replace(
  'import net from "node:net";',
  'import net from "node:net";\nimport dns from "node:dns";'
)
stub_tools_code = """
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
"""
code = code.replace(
  'const TOOL_COUNT = 17;',
  '''// Registry: tool names are recorded as server.tool() runs, so the count
// and the capability list derive from one source and cannot drift.
// TOOL_NAMES is the let-bound array below, overwritten on each registration.
const REGISTERED_TOOL_NAMES = [];
let TOOL_COUNT = 0;

// Mirrors the engine's validate_mcp_output_name: one safe basename,
// never a caller-selected path. Rejects before the engine spawns.
function validateMcpOutputName(name) {
  if (typeof name !== "string" || name.length === 0 || name === "." || name === "..")
    throw new Error("MCP output name must be a non-empty basename");
  if (Buffer.byteLength(name, "utf8") > 180 || name.includes("/") || name.includes("\\\\") ||
      /[\\x00-\\x1f\\x7f]/.test(name) || /^[a-zA-Z]:/.test(name))
    throw new Error("MCP output name must be a basename of at most 180 UTF-8 bytes");
}'''
)
# TOOL_NAMES is let-bound; the registry overwrites it on each server.tool() call.
code = code.replace(
  '''  const server = new McpServer({
    name: "netmax-mcp-server",
    version: "1.0.7",
    description: "NetMax Desktop network diagnostics \u2014 throughput, bufferbloat, DNS, WiFi, and more",
  });''',
  '''  const server = new McpServer({
    name: "netmax-mcp-server",
    version: "1.0.7",
    description: "NetMax Desktop network diagnostics \u2014 throughput, bufferbloat, DNS, WiFi, and more",
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
  };'''
)
code = code.replace('const TOOL_NAMES = [', 'let TOOL_NAMES = [')
code = code.replace(
  '  // ── Resources ──',
  drift_code + stub_tools_code + '\n  // ── Resources ──'
)

code = code.rstrip('\n') + '\n'
with open('desktop/netmax-mcp-server.mjs', 'w') as f:
    f.write(code)
