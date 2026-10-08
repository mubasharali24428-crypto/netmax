"""SSRF and DNS-pinning policy tests for configurable AI endpoints."""

from __future__ import annotations

import socket

import pytest

import netmax_ai_provider as provider


def _records(*addresses):
    return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (address, 443))
            for address in addresses]


@pytest.mark.parametrize("url", [
    "http://api.example.com/v1/chat/completions",
    "ftp://api.example.com/v1/chat/completions",
    "file:///tmp/response.json",
    "https://user:password@api.example.com/v1/chat/completions",
    "https://127%2e0%2e0%2e1/v1/chat/completions",
    "https://api.example.com:90000/v1/chat/completions",
    "https://10.0.0.1/v1/chat/completions",
    "https://172.16.0.1/v1/chat/completions",
    "https://192.168.1.1/v1/chat/completions",
    "https://169.254.169.254/latest/meta-data",
    "https://224.0.0.1/v1/chat/completions",
    "http://localhost.attacker.example/v1/chat/completions",
])
def test_rejects_unsafe_provider_urls(url):
    with pytest.raises(ValueError):
        provider._resolve_provider_target(url)


@pytest.mark.parametrize("url", [
    "http://127.0.0.1:11434/v1/chat/completions",
    "http://[::1]:8080/v1/chat/completions",
    "http://localhost:1234/v1/chat/completions",
])
def test_exact_loopback_provider_urls_remain_available(monkeypatch, url):
    if "localhost" in url:
        monkeypatch.setattr(provider.socket, "getaddrinfo",
                            lambda *_args, **_kwargs: _records("127.0.0.1", "::1"))
    parsed, _address = provider._resolve_provider_target(url)
    assert provider._is_loopback(url)
    assert parsed.hostname in {"127.0.0.1", "::1", "localhost"}


@pytest.mark.parametrize("url", [
    "http://localhost.attacker.example/v1/chat/completions",
    "http://127.0.0.1.attacker.example/v1/chat/completions",
    "http://0.0.0.0/v1/chat/completions",
])
def test_lookalike_and_unspecified_hosts_are_not_local(url):
    assert not provider._is_loopback(url)
    with pytest.raises(ValueError):
        provider._resolve_provider_target(url)


def test_dns_answers_must_all_be_public(monkeypatch):
    monkeypatch.setattr(provider.socket, "getaddrinfo",
                        lambda *_args, **_kwargs: _records(
                            "93.184.216.34", "10.0.0.10"))
    with pytest.raises(ValueError, match="non-public"):
        provider._resolve_provider_target("https://gateway.example/v1/chat/completions")


def test_localhost_dns_must_stay_on_loopback(monkeypatch):
    monkeypatch.setattr(provider.socket, "getaddrinfo",
                        lambda *_args, **_kwargs: _records("127.0.0.1", "10.0.0.10"))
    with pytest.raises(ValueError, match="outside loopback"):
        provider._resolve_provider_target("http://localhost:11434/v1/chat/completions")


def test_redirect_rejects_private_target(monkeypatch):
    from urllib.request import Request

    handler = provider._ProviderRedirectHandler()
    with pytest.raises(ValueError, match="non-public"):
        handler.redirect_request(
            Request("https://gateway.example/v1/chat/completions"),
            None, 302, "Found", {}, "https://10.0.0.2/private")
    assert handler.max_redirections == 5


def test_provider_open_rejects_private_target_before_connect(monkeypatch):
    from urllib.request import Request

    connected = []
    monkeypatch.setattr(
        provider.socket, "create_connection",
        lambda *args, **kwargs: connected.append((args, kwargs)))
    with pytest.raises(ValueError, match="non-public"):
        provider.urlopen(Request("https://10.0.0.4/v1/chat/completions"), timeout=1)
    assert connected == []


def test_https_transport_pins_address_and_preserves_tls_hostname(monkeypatch):
    seen = {}

    class Context:
        def wrap_socket(self, sock, *, server_hostname):
            seen["server_hostname"] = server_hostname
            return ("tls", sock)

    monkeypatch.setattr(provider.socket, "create_connection",
                        lambda address, *_args, **_kwargs: seen.setdefault("address", address))
    connection = provider._PinnedHTTPSConnection(
        "gateway.example:443", "93.184.216.34", "gateway.example",
        context=Context())
    connection.connect()
    assert seen == {
        "address": ("93.184.216.34", 443),
        "server_hostname": "gateway.example",
    }


def test_custom_provider_resolution_does_not_mistake_substrings_for_loopback():
    config = provider.resolve({
        "NETMAX_AI_BASE": "https://127.0.0.1.attacker.example/v1/chat/completions"})
    assert config.requires_key is True
    assert provider._is_loopback(config.base) is False


def test_env_float_parsing(monkeypatch):
    monkeypatch.setenv("TEST_FLOAT", "25.5")
    assert provider._env_float("TEST_FLOAT", 10.0) == 25.5
    monkeypatch.setenv("TEST_FLOAT", "not_a_number")
    assert provider._env_float("TEST_FLOAT", 10.0) == 10.0
    monkeypatch.delenv("TEST_FLOAT", raising=False)
    assert provider._env_float("TEST_FLOAT", 10.0) == 10.0


def test_cloud_presets_resolution():
    for name in provider.CLOUD_PRESETS:
        p = provider.resolve({"NETMAX_AI_PROVIDER": name, "NETMAX_AI_API_KEY": "secret"})
        assert p.name == name
        assert p.requires_key is True
        assert p.supports_json_mode is True


def test_resolve_provider_target_dns_errors(monkeypatch):
    monkeypatch.setattr(provider.socket, "getaddrinfo", lambda *_a, **_k: [])
    with pytest.raises(ValueError, match="AI provider host did not resolve"):
        provider._resolve_provider_target("https://gateway.example/v1")

    def err_getaddrinfo(*_a, **_k):
        raise OSError("resolution failed")

    monkeypatch.setattr(provider.socket, "getaddrinfo", err_getaddrinfo)
    with pytest.raises(ValueError, match="AI provider host did not resolve safely"):
        provider._resolve_provider_target("https://gateway.example/v1")

    with pytest.raises(ValueError, match="malformed AI provider host"):
        provider._resolve_provider_target("https://-bad-label-.example/v1")


def test_keychain_and_env_helpers(monkeypatch):
    import subprocess

    def fake_run(args, **_kwargs):
        if "find-generic-password" in args:
            return subprocess.CompletedProcess(args, 0, stdout="found_key\n")
        return subprocess.CompletedProcess(args, 0)

    monkeypatch.setattr(provider.subprocess, "run", fake_run)
    assert provider.keychain_get() == "found_key"
    assert provider.keychain_set("new_key") is True

    def fail_run(_args, **_kwargs):
        raise OSError("keychain failed")

    monkeypatch.setattr(provider.subprocess, "run", fail_run)
    assert provider.keychain_get() == ""
    assert provider.keychain_set("new_key") is False

    monkeypatch.setenv(provider.ENV_API_KEY, "")
    monkeypatch.setattr(provider, "keychain_get", lambda *a: "kc_key")
    env = provider.live_env()
    assert env[provider.ENV_API_KEY] == "kc_key"

    p = provider.Provider(name="test", base="https://api.test", model="model-1", api_key="exported_key")
    provider.apply_to_env(p)
    assert provider.os.environ[provider.ENV_BASE] == "https://api.test"
    assert provider.os.environ[provider.ENV_MODEL] == "model-1"
    assert provider.os.environ[provider.ENV_API_KEY] == "exported_key"


def test_detect_local_probes(monkeypatch):
    class Resp:
        status = 200
        def __enter__(self): return self
        def __exit__(self, *a): pass

    monkeypatch.setattr(provider.urllib.request, "urlopen", lambda *_a, **_k: Resp())
    assert provider.detect_local(0.1) in dict(provider.LOCAL_PROBES)

    def fail_probe(*_a, **_k):
        raise OSError("refused")

    monkeypatch.setattr(provider.urllib.request, "urlopen", fail_probe)
    assert provider.detect_local(0.1) == ""

