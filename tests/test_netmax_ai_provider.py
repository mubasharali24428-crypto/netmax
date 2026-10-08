"""Tests for the model provider layer.

This exists to make item 48 ("local-first models") usable without bundling
a native runtime. Three barriers are pinned here, because each one silently
made a local model impossible before:

  1. No env var for the base URL.
  2. An API key was mandatory even for a keyless localhost server.
  3. `response_format: json_object` went out unconditionally, which many
     local servers reject.

The OFFLINE suite forbids real sockets, so every transport test drives a
fake urlopen — including a fake that REFUSES json mode, which is the case
that actually breaks in the field.
"""

from __future__ import annotations

import json

import pytest

import netmax_ai_provider as prov


REMOTE_PAYLOAD = {
    "schema_version": 1,
    "analysis_id": "governor_preferences",
    "metrics": {"streams": 2, "download_mbps": 10.0},
}


@pytest.fixture(autouse=True)
def _allow_remote_transport_unit_tests(monkeypatch):
    # These tests exercise transport behavior with fake urlopen responses.
    # Consent enforcement itself is covered independently in test_ai_egress_policy.
    monkeypatch.setattr(prov, "_read_remote_ai_consent", lambda: True)


def _reply(content, *, reject_json_mode=False):
    """Fake urlopen; optionally refuses `response_format` like a local server."""
    state = {"json_mode_seen": False, "calls": 0}

    class Resp:
        status = 200

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def read(self, size=-1):
            data = json.dumps({
                "choices": [{"message": {"content": content}}]
            }).encode("utf-8")
            return data if size < 0 else data[:size]

    def fake(req, timeout=None):
        state["calls"] += 1
        body = json.loads(req.data.decode("utf-8"))
        state["json_mode_seen"] = "response_format" in body
        if reject_json_mode and "response_format" in body:
            raise prov.HTTPError(req.full_url, 400, "unsupported", {}, None)
        return Resp()

    return fake, state


class TestResolution:
    def test_nothing_configured_is_openai_and_unconfigured(self):
        p = prov.resolve({})
        assert p.name == "openai"
        assert p.configured is False

    def test_openai_key_configures_it(self):
        assert prov.resolve({"NETMAX_AI_API_KEY": "sk-x"}).configured is True

    def test_loopback_needs_no_key(self):
        """The single biggest barrier to a local model."""
        p = prov.resolve(
            {"NETMAX_AI_BASE": "http://127.0.0.1:11434/v1/chat/completions"})
        assert p.requires_key is False
        assert p.configured is True
        assert p.auth_style == "none"

    def test_localhost_is_also_loopback(self):
        p = prov.resolve(
            {"NETMAX_AI_BASE": "http://localhost:8080/v1/chat/completions"})
        assert p.requires_key is False

    def test_remote_custom_base_still_needs_a_key(self):
        p = prov.resolve({"NETMAX_AI_BASE": "https://gw.example/v1/chat/completions"})
        assert p.requires_key is True
        assert p.configured is False

    def test_remote_base_with_key_works(self):
        p = prov.resolve({"NETMAX_AI_BASE": "https://gw.example/v1/chat/completions",
                          "NETMAX_AI_API_KEY": "k"})
        assert p.configured is True
        assert p.auth_style == "bearer"

    def test_local_preset_defaults_to_ollama_port(self):
        p = prov.resolve({"NETMAX_AI_PROVIDER": "ollama"})
        assert "11434" in p.base
        assert p.configured is True

    def test_anthropic_uses_its_own_dialect(self):
        p = prov.resolve({"NETMAX_AI_PROVIDER": "anthropic",
                          "NETMAX_AI_API_KEY": "sk-ant"})
        assert p.auth_style == "x-api-key"
        assert p.extra_headers.get("anthropic-version")
        assert p.supports_json_mode is False

    def test_model_override_is_honoured(self):
        assert prov.resolve({"NETMAX_AI_MODEL": "my-model"}).model == "my-model"

    def test_local_presets_do_not_advertise_json_mode(self):
        """They usually reject it; pretending otherwise causes a failed call."""
        for preset in ("local", "ollama", "llamacpp", "lmstudio"):
            assert prov.resolve({"NETMAX_AI_PROVIDER": preset}).supports_json_mode is False


class TestRequestShaping:
    def test_openai_shape(self):
        p = prov.resolve({"NETMAX_AI_API_KEY": "k"})
        body = prov._build_request(p, "hi", "sys", 100, json_mode=True)
        assert body["messages"][0]["role"] == "system"
        assert body["response_format"] == {"type": "json_object"}

    def test_json_mode_off_omits_response_format(self):
        p = prov.resolve({"NETMAX_AI_API_KEY": "k"})
        body = prov._build_request(p, "hi", "sys", 100, json_mode=False)
        assert "response_format" not in body
        assert "JSON" in body["messages"][0]["content"]

    def test_anthropic_shape_has_system_outside_messages(self):
        p = prov.resolve({"NETMAX_AI_PROVIDER": "anthropic",
                          "NETMAX_AI_API_KEY": "k"})
        body = prov._build_request(p, "hi", "sys", 100, json_mode=False)
        # Anthropic has no response_format either, so it needs the same
        # compensating instruction the local providers get.
        assert body["system"].startswith("sys")
        assert "JSON" in body["system"]
        assert all("role" in m for m in body["messages"])


class TestBoundedResponses:
    def test_response_byte_limit_stops_read_and_does_not_retry(self, monkeypatch):
        body = json.dumps({"choices": [{"message": {"content": '{"ok":true}'}}]}).encode()
        seen = {"calls": 0, "size": None}

        class Resp:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def read(self, size=-1):
                seen["size"] = size
                return body[:size]

        def fake(*_args, **_kwargs):
            seen["calls"] += 1
            return Resp()

        monkeypatch.setattr(prov, "urlopen", fake)
        with pytest.raises(prov.ProviderResponseLimitError):
            prov.chat_json(
                "hi", provider=prov.Provider("test", "https://example.invalid", "m",
                                             requires_key=False),
                max_response_bytes=10, remote_payload=REMOTE_PAYLOAD)
        assert seen == {"calls": 1, "size": 11}

    def test_model_json_depth_limit_is_enforced(self, monkeypatch):
        content = "{" * 17 + "\"x\"" + "}" * 17
        fake, _state = _reply(content)
        monkeypatch.setattr(prov, "urlopen", fake)
        with pytest.raises(prov.ProviderResponseLimitError):
            prov.chat_json(
                "hi", provider=prov.Provider("test", "https://example.invalid", "m",
                                             requires_key=False),
                max_json_depth=16, remote_payload=REMOTE_PAYLOAD)
    def test_bearer_header_when_keyed(self):
        p = prov.resolve({"NETMAX_AI_API_KEY": "k"})
        assert prov._headers(p)["Authorization"] == "Bearer k"

    def test_no_auth_header_when_keyless(self):
        p = prov.resolve({"NETMAX_AI_BASE": "http://127.0.0.1:1/v1/chat/completions"})
        assert "Authorization" not in prov._headers(p)


class TestJsonModeDegradation:
    def test_retries_without_json_mode_when_refused(self, monkeypatch):
        fake, state = _reply(json.dumps({"ok": True}), reject_json_mode=True)
        monkeypatch.setattr(prov, "urlopen", fake)
        out = prov.chat_json("hi", env={"NETMAX_AI_API_KEY": "k"},
                             remote_payload=REMOTE_PAYLOAD)
        assert out == {"ok": True}
        assert state["calls"] == 2          # refused, then retried
        assert state["json_mode_seen"] is False

    def test_local_provider_sends_no_json_mode_at_all(self, monkeypatch):
        fake, state = _reply(json.dumps({"ok": True}))
        monkeypatch.setattr(prov, "urlopen", fake)
        prov.chat_json("hi", env={"NETMAX_AI_PROVIDER": "ollama"})
        assert state["calls"] == 1
        assert state["json_mode_seen"] is False

    def test_first_attempt_succeeds_without_retrying(self, monkeypatch):
        fake, state = _reply(json.dumps({"ok": True}))
        monkeypatch.setattr(prov, "urlopen", fake)
        prov.chat_json("hi", env={"NETMAX_AI_API_KEY": "k"},
                       remote_payload=REMOTE_PAYLOAD)
        assert state["calls"] == 1

    def test_hard_failure_is_raised_not_retried_forever(self, monkeypatch):
        def boom(req, timeout=None):
            raise prov.HTTPError(req.full_url, 500, "server", {}, None)
        monkeypatch.setattr(prov, "urlopen", boom)
        with pytest.raises(prov.HTTPError):
            prov.chat_json("hi", env={"NETMAX_AI_API_KEY": "k"},
                           remote_payload=REMOTE_PAYLOAD)


class TestLenientParsing:
    """Local models wrap JSON in fences despite being told not to."""

    @pytest.mark.parametrize("content", [
        '{"ok": true}',
        '```json\n{"ok": true}\n```',
        '```\n{"ok": true}\n```',
        'Here you go: {"ok": true}',
        '  {"ok": true}  ',
    ])
    def test_recovers_json_from_common_wrappers(self, content):
        assert prov._parse_json(content) == {"ok": True}

    def test_non_object_json_is_rejected(self):
        with pytest.raises(TypeError):
            prov._parse_json("[1,2,3]")

    def test_prose_with_no_json_is_rejected(self):
        with pytest.raises(ValueError):
            prov._parse_json("I cannot help with that")

    def test_anthropic_content_blocks_are_joined(self):
        p = prov.resolve({"NETMAX_AI_PROVIDER": "anthropic",
                          "NETMAX_AI_API_KEY": "k"})
        body = {"content": [{"type": "text", "text": '{"ok":'},
                            {"type": "text", "text": " true}"}]}
        assert prov._extract_content(p, body) == '{"ok": true}'


class TestVerify:
    def test_reports_unconfigured_without_calling_out(self, monkeypatch):
        def forbidden(req, timeout=None):
            raise AssertionError("must not call out when unconfigured")
        monkeypatch.setattr(prov, "urlopen", forbidden)
        out = prov.verify({})
        assert out["reachable"] is False
        assert "NETMAX_AI_API_KEY" in out["detail"]

    def test_reports_reachable_on_success(self, monkeypatch):
        fake, _ = _reply(json.dumps({"ok": True}))
        monkeypatch.setattr(prov, "urlopen", fake)
        out = prov.verify({"NETMAX_AI_API_KEY": "k"})
        assert out["reachable"] is True
        assert out["provider"] == "openai"

    def test_reports_failure_without_raising(self, monkeypatch):
        def boom(req, timeout=None):
            raise prov.URLError("refused")
        monkeypatch.setattr(prov, "urlopen", boom)
        out = prov.verify({"NETMAX_AI_API_KEY": "k"})
        assert out["reachable"] is False
        assert "URLError" in out["detail"]

    def test_flags_a_local_endpoint_as_local(self):
        out = prov.verify({"NETMAX_AI_BASE": "http://127.0.0.1:11434/v1/chat/completions"})
        assert out["local"] is True
        assert out["has_key"] is False


class TestKeylessLocalIsActuallyReachable:
    """Regression: fixing the transport is not the same as fixing the gate.

    An earlier version made `_chat_json` accept a keyless loopback base but
    left every analyser asking `if self.api_key:`. A local model was then
    still unreachable — the transport said yes and the caller never asked.
    """

    def test_has_provider_is_true_for_a_keyless_loopback(self):
        assert prov.has_provider(
            {"NETMAX_AI_BASE": "http://127.0.0.1:11434/v1/chat/completions"}) is True

    def test_has_provider_is_false_with_nothing_configured(self):
        assert prov.has_provider({}) is False

    def test_an_explicit_key_counts_without_the_environment(self):
        assert prov.has_provider({}, api_key="k") is True

    def test_an_explicit_key_does_not_rescue_a_broken_env(self):
        """A supplied key is sufficient on its own."""
        assert prov.has_provider({"NETMAX_AI_BASE": "https://x/v1/chat/completions"},
                                 api_key="k") is True

    def test_analysers_take_the_model_path_with_only_a_local_base(self, monkeypatch):
        """The end-to-end property, across all three AI modules.

        With ONLY a loopback base set, every analyser must be willing to
        consult a model. Transport is stubbed so this stays offline.
        """
        import netmax_ai
        import netmax_ai_p1
        import netmax_ai_p2

        monkeypatch.setenv("NETMAX_AI_BASE",
                           "http://127.0.0.1:11434/v1/chat/completions")
        monkeypatch.delenv("NETMAX_AI_API_KEY", raising=False)

        for cls in (netmax_ai.PredictiveShaper,
                    netmax_ai.EndpointStrategySelector,
                    netmax_ai_p1.RootCauseClassifier,
                    netmax_ai_p1.MultiObjectiveOptimizer,
                    netmax_ai_p2.ResultExplainer):
            assert prov.has_provider(api_key=cls().api_key) is True, cls.__name__

        # And the governor really does attempt the call — then degrades
        # safely when the endpoint is not there, instead of raising.
        fake, state = _reply(json.dumps({"streams": 2}))
        monkeypatch.setattr(prov, "urlopen", fake)
        decision = netmax_ai.AISpeedGovernor(
            api_base="http://127.0.0.1:11434/v1/chat/completions"
        ).decide(5.0, {"mbps": 5})
        assert state["calls"] == 1
        assert decision.streams == 2

    def test_unreachable_local_endpoint_degrades_without_raising(self, monkeypatch):
        """A configured-but-dead local model must not break the run."""
        import netmax_ai

        monkeypatch.setenv("NETMAX_AI_BASE",
                           "http://127.0.0.1:11434/v1/chat/completions")
        monkeypatch.delenv("NETMAX_AI_API_KEY", raising=False)

        def boom(req, timeout=None):
            raise prov.URLError("connection refused")

        monkeypatch.setattr(prov, "urlopen", boom)
        # A dead endpoint must not raise: decide() swallows the transport
        # error and returns None, which tells the caller to keep the
        # hardcoded pace. That is the whole safety property.
        assert netmax_ai.AISpeedGovernor(
            api_base="http://127.0.0.1:11434/v1/chat/completions"
        ).decide(5.0, {"mbps": 5}) is None

    def test_analysers_stay_local_with_no_configuration(self, monkeypatch):
        import netmax_ai
        monkeypatch.delenv("NETMAX_AI_BASE", raising=False)
        monkeypatch.delenv("NETMAX_AI_API_KEY", raising=False)
        monkeypatch.delenv("NETMAX_AI_PROVIDER", raising=False)

        governor = netmax_ai.AISpeedGovernor()
        assert governor.decide(5.0, {"mbps": 5}) is None      # no call attempted
        shaper = netmax_ai.PredictiveShaper()
        for _ in range(3):
            shaper.record_interval(50.0, 4, 50.0)
        out = shaper.suggest(50.0, 50.0, 12.0, 5.0, 5.0, 4)
        assert out["type"] == "high_jitter_loss"               # heuristics answered
        assert "source" not in out
