-- NetMax trial-registry D1 schema.
-- Mirrors trial_server/server.py's SQLite schema, plus a rate_hits table
-- (the Python server keeps rate state in process memory; on Workers there is
-- no shared process memory across isolates, so the rolling window lives in
-- D1 — see src/store.js and README.md for the rationale).
-- Apply with: wrangler d1 execute netmax-trial-registry --file schema.sql

CREATE TABLE IF NOT EXISTS trials (
    fingerprint_sha256 TEXT PRIMARY KEY,
    trial_start        TEXT NOT NULL,
    trial_end          TEXT NOT NULL,
    vm_suspected       INTEGER NOT NULL,
    activation_count   INTEGER NOT NULL,
    first_seen         TEXT NOT NULL,
    last_seen          TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS rate_hits (
    id   INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL,   -- 'activate' | 'status'
    ip   TEXT NOT NULL,
    ts   INTEGER NOT NULL -- epoch milliseconds
);

CREATE INDEX IF NOT EXISTS idx_rate_hits_kind_ip_ts
    ON rate_hits (kind, ip, ts);
