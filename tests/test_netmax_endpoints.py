"""Offline tests for netmax_endpoints (BRAVO-B1-07) — network fully mocked.

All HTTP/DNS seams are patched at the module boundary per repo convention
(see tests/test_netmax_fetch.py: `from urllib.request import ... urlopen` ->
patch ``netmax_endpoints.urlopen``). The shared autouse ``offline_guarantee``
fixture in tests/conftest.py additionally tripwires subprocess/getaddrinfo/
socket creation, so no test can touch the real network.

Coverage targets (mission BRAVO-B1-07):
  * ok path           — a healthy endpoint reports healthy
  * timeout           — a timing-out endpoint reports unhealthy, distinctly
  * HTTP error        — a 4xx/5xx endpoint reports unhealthy, distinctly
  * malformed summary — garbage payloads never crash the summarizer

NOTE(B1-07 staging): helper resolvers below tolerate reasonable naming choices
by B1-06 (function/constants names). Once netmax_endpoints lands these are
tightened to the real surface; the behavioral assertions stay.
"""

from __future__ import annotations

import urllib.error

import pytest

import netmax_endpoints

# ── fakes & seam installation ─────────────────────────────────────────────────


class FakeResponse:
    """Minimal urlopen stand-in: read(n)/close()/getcode()/context-manager."""

    def __init__(self, body=b"", status=200, headers=None):
        self._body = body
        self.status = status
        self.headers = headers or {}

    def read(self, n=-1):
        if n is None or n < 0:
            block, self._body = self._body, b""
        else:
            block, self._body = self._body[:n], self._body[n:]
        return block

    def close(self):
        pass

    def getcode(self):
        return self.status

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def install_urlopen(monkeypatch, script):
    """Install scripted urlopen on every plausible seam; return call log.

    ``script(url, timeout) -> FakeResponse | raises``. Covers both import
    styles (``from urllib.request import urlopen`` and ``import urllib.request``).
    """
    calls = []

    def fake_urlopen(req, timeout=None):
        url = getattr(req, "full_url", None)
        if url is None:
            url = req if isinstance(req, str) else getattr(req, "type", "?")
        calls.append({"url": url, "timeout": timeout})
        resp = script(url, timeout)
        # Emulate real urllib: >=400 statuses surface as HTTPError raises,
        # never as a visible response object.
        status = getattr(resp, "status", 200)
        if status >= 400:
            raise urllib.error.HTTPError(url, status, "simulated", None, None)
        return resp

    if hasattr(netmax_endpoints, "urlopen"):
        monkeypatch.setattr(netmax_endpoints, "urlopen", fake_urlopen)
    if hasattr(netmax_endpoints, "urllib"):
        monkeypatch.setattr(netmax_endpoints.urllib.request, "urlopen", fake_urlopen)
    return calls


# ── surface discovery (staging shims; tightened when B1-06 lands) ─────────────

PROBE_FN_NAMES = (
    "health_check",
    "check_endpoint",
    "probe_endpoint",
    "endpoint_health",
    "probe",
    "health",
    "check",
)


def _find_probe():
    for name in PROBE_FN_NAMES:
        fn = getattr(netmax_endpoints, name, None)
        if callable(fn):
            return name, fn
    return None, None


def _first_endpoint():
    """A (name, template) endpoint to probe, discovered from module constants."""
    for attr in ("ENDPOINTS", "SPEED_ENDPOINTS", "PROBE_ENDPOINTS",
                 "DNS_ENDPOINTS", "DEFAULT"):
        eps = getattr(netmax_endpoints, attr, None)
        if isinstance(eps, list) and eps:
            first = eps[0]
            if isinstance(first, tuple) and len(first) == 2:
                return first
            if isinstance(first, str):
                return ("ep0", first)
    return ("OVH", "https://proof.ovh.net/files/100Mb.dat")


def _is_healthy(value):
    """Interpret an arbitrary probe result's healthiness (shape-tolerant)."""
    if isinstance(value, bool):
        return value
    if value is None:
        return False
    if isinstance(value, dict):
        for key in ("ok", "healthy", "available", "alive", "up", "reachable"):
            if key in value:
                return bool(value[key])
        status = value.get("status")
        if isinstance(status, int):
            return 200 <= status < 400
        if isinstance(status, str):
            return status.lower() in ("ok", "healthy", "up", "available")
    return True


# ── ok path ───────────────────────────────────────────────────────────────────


def test_ok_path_reports_healthy(monkeypatch):
    name, probe = _find_probe()
    assert probe is not None, (
        f"netmax_endpoints exposes none of {PROBE_FN_NAMES}; adjust PROBE_FN_NAMES"
    )
    install_urlopen(
        monkeypatch, lambda url, timeout: FakeResponse(b"OK", status=200)
    )
    outcome = _is_healthy(probe(_first_endpoint()))
    assert outcome is True, f"{name}(...) must report healthy on HTTP 200"


def test_probe_hits_the_requested_url_and_passes_timeout(monkeypatch):
    _, probe = _find_probe()
    ep = _first_endpoint()
    calls = install_urlopen(
        monkeypatch, lambda url, timeout: FakeResponse(status=200)
    )
    _is_healthy(probe(ep))
    assert calls, "probe never issued an HTTP request"
    # cache-buster templates must not reach urlopen unsubstituted
    assert all("{cb}" not in c["url"] for c in calls), calls


# ── failure paths: timeout & HTTP error ───────────────────────────────────────


def _outcome(monkeypatch, script):
    install_urlopen(monkeypatch, script)
    _, probe = _find_probe()
    try:
        value = probe(_first_endpoint())
    except (urllib.error.URLError, OSError, TimeoutError):
        return None  # probe surfaced the network error itself == unhealthy
    return _is_healthy(value)


def test_timeout_reports_unhealthy(monkeypatch):
    def timed_out(url, timeout=None):
        raise TimeoutError("simulated connect timeout")

    assert _outcome(monkeypatch, timed_out) is not True


def test_http_error_reports_unhealthy(monkeypatch):
    def forbidden(url, timeout=None):
        raise urllib.error.HTTPError(url, 403, "blocked", None, None)

    assert _outcome(monkeypatch, forbidden) is not True


def test_server_error_reports_unhealthy(monkeypatch):
    install_urlopen(monkeypatch, lambda url, t: FakeResponse(b"", status=503))
    _, probe = _find_probe()
    try:
        value = probe(_first_endpoint())
    except (urllib.error.URLError, OSError):
        return  # wrapped 503 into a network error == unhealthy, allowed
    assert _is_healthy(value) is not True


def test_failure_is_distinguishable_from_success(monkeypatch):
    """Healthy and broken endpoints must produce different verdicts."""
    _, probe = _find_probe()

    install_urlopen(monkeypatch, lambda url, t: FakeResponse(b"OK", status=200))
    good = _outcome_strict(probe)

    def timed_out(url, timeout=None):
        raise TimeoutError("simulated")

    install_urlopen(monkeypatch, timed_out)
    bad = _outcome_strict(probe)

    assert good is True, "ok path must be healthy"
    assert bad is not True, "timeout path must not look healthy"


def _outcome_strict(probe):
    try:
        return _is_healthy(probe(_first_endpoint()))
    except (urllib.error.URLError, OSError, TimeoutError):
        return False


# ── malformed summary ─────────────────────────────────────────────────────────

SUMMARY_FN_NAMES = (
    "parse_summary",
    "parse_health_summary",
    "summarize",
    "parse_report",
    "build_report",
    "aggregate",
    "report",
    "parse",
)

MALFORMED_SUMMARIES = [
    "",
    "   \n\t ",
    "<<not json at all>>",
    '{"truncated": ',
    "\x00\x01\x02binary-garbage",
    "null",
    '{"latency_ms": "not-a-number", "status": }',
    "a" * 5000,
    b"\xff\xfe-bytes-garbage",
    None,
    42,
    [None, 7, "junk"],                      # right shape, wrong items
    {"results": "should-have-been-a-list"},  # wrong value types
]


def _find_summarizer():
    for name in SUMMARY_FN_NAMES:
        fn = getattr(netmax_endpoints, name, None)
        if callable(fn):
            return name, fn
    return None, None


GRACEFUL_REJECTIONS = (ValueError, TypeError)


@pytest.mark.parametrize("garbage", MALFORMED_SUMMARIES)
def test_malformed_summary_never_crashes(garbage):
    """Malformed summaries must degrade gracefully: either return a value
    (sentinel/zeros/empty report — repo convention, cf. watch_loop's F-grade
    degradation) or reject explicitly with ValueError/TypeError. Sloppy
    leaks (AttributeError, KeyError, raw JSONDecodeError, …) fail."""
    name, summarize = _find_summarizer()
    if summarize is None:
        pytest.skip(f"netmax_endpoints exposes none of {SUMMARY_FN_NAMES}")
    try:
        summarize(garbage)
    except GRACEFUL_REJECTIONS:
        pass  # explicit validation counts as graceful
    except Exception as exc:
        raise AssertionError(
            f"{name}(malformed) leaked {type(exc).__name__}: {exc}; "
            "return a degraded value or raise ValueError/TypeError"
        ) from exc


# ── endpoint registry sanity (mirrors netmax.ENDPOINTS conventions) ──────────


def test_registry_constants_are_wellformed():
    eps = getattr(netmax_endpoints, "ENDPOINTS", None)
    assert eps, "netmax_endpoints must expose an ENDPOINTS-style registry"
    for entry in eps:
        assert isinstance(entry, (tuple, list)) and len(entry) >= 2
        name, template = entry[0], entry[1]
        assert isinstance(name, str) and name
        assert isinstance(template, str) and template.startswith("https://")
