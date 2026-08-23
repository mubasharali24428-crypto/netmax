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


def upload_probe(seconds: float) -> tuple[float, float]:
    """Upload for up to `seconds`; return (Mbps_up, MB_sent).

    Raises netmax.NetMaxError if no verified endpoint yields a valid sample.
    """
    if seconds <= 0:
        raise ValueError("seconds must be positive")

    # Payload sized for the time window: assume ~10 Mbps worst case floor so we
    # never run dry mid-window on slow links (extra bytes are harmless — curl's
    # --max-time caps the window).
    size_bytes = max(100_000, int(10e6 * seconds / 8))
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as f:
        f.write(os.urandom(size_bytes))
        payload = f.name

    problems: list[str] = []
    try:
        for endpoint in ENDPOINTS_VERIFIED:
            started = time.monotonic()
            proc = subprocess.run(
                ["curl", "-s", "-o", "/dev/null", "-w", _WRITE_OUT_FMT,
                 "-X", "POST", "--data-binary", "@" + payload,
                 "--max-time", str(max(1.0, round(seconds, 3))),
                 endpoint],
                capture_output=True, text=True,
                timeout=seconds + 15,          # stall guard past curl's own cap
            )
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
            nbytes, secs = int(nbytes_s), float(secs_s)
            if secs <= 0 or wall <= 0:
                problems.append(f"{endpoint}: zero/negative duration")
                continue
            if nbytes == 0:
                # Proxy interception guard: nothing actually left the machine.
                problems.append(f"{endpoint}: 0 bytes uploaded (HTTP 200)")
                continue
            mbps = nbytes * 8 / secs / 1e6
            return mbps, nbytes / 1e6
    except subprocess.TimeoutExpired:
        problems.append("curl hung past subprocess timeout — aborted")
    finally:
        try:
            os.unlink(payload)
        except OSError:
            pass

    raise netmax.NetMaxError(
        "upload probe failed on all endpoints: " + "; ".join(problems)
    )
