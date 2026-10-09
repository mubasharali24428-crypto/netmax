/**
 * store.js — trial-registry storage adapters.
 *
 * Both adapters implement the async contract consumed by trial.js:
 *   get(fp)                                        -> {trial_start, trial_end} | null
 *   insert(fp, {trial_start, trial_end, vmSuspected, nowIso})
 *       -> throws {code:"TRIAL_DUPLICATE"} when the fingerprint already exists
 *   touch(fp, nowIso)                              -> activation_count++, last_seen = nowIso
 *   rateHit(kind, ip, nowMs, windowMs, limit)       -> true when over the limit
 *
 * createD1Store(db)  — production adapter over a D1 database binding.
 * createMemoryStore() — in-memory shim with identical semantics, for tests
 *                       and local development (no D1 needed).
 */

export function createD1Store(db) {
  return {
    async get(fp) {
      const row = await db
        .prepare("SELECT trial_start, trial_end FROM trials WHERE fingerprint_sha256 = ?")
        .bind(fp)
        .first();
      return row ? { trial_start: row.trial_start, trial_end: row.trial_end } : null;
    },

    async insert(fp, { trial_start, trial_end, vmSuspected, nowIso }) {
      try {
        await db
          .prepare(
            `INSERT INTO trials
               (fingerprint_sha256, trial_start, trial_end, vm_suspected,
                activation_count, first_seen, last_seen)
             VALUES (?, ?, ?, ?, 1, ?, ?)`,
          )
          .bind(fp, trial_start, trial_end, vmSuspected, nowIso, nowIso)
          .run();
      } catch (e) {
        // D1 surfaces PK violations as a D1_ERROR mentioning the constraint.
        if (e && /UNIQUE constraint failed/i.test(String((e && e.message) || e))) {
          throw { code: "TRIAL_DUPLICATE" };
        }
        throw e;
      }
    },

    async touch(fp, nowIso) {
      await db
        .prepare(
          "UPDATE trials SET activation_count = activation_count + 1, last_seen = ? " +
            "WHERE fingerprint_sha256 = ?",
        )
        .bind(nowIso, fp)
        .run();
    },

    /**
     * Rolling-window per-IP rate limit, mirroring the Python server's
     * in-memory semantics. Implemented in D1 (not Workers KV) so every
     * isolate sees the same counters — KV's eventual consistency would let
     * bursts through — and so rate limiting needs no second binding.
     */
    async rateHit(kind, ip, nowMs, windowMs, limit) {
      const cutoff = nowMs - windowMs;
      const counted = await db.batch([
        db.prepare("DELETE FROM rate_hits WHERE ts < ?").bind(cutoff),
        db
          .prepare("SELECT COUNT(*) AS n FROM rate_hits WHERE kind = ? AND ip = ? AND ts >= ?")
          .bind(kind, ip, cutoff),
      ]);
      const n = counted[1].results[0].n;
      if (n >= limit) return true;
      await db
        .prepare("INSERT INTO rate_hits (kind, ip, ts) VALUES (?, ?, ?)")
        .bind(kind, ip, nowMs)
        .run();
      return false;
    },
  };
}

export function createMemoryStore() {
  const trials = new Map(); // fp -> {trial_start, trial_end, vmSuspected, activation_count, first_seen, last_seen}
  const hits = []; // {kind, ip, ts}
  return {
    async get(fp) {
      const r = trials.get(fp);
      return r ? { trial_start: r.trial_start, trial_end: r.trial_end } : null;
    },
    async insert(fp, { trial_start, trial_end, vmSuspected, nowIso }) {
      if (trials.has(fp)) throw { code: "TRIAL_DUPLICATE" };
      trials.set(fp, {
        trial_start,
        trial_end,
        vmSuspected,
        activation_count: 1,
        first_seen: nowIso,
        last_seen: nowIso,
      });
    },
    async touch(fp, nowIso) {
      const r = trials.get(fp);
      if (r) {
        r.activation_count += 1;
        r.last_seen = nowIso;
      }
    },
    async rateHit(kind, ip, nowMs, windowMs, limit) {
      const cutoff = nowMs - windowMs;
      for (let i = hits.length - 1; i >= 0; i--) {
        if (hits[i].ts < cutoff) hits.splice(i, 1);
      }
      if (hits.filter((h) => h.kind === kind && h.ip === ip).length >= limit) return true;
      hits.push({ kind, ip, ts: nowMs });
      return false;
    },
    // Test introspection only (not part of the contract).
    _trials: trials,
    _hits: hits,
  };
}
