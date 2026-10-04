"""Tests for the merged provider extras: per-server ports, cloud presets,
Keychain storage, local detection, and env application.

resolve()/verify()/chat_json() themselves are covered in
test_netmax_ai_provider.py — this file covers only the additions.
No real network or Keychain: urlopen and module attrs are faked.
"""

from __future__ import annotations

import json
import os

import pytest

import netmax_ai_provider as prov


@pytest.fixture(autouse=True)
def _no_keychain(monkeypatch):
    monkeypatch.setattr(prov, "keychain_get", lambda account="default": "")


def _resp(payload: dict, status: int = 200):
    class Fake:
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        @property
        def status(self):
            return status

        def read(self):
            return json.dumps(payload).encode()

    return Fake()


def test_local_presets_use_their_own_ports():
    assert "11434" in prov.resolve({"NETMAX_AI_PROVIDER": "ollama"}).base
    assert "1234" in prov.resolve({"NETMAX_AI_PROVIDER": "lmstudio"}).base
    assert "8080" in prov.resolve({"NETMAX_AI_PROVIDER": "llamacpp"}).base


def test_local_preset_default_models():
    assert prov.resolve({"NETMAX_AI_PROVIDER": "lmstudio"}).model == "local-model"
    assert prov.resolve({"NETMAX_AI_PROVIDER": "llamacpp"}).model == "default"


def test_cloud_presets_need_keys():
    for name in ("gemini", "deepseek", "groq", "mistral", "openrouter"):
        p = prov.resolve({"NETMAX_AI_PROVIDER": name})
        assert p.requires_key and not p.configured, name
        assert p.auth_style == "bearer", name
        p = prov.resolve({"NETMAX_AI_PROVIDER": name,
                          "NETMAX_AI_API_KEY": "k"})
        assert p.configured, name


def test_live_env_overlays_keychain_key(monkeypatch):
    monkeypatch.setattr(prov, "keychain_get", lambda account="default": "kc")
    monkeypatch.delenv(prov.ENV_API_KEY, raising=False)
    assert prov.live_env()[prov.ENV_API_KEY] == "kc"


def test_live_env_keeps_explicit_key(monkeypatch):
    monkeypatch.setattr(prov, "keychain_get", lambda account="default": "kc")
    monkeypatch.setenv(prov.ENV_API_KEY, "env-key")
    assert prov.live_env()[prov.ENV_API_KEY] == "env-key"


def test_keychain_failures_are_quiet(monkeypatch):
    monkeypatch.undo()
    def boom(*a, **k):
        raise FileNotFoundError("no security CLI")

    monkeypatch.setattr(prov.subprocess, "run", boom)
    assert prov.keychain_get() == ""
    assert prov.keychain_set("k") is False


def test_detect_local_picks_first_alive(monkeypatch):
    calls = []

    def fake(url, timeout=None):
        calls.append(url)
        if "8080" in url:
            return _resp({})
        raise OSError("refused")

    monkeypatch.setattr(prov.urllib.request, "urlopen", fake)
    assert prov.detect_local() == "llamacpp"
    assert len(calls) == 3


def test_detect_local_none_alive(monkeypatch):
    def boom(url, timeout=None):
        raise OSError("refused")

    monkeypatch.setattr(prov.urllib.request, "urlopen", boom)
    assert prov.detect_local() == ""


def test_apply_to_env(monkeypatch):
    for var in (prov.ENV_BASE, prov.ENV_MODEL, prov.ENV_API_KEY):
        monkeypatch.delenv(var, raising=False)
    p = prov.resolve({"NETMAX_AI_PROVIDER": "ollama"})
    prov.apply_to_env(p)
    assert os.environ[prov.ENV_BASE] == p.base
    assert os.environ[prov.ENV_MODEL] == p.model
    assert prov.ENV_API_KEY not in os.environ  # keyless: nothing to export
