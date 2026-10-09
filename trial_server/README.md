# NetMax Trial Registry Server (reference implementation)

Stdlib-only (`ThreadingHTTPServer` + `sqlite3`) reference server behind
NETMAX-APP's hardware-bound 14-day trial. It exists to close the
email-keyed trial loop: a trial is bound to the **SHA-256 of the hardware
UUID**, so reinstalling with a fresh email on the same machine finds the
same fingerprint already consumed.

**Status: not deployed.** This is a reference implementation shipped for
review and testing. The deployment options below are sketches only — nothing
here has been stood up, and nothing will be without MAX's explicit approval.

## Running it

```bash
export NETMAX_TRIAL_HMAC_SECRET='a-long-random-secret'   # REQUIRED
# Optional:
export NETMAX_TRIAL_DB='/var/lib/netmax-trial/registry.db'  # default: trial_registry.db next to server.py

python3 server.py --host 127.0.0.1 --port 8080
```

- The secret is read **only** in `main()` (never at import time) so tests can
  import the module safely.
- Refuses to start with a clear error (exit code 2) when
  `NETMAX_TRIAL_HMAC_SECRET` is unset.
- `GET /healthz` → `{"ok": true}` for load-balancer / uptime checks.

Generate a secret with e.g. `python3 -c "import secrets; print(secrets.token_hex(32))"`.

## API

`POST /v1/trial/activate` with JSON
`{fingerprint_sha256, app_version, vm_suspected}` →

- `200` `{ok:true, trial_start, trial_end, token}`
- `403` `{ok:false, error:"trial_already_consumed", trial_start, trial_end}`
- `403` `{ok:false, error:"vm_not_allowed"}` (when `DENY_VM_TRIALS` and the
  client reports a suspected VM)
- `400` malformed fingerprint / malformed request
- `429` rate-limited

`GET /v1/trial/status?fp=<hex>&token=<hex>` →

- `200` `{ok:true, active:bool, trial_start, trial_end}`
- `403` `{ok:false, error:"bad_token"}`
- `404` `{ok:false, error:"unknown_fingerprint"}`
- `429` rate-limited

Shared contract: `token = HMAC-SHA256(secret, f"{fp}|{trial_start}|{trial_end}")`,
timestamps UTC ISO `YYYY-MM-DDTHH:MM:SSZ`, `TRIAL_DAYS=14`. The raw hardware
UUID is never accepted, logged, or stored — only its 64-hex digest.

## Security notes

- **The HMAC secret is the whole trust root.** Anyone with it can mint valid
  trial tokens for any fingerprint. Keep it out of the repo, out of logs, and
  out of client code (clients only ever *receive* tokens).
- **Rotating the secret invalidates every issued token.** Existing trials keep
  their `trial_start`/`trial_end` rows, but clients holding old tokens will get
  `bad_token` on `/status` until they re-activate. Plan rotation as a
  maintenance event, not a silent change.
- **Terminate TLS at a reverse proxy.** This server speaks plain HTTP by
  design; put nginx/Caddy/Cloudflare in front of it and never expose the raw
  port to the internet.
- **The SQLite DB is the abuse record — back it up.** `trial_registry.db`
  holds every consumed fingerprint plus `activation_count`/`last_seen`, which
  is how repeat-activation abuse is detected. Lose the DB and every machine
  gets a fresh trial. Copy it on a schedule; SQLite files back up with a
  plain file copy while the server is running (or `VACUUM INTO`).
- **Rate limiting is in-memory per process** (`20` activates / `120` status
  checks per IP per hour). It resets on restart and does not coordinate across
  processes. Behind multiple workers, enforce limits at the reverse proxy.
- **VM denial is advisory.** `DENY_VM_TRIALS=True` rejects clients that
  *self-report* `vm_suspected`. It stops casual VM trial-farming, not a
  determined attacker who patches the client flag.
- **Threat model, honestly:** this stops the casual loop (reinstall + new
  email). It does not stop fresh-VM attackers, fingerprint spoofing, or
  someone who simply never phones home. The VM signal is a secondary
  heuristic, not proof.

## Deployment options (sketches, not deployed)

**Option A — VPS + reverse proxy (recommended reference path).**
Small VM (1 vCPU / 1 GB is plenty), systemd unit sketch:

```ini
[Unit]
Description=NetMax trial registry
After=network.target

[Service]
Environment=NETMAX_TRIAL_HMAC_SECRET_FILE=/etc/netmax-trial/secret
Environment=NETMAX_TRIAL_DB=/var/lib/netmax-trial/registry.db
ExecStart=/usr/bin/python3 /opt/netmax-trial/server.py --host 127.0.0.1 --port 8080
Restart=always
User=netmax-trial
```

(Use `EnvironmentFile=` or a wrapper that reads the secret file; systemd's
`Environment=` would expose it in the unit.) Front with Caddy or nginx for
TLS + rate limiting, firewall the raw port closed.

**Option B — Fly.io sketch.** `fly launch` with a small shared-cpu machine,
secret via `fly secrets set NETMAX_TRIAL_HMAC_SECRET=...`, and a persistent
1 GB volume mounted for the SQLite DB (without the volume, every deploy
wipes the abuse record). ~$2–5/mo territory.

**Option C — Cloudflare Tunnel sketch.** Run the server on any always-on box
(home server, VPS), expose it via `cloudflared tunnel` so no inbound firewall
ports are needed; Cloudflare terminates TLS. Same secret/DB caveats apply.

**Cloudflare Workers would need a rewrite.** Workers don't run CPython's
`http.server`/`sqlite3`; this code cannot be lifted there. The equivalent
would be a Worker + D1 (SQLite) or KV re-implementing the same endpoints and
the HMAC contract — doable, but it's a port, not a deploy.

## Testing

From the repo root: `python3 -m pytest tests/test_trial_server.py -q`.
The suite starts the real server on an ephemeral `127.0.0.1` port in a
thread — no network beyond loopback.
