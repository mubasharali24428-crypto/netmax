#!/usr/bin/env python3
"""Reference trial-registry server for NETMAX-APP's hardware-bound trial.

Stdlib only: ThreadingHTTPServer + sqlite3. This is the server side of the
trial-abuse hardening contract:

    fingerprint = SHA-256 hex (64 lowercase chars) of the hardware UUID string
    token       = HMAC-SHA256(secret, f"{fp_hex}|{trial_start}|{trial_end}")

Timestamps are UTC ISO ``YYYY-MM-DDTHH:MM:SSZ``. The raw hardware UUID is
NEVER accepted, logged, or stored — only its 64-hex digest.

API:
    POST /v1/trial/activate   JSON {fingerprint_sha256, app_version, vm_suspected}
        200 {ok:true, trial_start, trial_end, token}
        403 {ok:false, error:"trial_already_consumed", trial_start, trial_end}
        403 {ok:false, error:"vm_not_allowed"}
        400 {ok:false, error:"malformed_fingerprint" | "malformed_request"}
        429 {ok:false, error:"rate_limited"}
    GET /v1/trial/status?fp=<hex>&token=<hex>
        200 {ok:true, active:bool, trial_start, trial_end}
        403 {ok:false, error:"bad_token"}
        404 {ok:false, error:"unknown_fingerprint"}
        429 {ok:false, error:"rate_limited"}
    GET /healthz
        200 {ok:true}

The HMAC secret comes ONLY from the ``NETMAX_TRIAL_HMAC_SECRET`` environment
variable, read in ``main()`` — never at import time, so tests can import this
module safely. ``TRIAL_DAYS``, ``DENY_VM_TRIALS``, and the rate-limit
constants are module-level named constants read at request time so tests can
monkeypatch them.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import re
import sqlite3
import sys
import threading
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

# ---------------------------------------------------------------------------
# Policy / tuning constants (monkeypatch-friendly: read at request time).
# ---------------------------------------------------------------------------

#: Length of the free trial in days.
TRIAL_DAYS = 14

#: Server-side kill switch: refuse trial activation from suspected VMs.
DENY_VM_TRIALS = True

#: In-memory per-IP rate limits (rolling window).
RATE_LIMIT_WINDOW_SECONDS = 3600
ACTIVATE_LIMIT_PER_IP_HOUR = 20
STATUS_LIMIT_PER_IP_HOUR = 120

#: Largest request body we will read (protects the JSON parser).
MAX_BODY_BYTES = 64 * 1024

FP_RE = re.compile(r"^[0-9a-f]{64}$")
_TS_FORMAT = "%Y-%m-%dT%H:%M:%SZ"

_SCHEMA = """
CREATE TABLE IF NOT EXISTS trials (
    fingerprint_sha256 TEXT PRIMARY KEY,
    trial_start        TEXT NOT NULL,
    trial_end          TEXT NOT NULL,
    vm_suspected       INTEGER NOT NULL,
    activation_count   INTEGER NOT NULL,
    first_seen         TEXT NOT NULL,
    last_seen          TEXT NOT NULL
)
"""


def utc_now_iso() -> str:
    """Current UTC time as ``YYYY-MM-DDTHH:MM:SSZ``."""
    return datetime.now(timezone.utc).strftime(_TS_FORMAT)


def parse_ts(ts: str) -> datetime:
    """Parse a ``YYYY-MM-DDTHH:MM:SSZ`` timestamp as an aware datetime."""
    return datetime.strptime(ts, _TS_FORMAT).replace(tzinfo=timezone.utc)


class TrialServer(ThreadingHTTPServer):
    """HTTP server holding the trial registry DB, rate-limit state, secret."""

    daemon_threads = True

    def __init__(self, server_address, db_path, hmac_secret):
        super().__init__(server_address, TrialHandler)
        self.db_path = db_path
        self.hmac_secret = hmac_secret
        self._conn = sqlite3.connect(db_path, check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        with self._conn:
            self._conn.executescript(_SCHEMA)
        self._db_lock = threading.Lock()
        self._rate_lock = threading.Lock()
        # (kind, ip) -> list of monotonic timestamps of recent requests.
        self._rate: dict = {}

    # -- token -----------------------------------------------------------
    def mint_token(self, fp_hex: str, trial_start: str, trial_end: str) -> str:
        msg = f"{fp_hex}|{trial_start}|{trial_end}".encode("utf-8")
        return hmac.new(
            self.hmac_secret.encode("utf-8"), msg, hashlib.sha256
        ).hexdigest()

    def token_ok(
        self, fp_hex: str, trial_start: str, trial_end: str, token: str
    ) -> bool:
        if not isinstance(token, str):
            return False
        return hmac.compare_digest(self.mint_token(fp_hex, trial_start, trial_end), token)

    # -- db --------------------------------------------------------------
    def db_get(self, fp_hex):
        """Return (trial_start, trial_end) for fp, or None."""
        with self._db_lock:
            row = self._conn.execute(
                "SELECT trial_start, trial_end FROM trials "
                "WHERE fingerprint_sha256 = ?",
                (fp_hex,),
            ).fetchone()
        return (row["trial_start"], row["trial_end"]) if row else None

    def db_activate(self, fp_hex, trial_start, trial_end, vm_flag):
        """Insert a fresh trial row. Caller must have checked for existing."""
        now = utc_now_iso()
        with self._db_lock:
            with self._conn:
                self._conn.execute(
                    "INSERT INTO trials (fingerprint_sha256, trial_start, "
                    "trial_end, vm_suspected, activation_count, first_seen, "
                    "last_seen) VALUES (?, ?, ?, ?, 1, ?, ?)",
                    (fp_hex, trial_start, trial_end, int(bool(vm_flag)), now, now),
                )

    def db_touch(self, fp_hex):
        """Record a repeat activation attempt (abuse signal)."""
        with self._db_lock:
            with self._conn:
                self._conn.execute(
                    "UPDATE trials SET activation_count = activation_count + 1, "
                    "last_seen = ? WHERE fingerprint_sha256 = ?",
                    (utc_now_iso(), fp_hex),
                )


class TrialHandler(BaseHTTPRequestHandler):
    server_version = "NetMaxTrialRegistry/1.0"

    def log_message(self, fmt, *args):  # keep test output and logs quiet
        pass

    # -- small helpers ---------------------------------------------------
    def _json(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return None
        if length <= 0 or length > MAX_BODY_BYTES:
            return None
        return self.rfile.read(length)

    def _rate_limited(self, kind):
        if kind == "activate":
            limit = ACTIVATE_LIMIT_PER_IP_HOUR
        else:
            limit = STATUS_LIMIT_PER_IP_HOUR
        key = (kind, self.client_address[0])
        now = time.monotonic()
        with self.server._rate_lock:
            hits = [
                t
                for t in self.server._rate.get(key, [])
                if now - t < RATE_LIMIT_WINDOW_SECONDS
            ]
            if len(hits) >= limit:
                self.server._rate[key] = hits
                return True
            hits.append(now)
            self.server._rate[key] = hits
        return False

    @staticmethod
    def _valid_fp(value):
        return isinstance(value, str) and FP_RE.match(value) is not None

    # -- routing ----------------------------------------------------------
    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/healthz":
            self._json(200, {"ok": True})
        elif parsed.path == "/v1/trial/status":
            self._handle_status(parsed)
        else:
            self._json(404, {"ok": False, "error": "not_found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path == "/v1/trial/activate":
            self._handle_activate()
        else:
            self._json(404, {"ok": False, "error": "not_found"})

    # -- endpoints ---------------------------------------------------------
    def _handle_activate(self):
        if self._rate_limited("activate"):
            self._json(429, {"ok": False, "error": "rate_limited"})
            return
        raw = self._read_body()
        if raw is None:
            self._json(400, {"ok": False, "error": "malformed_request"})
            return
        try:
            body = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            self._json(400, {"ok": False, "error": "malformed_request"})
            return
        if not isinstance(body, dict):
            self._json(400, {"ok": False, "error": "malformed_request"})
            return
        fp_hex = body.get("fingerprint_sha256")
        if not self._valid_fp(fp_hex):
            # Only the 64-hex digest is ever accepted — raw UUIDs rejected.
            self._json(400, {"ok": False, "error": "malformed_fingerprint"})
            return
        vm_flag = body.get("vm_suspected")
        if vm_flag and DENY_VM_TRIALS:
            self._json(403, {"ok": False, "error": "vm_not_allowed"})
            return
        existing = self.server.db_get(fp_hex)
        if existing is not None:
            trial_start, trial_end = existing
            self.server.db_touch(fp_hex)
            self._json(
                403,
                {
                    "ok": False,
                    "error": "trial_already_consumed",
                    "trial_start": trial_start,
                    "trial_end": trial_end,
                },
            )
            return
        trial_start = utc_now_iso()
        trial_end = (parse_ts(trial_start) + timedelta(days=TRIAL_DAYS)).strftime(
            _TS_FORMAT
        )
        self.server.db_activate(fp_hex, trial_start, trial_end, vm_flag)
        token = self.server.mint_token(fp_hex, trial_start, trial_end)
        self._json(
            200,
            {
                "ok": True,
                "trial_start": trial_start,
                "trial_end": trial_end,
                "token": token,
            },
        )

    def _handle_status(self, parsed):
        if self._rate_limited("status"):
            self._json(429, {"ok": False, "error": "rate_limited"})
            return
        query = parse_qs(parsed.query)
        fp_hex = query.get("fp", [None])[0]
        token = query.get("token", [None])[0]
        if not self._valid_fp(fp_hex):
            self._json(400, {"ok": False, "error": "malformed_fingerprint"})
            return
        existing = self.server.db_get(fp_hex)
        if existing is None:
            self._json(404, {"ok": False, "error": "unknown_fingerprint"})
            return
        trial_start, trial_end = existing
        if not self.server.token_ok(fp_hex, trial_start, trial_end, token):
            self._json(403, {"ok": False, "error": "bad_token"})
            return
        try:
            active = datetime.now(timezone.utc) < parse_ts(trial_end)
        except ValueError:
            active = False
        self._json(
            200,
            {
                "ok": True,
                "active": active,
                "trial_start": trial_start,
                "trial_end": trial_end,
            },
        )


def build_arg_parser():
    parser = argparse.ArgumentParser(
        description="Reference trial-registry server for NETMAX-APP "
        "(hardware-bound 14-day trial)."
    )
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    return parser


def main(argv=None) -> int:
    """Entry point. Returns a process exit code (no SystemExit raised here)."""
    args = build_arg_parser().parse_args(argv)
    secret = os.environ.get("NETMAX_TRIAL_HMAC_SECRET")
    if not secret:
        print(
            "error: NETMAX_TRIAL_HMAC_SECRET is not set — refusing to start "
            "without an HMAC secret (all trial tokens would be forgeable).",
            file=sys.stderr,
        )
        return 2
    db_path = os.environ.get(
        "NETMAX_TRIAL_DB",
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "trial_registry.db"),
    )
    server = TrialServer((args.host, args.port), db_path=db_path, hmac_secret=secret)
    host, port = server.server_address[0], server.server_address[1]
    print(f"netmax trial registry listening on {host}:{port} db={db_path}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
