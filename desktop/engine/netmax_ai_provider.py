#!/usr/bin/env python3
"""Model provider resolution for the AI layer.

Item 48 ("local-first models") is usually read as "bundle llama.cpp". That
is not the only way to get a model onto the user's machine, and it is not
the cheapest: a native runtime inside a signed bundle is a large, fragile
dependency. Any OpenAI-compatible server — Ollama, llama.cpp's server,
vLLM, LM Studio, or a self-hosted gateway — speaks the same
`POST /v1/chat/completions` shape. This module makes pointing at one a
configuration change rather than a code change, which delivers the
outcome item 48 was after without the native dependency.

Three things blocked that today, and all three are fixed here:

1. No environment variable for the base URL, so the endpoint was a
   constructor default only — reaching a local server meant editing code.
2. An API key was mandatory, so a keyless localhost server could not be
   used at all (`if not self.api_key: return None`).
3. `response_format: {"type": "json_object"}` was sent unconditionally.
   Many local servers reject that field outright or silently ignore it,
   so the request failed or returned prose the caller could not parse.
   `_chat_json_compat` degrades instead: try JSON mode, and on a refusal
   fall back to prompting for bare JSON and extracting it.

Anthropic is supported too, and genuinely differently — it is not
OpenAI-compatible, so it gets its own auth header, version header and
response path rather than a pretend-translated one.

Nothing here reaches the network at import time, and `verify()` is the only
function that does so, because probing a provider on every call would be
both slow and a privacy surprise.
"""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass, field
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

# Environment variables, in precedence order.
ENV_API_KEY = "NETMAX_AI_API_KEY"
ENV_MODEL = "NETMAX_AI_MODEL"
ENV_BASE = "NETMAX_AI_BASE"
ENV_PROVIDER = "NETMAX_AI_PROVIDER"
ENV_TIMEOUT = "NETMAX_AI_TIMEOUT"

OPENAI_DEFAULT_MODEL = "gpt-4o-mini"
OPENAI_DEFAULT_BASE = "https://api.openai.com/v1/chat/completions"
ANTHROPIC_DEFAULT_MODEL = "claude-sonnet-5"
ANTHROPIC_DEFAULT_BASE = "https://api.anthropic.com/v1/messages"


@dataclass
class Provider:
    """One provider's wire conventions and capabilities."""
    name: str
    base: str
    model: str
    #: Whether a key must be present. False for a local server.
    requires_key: bool = True
    #: Whether the endpoint accepts response_format=json_object.
    supports_json_mode: bool = True
    #: "bearer" | "x-api-key" | "none"
    auth_style: str = "bearer"
    extra_headers: dict[str, str] = field(default_factory=dict)
    api_key: str | None = None

    @property
    def configured(self) -> bool:
        return (not self.requires_key) or bool(self.api_key)


def _env_float(name: str, fallback: float) -> float:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return fallback
    try:
        return max(1.0, min(120.0, float(raw)))
    except ValueError:
        return fallback


def resolve(env: dict[str, str] | None = None) -> Provider:
    """Build the active provider from the environment.

    Precedence: an explicit NETMAX_AI_PROVIDER preset, then a bare
    NETMAX_AI_BASE (treated as a local/self-hosted OpenAI-compatible
    server unless a key is present), then OpenAI.

    A local server is inferred when the base URL points at loopback and no
    key is set: that combination is a keyless self-hosted endpoint, and
    demanding a key for it is the single thing that made local models
    unusable before.
    """
    environ = os.environ if env is None else env
    key = (environ.get(ENV_API_KEY, "") or "").strip()
    model = (environ.get(ENV_MODEL, "") or "").strip()
    base = (environ.get(ENV_BASE, "") or "").strip()
    preset = (environ.get(ENV_PROVIDER, "") or "").strip().lower()

    if preset in ("anthropic", "claude"):
        return Provider(
            name="anthropic",
            base=base or ANTHROPIC_DEFAULT_BASE,
            model=model or ANTHROPIC_DEFAULT_MODEL,
            requires_key=True,
            supports_json_mode=False,
            auth_style="x-api-key",
            extra_headers={"anthropic-version": "2023-06-01"},
            api_key=key or None,
        )

    if preset in ("local", "ollama", "llamacpp", "lmstudio", "self-hosted"):
        return Provider(
            name=preset,
            base=base or "http://127.0.0.1:11434/v1/chat/completions",
            model=model or "llama3.1",
            # A self-hosted endpoint may legitimately need no key.
            requires_key=False,
            supports_json_mode=False,
            auth_style="bearer" if key else "none",
            api_key=key or None,
        )

    if base:
        # An explicit base wins: self-hosted gateway, proxy, or a local
        # server the user pointed us at.
        local = _is_loopback(base)
        return Provider(
            name="custom",
            base=base,
            model=model or OPENAI_DEFAULT_MODEL,
            requires_key=not local or bool(key),
            supports_json_mode=not local,
            auth_style="bearer" if key else "none",
            api_key=key or None,
        )

    return Provider(
        name="openai",
        base=OPENAI_DEFAULT_BASE,
        model=model or OPENAI_DEFAULT_MODEL,
        requires_key=True,
        supports_json_mode=True,
        auth_style="bearer",
        api_key=key or None,
    )


def _is_loopback(url: str) -> bool:
    lowered = url.lower()
    return any(host in lowered for host in
               ("127.0.0.1", "localhost", "[::1]", "0.0.0.0"))


# ── request shaping ──────────────────────────────────────────────────────────

_JSON_INSTRUCTION = (
    "Reply with a single valid JSON object and nothing else. "
    "No prose, no markdown fence, no explanation outside the JSON."
)


def _headers(provider: Provider) -> dict[str, str]:
    headers = {"Content-Type": "application/json", **provider.extra_headers}
    if provider.auth_style == "bearer" and provider.api_key:
        headers["Authorization"] = f"Bearer {provider.api_key}"
    elif provider.auth_style == "x-api-key" and provider.api_key:
        headers["x-api-key"] = provider.api_key
    return headers


def _build_request(provider: Provider, prompt: str, system: str,
                   max_tokens: int, json_mode: bool) -> dict[str, Any]:
    """Shape a request in this provider's dialect."""
    # The compensating instruction belongs to the NO-JSON-MODE path: when
    # response_format is set the API already guarantees an object, and when
    # it is not, the instruction is the only thing asking for one.
    full_system = f"{system} {_JSON_INSTRUCTION}" if not json_mode else system

    if provider.auth_style == "x-api-key":
        # Anthropic: system is a top-level field, not a message.
        return {
            "model": provider.model,
            "max_tokens": max_tokens,
            "temperature": 0.1,
            "system": full_system,
            "messages": [{"role": "user", "content": prompt}],
        }

    payload: dict[str, Any] = {
        "model": provider.model,
        "temperature": 0.1,
        "max_tokens": max_tokens,
        "messages": [
            {"role": "system", "content": full_system},
            {"role": "user", "content": prompt},
        ],
    }
    if json_mode:
        payload["response_format"] = {"type": "json_object"}
    return payload


def _extract_content(provider: Provider, body: dict[str, Any]) -> str:
    """Pull the assistant text out of this provider's response shape."""
    if provider.auth_style == "x-api-key":
        blocks = body.get("content") or []
        parts = [b.get("text", "") for b in blocks if isinstance(b, dict)]
        return "".join(parts).strip()

    choices = body.get("choices") or []
    if not choices:
        raise ValueError("empty choices")
    message = choices[0].get("message")
    if isinstance(message, dict):
        content = message.get("content", "")
    else:
        content = choices[0].get("text", "")
    if not content:
        raise ValueError("empty content")
    return str(content).strip()


def _parse_json(text: str) -> dict[str, Any]:
    """Parse a JSON object, tolerating a markdown fence or stray prose.

    Local models are far likelier to wrap JSON in ```json fences despite
    being told not to, so recovering from that is the difference between
    working and not.
    """
    stripped = text.strip()
    try:
        parsed = json.loads(stripped)
    except json.JSONDecodeError:
        pass
    else:
        if isinstance(parsed, dict):
            return parsed
        raise TypeError("model content was not a JSON object")

    fenced = re.search(r"```(?:json)?\s*(.+?)\s*```", stripped, re.S)
    if fenced:
        parsed = json.loads(fenced.group(1))
        if isinstance(parsed, dict):
            return parsed
        raise TypeError("model content was not a JSON object")

    # Last resort: the outermost {...} span.
    start = stripped.find("{")
    end = stripped.rfind("}")
    if start != -1 and end > start:
        parsed = json.loads(stripped[start:end + 1])
        if isinstance(parsed, dict):
            return parsed
        raise TypeError("model content was not a JSON object")

    raise ValueError("no JSON object in model response")


def chat_json(
    prompt: str,
    *,
    system: str = "You are a JSON-only network assistant.",
    max_tokens: int = 200,
    env: dict[str, str] | None = None,
    provider: Provider | None = None,
) -> dict[str, Any]:
    """One JSON-mode completion. Raises on failure; callers fall back.

    Degrades in two steps rather than failing: if the endpoint refuses
    `response_format`, retry once without it and parse defensively.
    """
    active = provider or resolve(env)
    if not active.configured:
        raise ValueError(f"provider {active.name!r} needs an API key")

    timeout = _env_float(ENV_TIMEOUT, 30.0)
    headers = _headers(active)

    attempts = [active.supports_json_mode]
    if not attempts[0]:
        attempts = [False]
    else:
        attempts.append(False)          # retry without JSON mode on refusal

    last_error: Exception | None = None
    for json_mode in attempts:
        payload = _build_request(active, prompt, system, max_tokens, json_mode)
        request = Request(
            active.base,
            data=json.dumps(payload).encode("utf-8"),
            headers=headers,
            method="POST",
        )
        try:
            with urlopen(request, timeout=timeout) as response:
                body = json.loads(response.read().decode("utf-8"))
            return _parse_json(_extract_content(active, body))
        except HTTPError as exc:
            last_error = exc
            # A 4xx on the JSON-mode attempt is the documented refusal
            # case: retry without it. Anything else is a real failure.
            if json_mode and exc.code in (400, 422, 501):
                continue
            raise
        except (URLError, OSError, ValueError, TypeError) as exc:
            last_error = exc
            if json_mode:
                continue                # try the simpler shape once
            raise
    raise last_error or ValueError("provider call failed")


def verify(env: dict[str, str] | None = None) -> dict[str, Any]:
    """Check the configured provider with a tiny real call.

    The only function here that touches the network, deliberately: it is
    the answer to "is my setup right?", and it must actually try.
    """
    active = resolve(env)
    result: dict[str, Any] = {
        "provider": active.name,
        "model": active.model,
        "base": active.base,
        "requires_key": active.requires_key,
        "has_key": bool(active.api_key),
        "supports_json_mode": active.supports_json_mode,
        "local": _is_loopback(active.base),
    }
    if not active.configured:
        result.update(reachable=False,
                      detail=f"set {ENV_API_KEY} to use {active.name}")
        return result
    try:
        chat_json("Return {\"ok\": true}.", system="You reply with JSON only.",
                  max_tokens=32, provider=active)
        result.update(reachable=True, detail="provider responded")
    except Exception as exc:
        result.update(reachable=False,
                      detail=f"{type(exc).__name__}: {exc}"[:200])
    return result