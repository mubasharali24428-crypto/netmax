"""Shared fixtures for the netmax offline test suite.

Hard guarantee: no test may touch the real network. An autouse fixture arms
tripwires on every OS-level I/O seam netmax could reach (subprocess.run,
getaddrinfo, socket creation). Individual tests then replace these seams with
fakes via their own monkeypatch.setattr calls — a later setattr on the same
attribute wins, so a test that installs a fake implicitly disarms that one
tripwire while all others stay armed.
"""

import socket
import subprocess
import sys
from pathlib import Path

import pytest

# Make the project root (parent of tests/) importable so `import netmax` works
# regardless of where pytest is invoked from.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))


def _tripwire(seam: str):
    def guard(*args, **kwargs):
        raise AssertionError(
            f"offline suite attempted real {seam} — mock it in the test"
        )

    return guard


@pytest.fixture(autouse=True)
def offline_guarantee(monkeypatch):
    """Block every real network/process seam for the duration of each test."""
    monkeypatch.setattr(subprocess, "run", _tripwire("subprocess.run"))
    monkeypatch.setattr(socket, "getaddrinfo", _tripwire("socket.getaddrinfo"))
    monkeypatch.setattr(socket, "create_connection", _tripwire("socket.create_connection"))
    monkeypatch.setattr(socket, "socket", _tripwire("socket.socket"))


# Every NETMAX_AI_* variable, so the fixture below clears the whole set
# without having to track new ones as they are added.
_AI_ENV_VARS = (
    "NETMAX_AI_API_KEY", "NETMAX_AI_BASE", "NETMAX_AI_MODEL",
    "NETMAX_AI_PROVIDER", "NETMAX_AI_TIMEOUT", "NETMAX_AI_ENDPOINT",
)


@pytest.fixture(autouse=True)
def clean_ai_environment(monkeypatch):
    """Start every test with no ambient AI-provider configuration.

    Two reasons, both learned the hard way:

    1. A developer's real environment (or an exported shell variable) must
       not decide whether a test passes. Tests control their own inputs.
    2. Provider resolution reads os.environ, so a stray NETMAX_AI_BASE left
       behind by an earlier test silently flips `has_provider()` to true.
       The analysers then attempt a real model call, and the next test
       fails on the offline tripwire hundreds of lines away from the cause.

    Restored by monkeypatch at teardown, so a test may still set these
    itself with monkeypatch.setenv.
    """
    for name in _AI_ENV_VARS:
        monkeypatch.delenv(name, raising=False)
