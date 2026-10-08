import { URL } from "url";
import dns from "dns";
import https from "https";

export function parseFleetConfig(allowlistJson, tokensJson = "{}") {
  if (!allowlistJson) return {};
  if (allowlistJson.length > 4096 || tokensJson.length > 4096) throw new Error("oversized config");
  const allowlist = JSON.parse(allowlistJson);
  const tokens = JSON.parse(tokensJson);
  const peers = {};
  let count = 0;
  for (const [alias, origin] of Object.entries(allowlist)) {
    if (++count > 32) throw new Error("32 peers limit exceeded");
    let u;
    try { u = new URL(origin); } catch { throw new Error("invalid url"); }
    if (u.protocol !== "https:") throw new Error("must be https");
    if (u.pathname !== "/" || u.search || u.hash || u.username || u.password) throw new Error("origin must have no path/query/auth");
    
    peers[alias] = {
      alias,
      hostname: u.hostname,
      port: u.port || "443",
      token: tokens[alias] || ""
    };
  }
  return peers;
}

function isGlobalIP(addr, family) {
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
    if (!isGlobalIP(a.address, a.family)) {
      throw new Error("non-global IP address detected");
    }
  }
  return { ...peer, address: answers[0].address, family: answers[0].family };
}

export async function fleetRequest(peer, deps) {
  const { resolve, transport } = deps;
  const target = await resolve(peer);
  
  return new Promise((res, rej) => {
    const headers = {};
    if (peer.token) headers["authorization"] = `Bearer ${peer.token}`;
    
    const opts = {
      host: peer.hostname,
      servername: peer.hostname,
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
    const peersObj = parseFleetConfig(env.NETMAX_FLEET_ALLOWLIST, env.NETMAX_FLEET_TOKENS_JSON);
    const results = [];
    for (const [alias, peer] of Object.entries(peersObj)) {
      try {
        const res = await fleetRequest(peer, deps);
        results.push({ name: alias, ok: true, status: res.body.replace(/\n/g, " | ") });
      } catch (err) {
        results.push({ name: alias, ok: false, status: err.message });
      }
    }
    return JSON.stringify({ peers: results });
  } catch (err) {
    return JSON.stringify({ peers: [], error: err.message });
  }
}

export class BudgetError extends Error {}

export function createMeasurementBudget(statsPath) {
  let spend = 0;
  return {
    spend: (amount) => {
      spend += amount;
      if (spend > 100 * 1024 * 1024) throw new BudgetError("budget exceeded");
    }
  };
}

export function measurementCost() {
  return 1024;
}
