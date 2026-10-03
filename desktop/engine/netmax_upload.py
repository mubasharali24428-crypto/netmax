"""Upload-speed probe — POST a random payload via curl, measure Mbps up.

Follows docs/FEATURE-SPECS.md '### 4. Upload speed via curl POST to public
endpoints' exactly: incompressible payload from /dev/urandom, curl
`%{http_code} %{size_upload} %{time_total}` write-out, VERIFIED endpoints only,
non-200 / unparseable results fall through to the next endpoint.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import time

import netmax

# All confirmed live 2026-08-22 (see FEATURE-SPECS.md). Cloudflare's __up is
# the fastest sink and tolerates large bodies; echo services buffer bodies in
# RAM so keep payloads small when falling through to them.
ENDPOINTS_VERIFIED = [
    "https://speed.cloudflare.com/__up",
    "https://httpbin.org/post",
    "https://postman-echo.com/post",
]

_WRITE_OUT_FMT = "%{http_code} %{size_upload} %{time_total}"


def _silent_unlink(path: str) -> None:
    try:
        os.unlink(path)
    except OSError:
        pass


def _source_for(size_bytes: int):
    """Payload source for one POST: (data_argv_token, stdin, cleanup_fn).

    Streams `head -c N /dev/urandom` straight into curl (`--data-binary @-`)
    so large windows never stage hundreds of MB to disk first. Falls back
    to the staged temp file when the pipe cannot be opened. cleanup_fn()
    releases whichever side was created and never raises.
    """
    try:
        head = subprocess.Popen(
            ["head", "-c", str(size_bytes), "/dev/urandom"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except (OSError, FileNotFoundError):
        head = None
    if head is None:
        with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as staged:
            payload_path = staged.name
            try:
                staged.write(os.urandom(size_bytes))
            except BaseException:
                _silent_unlink(payload_path)
                raise
        return "@" + payload_path, None, lambda: _silent_unlink(payload_path)

    def _cleanup(proc=head):
        try:
            if proc.stdout is not None:
                proc.stdout.close()
        finally:
            try:
                proc.terminate()
            except OSError:
                pass
            try:
                proc.wait(timeout=10)
            except (OSError, subprocess.TimeoutExpired):
                try:
                    proc.kill()
                except OSError:
                    pass
                proc.wait()

    return "@-", head.stdout, _cleanup


def upload_probe(seconds: float) -> tuple[float, float]:
    """Upload for up to `seconds`; return (Mbps_up, MB_sent).

    Raises netmax.NetMaxError if no verified endpoint yields a valid sample.
    """
    if seconds <= 0:
        raise ValueError("seconds must be positive")

    # Payload sized for the time window: assume ~10 Mbps worst case floor so we
    # never run dry mid-window on slow links (extra bytes are harmless — curl's
    # --max-time caps the window). CAPPED at 250 MB (audit F9): the old formula
    # materialized 27 GB of os.urandom for a 6-h window — curl re-POSTs the
    # same capped file within the window instead, same measurement quality.
    size_bytes = min(max(100_000, int(10e6 * seconds / 8)), 250_000_000)
    problems: list[str] = []
    for endpoint in ENDPOINTS_VERIFIED:
        # Fresh stream per endpoint: a half-consumed pipe must never feed
        # the next POST (curl would under-read and fabricate a slow sample).
        data_arg, stdin, cleanup = _source_for(size_bytes)
        netmax._progress_emit({"event": "attempt", "endpoint": endpoint})
        try:
            started = time.monotonic()
            try:
                proc = subprocess.run(
                    ["curl", "-s", "-o", "/dev/null", "-w", _WRITE_OUT_FMT,
                     "-X", "POST", "--data-binary", data_arg,
                     "--max-time", str(max(1.0, round(seconds, 3))),
                     endpoint],
                    stdin=stdin,
                    capture_output=True, text=True,
                    timeout=seconds + 15,          # stall guard past curl's own cap
                )
            except FileNotFoundError:
                raise netmax.NetMaxError(
                    "curl not found on PATH — install curl to measure upload"
                ) from None
            except subprocess.TimeoutExpired:
                # One hung endpoint must not abort failover to the next.
                problems.append(f"{endpoint}: curl hung past subprocess timeout")
                continue
            wall = time.monotonic() - started
            parts = proc.stdout.split()
            if len(parts) != 3:
                detail = proc.stderr.strip() or f"unparseable output {proc.stdout[:120]!r}"
                problems.append(f"{endpoint}: curl exit {proc.returncode}: {detail}")
                continue
            code_s, nbytes_s, secs_s = parts
            # Non-200 (rate limit / 4xx) → discard sample, next endpoint.
            if code_s != "200":
                problems.append(f"{endpoint}: HTTP {code_s}")
                continue
            try:
                nbytes, secs = int(nbytes_s), float(secs_s)
            except ValueError:
                problems.append(
                    f"{endpoint}: unparseable numbers {nbytes_s!r} {secs_s!r}"
                )
                continue
            if secs <= 0 or wall <= 0:
                problems.append(f"{endpoint}: zero/negative duration")
                continue
            if nbytes == 0:
                # Proxy interception guard: nothing actually left the machine.
                problems.append(f"{endpoint}: 0 bytes uploaded (HTTP 200)")
                continue
            # Mbps math divides bytes sent by curl's own time_total, so a
            # capped payload ending its last POST early stays exact — and a
            # stream cut short by --max-time measures exactly what was sent.
            mbps = nbytes * 8 / secs / 1e6
            return mbps, nbytes / 1e6
        finally:
            cleanup()

    raise netmax.NetMaxError(
        "upload probe failed on all endpoints: " + "; ".join(problems)
    )
