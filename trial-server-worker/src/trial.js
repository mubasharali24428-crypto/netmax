/**
 * trial.js — pure trial-registry logic for the NetMax Cloudflare Worker.
 *
 * No Workers / D1 / Node imports here: this module runs unmodified in plain
 * `node` (>= 18, via globalThis.crypto.subtle) and in Cloudflare Workers.
 * D1 access lives behind the store adapter in store.js.
 *
 * TOKEN SCHEME (byte-identical to trial_server/server.py — do not "improve"):
 *   message = "<fp_hex>|<trial_start>|<trial_end>"   (UTF-8 bytes)
 *   token   = HMAC-SHA256(key = secret UTF-8 bytes, message).hexdigest()
 *   fp_hex      = 64 lowercase hex chars (SHA-256 of the hardware UUID string)
 *   trial_start / trial_end = UTC "YYYY-MM-DDTHH:MM:SSZ" (second precision,
 *               no fractional part), trial_end = trial_start + TRIAL_DAYS.
 * The Swift TrialRegistryClient mints/verifies the same way, so any change
 * here breaks interop with both the Python server and shipped clients.
 */

// Policy / tuning constants — mirrors trial_server/server.py.
export const TRIAL_DAYS = 14;
export const DENY_VM_TRIALS = true;
export const RATE_LIMIT_WINDOW_SECONDS = 3600;
export const ACTIVATE_LIMIT_PER_IP_HOUR = 20;
export const STATUS_LIMIT_PER_IP_HOUR = 120;
export const MAX_BODY_BYTES = 64 * 1024;

const FP_RE = /^[0-9a-f]{64}$/;
const ISO_NO_MS = /\.\d{3}Z$/;

export function defaultConfig() {
  return {
    trialDays: TRIAL_DAYS,
    denyVmTrials: DENY_VM_TRIALS,
    rateWindowSec: RATE_LIMIT_WINDOW_SECONDS,
    activateLimit: ACTIVATE_LIMIT_PER_IP_HOUR,
    statusLimit: STATUS_LIMIT_PER_IP_HOUR,
    maxBodyBytes: MAX_BODY_BYTES,
  };
}

/** Only the 64-hex digest is ever accepted — raw UUIDs are rejected. */
export function validFingerprint(v) {
  return typeof v === "string" && FP_RE.test(v);
}

/**
 * Current UTC time as "YYYY-MM-DDTHH:MM:SSZ".
 * Matches Python: datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
 * (second precision — the fractional part of toISOString() is stripped).
 */
export function utcNowIso(nowMs = Date.now()) {
  return new Date(nowMs).toISOString().replace(ISO_NO_MS, "Z");
}

/** Add whole days to a "YYYY-MM-DDTHH:MM:SSZ" timestamp (== timedelta(days=n)). */
export function addDaysIso(startIso, days) {
  return utcNowIso(Date.parse(startIso) + days * 86400 * 1000);
}

async function hmacSha256Hex(secret, message) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return Array.from(new Uint8Array(sig), (b) => b.toString(16).padStart(2, "0")).join("");
}

/** Mint a trial token. Byte-identical to Python's TrialServer.mint_token. */
export async function mintToken(secret, fpHex, trialStart, trialEnd) {
  return hmacSha256Hex(secret, `${fpHex}|${trialStart}|${trialEnd}`);
}

/**
 * Constant-time comparison of two hex strings. Equivalent to Python's
 * hmac.compare_digest on ASCII input; avoids node:crypto so this also runs
 * in Workers.
 */
export function tokensEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export async function tokenOk(secret, fpHex, trialStart, trialEnd, token) {
  return tokensEqual(await mintToken(secret, fpHex, trialStart, trialEnd), token);
}

/**
 * Store adapter contract (async). See store.js for the D1 implementation
 * and the in-memory shim used by tests:
 *   get(fp)                    -> {trial_start, trial_end} | null
 *   insert(fp, rec)            -> throws {code:"TRIAL_DUPLICATE"} on PK clash
 *   touch(fp, nowIso)          -> activation_count++, last_seen = nowIso
 *   rateHit(kind, ip, nowMs, windowMs, limit) -> true when over the limit
 */

/**
 * POST /v1/trial/activate — pure logic. `body` is the parsed JSON value
 * (worker.js rejects oversized/unparseable bodies before calling).
 * Returns {status, body}.
 */
export async function handleActivate({
  store,
  secret,
  body,
  ip,
  nowMs = Date.now(),
  config = defaultConfig(),
}) {
  if (await store.rateHit("activate", ip, nowMs, config.rateWindowSec * 1000, config.activateLimit)) {
    return { status: 429, body: { ok: false, error: "rate_limited" } };
  }
  if (body === null || typeof body !== "object" || Array.isArray(body)) {
    return { status: 400, body: { ok: false, error: "malformed_request" } };
  }
  const fp = body.fingerprint_sha256;
  if (!validFingerprint(fp)) {
    return { status: 400, body: { ok: false, error: "malformed_fingerprint" } };
  }
  if (body.vm_suspected && config.denyVmTrials) {
    return { status: 403, body: { ok: false, error: "vm_not_allowed" } };
  }
  const nowIso = utcNowIso(nowMs);
  const existing = await store.get(fp);
  if (existing) {
    await store.touch(fp, nowIso);
    return {
      status: 403,
      body: {
        ok: false,
        error: "trial_already_consumed",
        trial_start: existing.trial_start,
        trial_end: existing.trial_end,
      },
    };
  }
  const trialStart = nowIso;
  const trialEnd = addDaysIso(trialStart, config.trialDays);
  try {
    await store.insert(fp, {
      trial_start: trialStart,
      trial_end: trialEnd,
      vmSuspected: body.vm_suspected ? 1 : 0,
      nowIso,
    });
  } catch (e) {
    // Lost a concurrent-activation race: the other request won the insert.
    if (e && e.code === "TRIAL_DUPLICATE") {
      const winner = await store.get(fp);
      await store.touch(fp, nowIso);
      return {
        status: 403,
        body: {
          ok: false,
          error: "trial_already_consumed",
          trial_start: winner.trial_start,
          trial_end: winner.trial_end,
        },
      };
    }
    throw e;
  }
  const token = await mintToken(secret, fp, trialStart, trialEnd);
  return { status: 200, body: { ok: true, trial_start: trialStart, trial_end: trialEnd, token } };
}

/** GET /v1/trial/status — pure logic. Returns {status, body}. */
export async function handleStatus({
  store,
  secret,
  fp,
  token,
  ip,
  nowMs = Date.now(),
  config = defaultConfig(),
}) {
  if (await store.rateHit("status", ip, nowMs, config.rateWindowSec * 1000, config.statusLimit)) {
    return { status: 429, body: { ok: false, error: "rate_limited" } };
  }
  if (!validFingerprint(fp)) {
    return { status: 400, body: { ok: false, error: "malformed_fingerprint" } };
  }
  const existing = await store.get(fp);
  if (!existing) {
    return { status: 404, body: { ok: false, error: "unknown_fingerprint" } };
  }
  if (!(await tokenOk(secret, fp, existing.trial_start, existing.trial_end, token))) {
    return { status: 403, body: { ok: false, error: "bad_token" } };
  }
  const active = nowMs < Date.parse(existing.trial_end);
  return {
    status: 200,
    body: {
      ok: true,
      active,
      trial_start: existing.trial_start,
      trial_end: existing.trial_end,
    },
  };
}
