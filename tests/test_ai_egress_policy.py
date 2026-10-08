"""Fail-closed consent and strict payload tests for remote AI egress."""

from __future__ import annotations

import json
import subprocess

import pytest

import netmax_ai_provider as provider


VALID_PAYLOAD = {
    "schema_version": 1,
    "analysis_id": "governor_preferences",
    "metrics": {
        "mode": "limit",
        "streams": 4,
        "duration_seconds": 60,
        "download_mbps": 50.0,
        "latency_ms": 12.5,
        "jitter_ms": 2.0,
        "packet_loss_percent": 0.1,
        "sample_count": 8,
    },
}


def _response(content='{"ok":true}'):
    class Response:
        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return False

        def read(self, size=-1):
            data = json.dumps({
                "choices": [{"message": {"content": content}}]
            }).encode()
            return data if size < 0 else data[:size]

    return Response()


def _defaults_result(args, code, stdout):
    return subprocess.CompletedProcess(args, code, stdout=stdout, stderr="")


def test_consent_uses_typed_defaults_argv_with_bounded_timeouts(monkeypatch):
    calls = []

    def fake_run(args, **kwargs):
        calls.append((args, kwargs))
        output = ("Type is boolean" if args[1] == "read-type" else "1")
        return _defaults_result(args, 0, output)

    monkeypatch.setattr(provider.subprocess, "run", fake_run)
    assert provider._read_remote_ai_consent() is True
    assert [call[0] for call in calls] == [
        ["/usr/bin/defaults", "read-type", "com.netmax.desktop",
         "netmax.prefs.allowRemoteAI"],
        ["/usr/bin/defaults", "read", "com.netmax.desktop",
         "netmax.prefs.allowRemoteAI"],
    ]
    assert all(call[1] == {
        "capture_output": True, "text": True, "timeout": 1.0, "check": False,
    } for call in calls)


@pytest.mark.parametrize("type_code,type_text,value_code,value_text", [
    (1, "", 0, "1"),
    (0, "Type is string", 0, "true"),
    (0, "Type is boolean", 1, "1"),
    (0, "Type is boolean", 0, "YES"),
])
def test_malformed_missing_or_unreadable_preference_fails_closed(
        monkeypatch, type_code, type_text, value_code, value_text):
    def fake_run(args, **_kwargs):
        return _defaults_result(
            args, type_code if args[1] == "read-type" else value_code,
            type_text if args[1] == "read-type" else value_text)

    monkeypatch.setattr(provider.subprocess, "run", fake_run)
    assert provider._read_remote_ai_consent() is False


def test_preference_timeout_and_environment_cannot_enable_remote_ai(monkeypatch):
    def timeout(*_args, **_kwargs):
        raise subprocess.TimeoutExpired("defaults", 1.0)

    monkeypatch.setattr(provider.subprocess, "run", timeout)
    monkeypatch.setenv("NETMAX_ALLOW_REMOTE_AI", "1")
    assert provider._read_remote_ai_consent() is False


def test_remote_consent_is_checked_before_request_body_or_socket(monkeypatch):
    touched = []
    monkeypatch.setattr(provider, "_read_remote_ai_consent", lambda: False)
    monkeypatch.setattr(provider, "_build_request", lambda *_a, **_k: touched.append("body"))
    monkeypatch.setattr(provider, "urlopen", lambda *_a, **_k: touched.append("socket"))
    remote = provider.Provider(
        "custom", "https://provider.example/v1/chat/completions", "model",
        api_key="secret")
    with pytest.raises(PermissionError, match="disabled"):
        provider.chat_json("contains secret history", provider=remote)
    assert touched == []


def test_remote_request_contains_only_the_allowlisted_json(monkeypatch):
    seen = {}
    monkeypatch.setattr(provider, "_read_remote_ai_consent", lambda: True)

    def fake_open(request, timeout=None):
        seen["body"] = json.loads(request.data)
        seen["headers"] = dict(request.header_items())
        return _response()

    monkeypatch.setattr(provider, "urlopen", fake_open)
    remote = provider.Provider(
        "custom", "https://provider.example/v1/chat/completions", "model",
        api_key="secret")
    assert provider.chat_json(
        "raw history CANARY and hostname private.example",
        system="user free-text SYSTEM CANARY", provider=remote,
        remote_payload=VALID_PAYLOAD) == {"ok": True}
    messages = seen["body"]["messages"]
    assert messages[0]["content"] == provider.REMOTE_SYSTEM_PROMPT
    assert messages[1]["content"] == json.dumps(
        provider._validate_remote_payload(VALID_PAYLOAD),
        separators=(",", ":"), allow_nan=False)
    serialized = json.dumps(seen["body"])
    assert "CANARY" not in serialized
    assert "private.example" not in serialized
    assert "secret" not in serialized
    assert seen["headers"]["Authorization"] == "Bearer secret"


@pytest.mark.parametrize("payload", [
    None,
    {**VALID_PAYLOAD, "free_text": "send this"},
    {**VALID_PAYLOAD, "analysis_id": "not_registered"},
    {**VALID_PAYLOAD, "schema_version": True},
    {**VALID_PAYLOAD, "metrics": {**VALID_PAYLOAD["metrics"], "ssid": "CANARY"}},
    {**VALID_PAYLOAD, "metrics": {"streams": "4"}},
    {**VALID_PAYLOAD, "metrics": {"streams": 51}},
    {**VALID_PAYLOAD, "metrics": {"duration_seconds": 21_601}},
    {**VALID_PAYLOAD, "metrics": {"download_mbps": float("nan")}},
    {**VALID_PAYLOAD, "metrics": {"packet_loss_percent": 101}},
    {**VALID_PAYLOAD, "metrics": {"bufferbloat_grade": "A+"}},
])
def test_invalid_remote_payload_is_rejected_before_network(monkeypatch, payload):
    touched = []
    monkeypatch.setattr(provider, "_read_remote_ai_consent", lambda: True)
    monkeypatch.setattr(provider, "urlopen", lambda *_a, **_k: touched.append("socket"))
    remote = provider.Provider(
        "custom", "https://provider.example/v1/chat/completions", "model",
        api_key="secret")
    with pytest.raises(ValueError):
        provider.chat_json("free text", provider=remote, remote_payload=payload)
    assert touched == []


def test_local_provider_remains_available_without_remote_consent(monkeypatch):
    seen = {}
    monkeypatch.setattr(provider, "_read_remote_ai_consent",
                        lambda: pytest.fail("local provider read remote consent"))

    def fake_open(request, timeout=None):
        seen["body"] = json.loads(request.data)
        return _response()

    monkeypatch.setattr(provider, "urlopen", fake_open)
    local = provider.Provider(
        "local", "http://127.0.0.1:11434/v1/chat/completions", "model",
        requires_key=False, supports_json_mode=False, auth_style="none")
    assert provider.chat_json("local-only prompt", provider=local) == {"ok": True}
    assert "local-only prompt" in json.dumps(seen["body"])


def test_remote_analysis_registry_matches_engine_registry():
    from netmax import AI_SIGNATURES

    assert provider.REMOTE_ANALYSIS_IDS == frozenset(AI_SIGNATURES)


def test_validate_remote_payload_detailed_error_branches():
    def payload_with(metrics):
        return {"schema_version": 1, "analysis_id": "governor_preferences", "metrics": metrics}

    with pytest.raises(ValueError, match="invalid remote-AI mode"):
        provider._validate_remote_payload(payload_with({"mode": 123}))
    with pytest.raises(ValueError, match="invalid bufferbloat grade"):
        provider._validate_remote_payload(payload_with({"bufferbloat_grade": 456}))
    with pytest.raises(ValueError, match="invalid remote-AI latency_ms"):
        provider._validate_remote_payload(payload_with({"latency_ms": True}))
    with pytest.raises(ValueError, match="invalid remote-AI latency_ms"):
        provider._validate_remote_payload(payload_with({"latency_ms": "not_a_num"}))
    with pytest.raises(ValueError, match="invalid remote-AI latency_ms"):
        provider._validate_remote_payload(payload_with({"latency_ms": float("inf")}))

