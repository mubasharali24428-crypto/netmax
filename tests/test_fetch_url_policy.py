"""URL, DNS-pinning, redirect, and response-size boundaries for downloads."""

from __future__ import annotations

import socket

import pytest

import netmax_fetch
from netmax import NetMaxError


def _records(*addresses):
    return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (address, 443))
            for address in addresses]


@pytest.mark.parametrize("url", [
    "file:///etc/passwd",
    "ftp://example.com/file",
    "http://example.com/file",
    "https://user:secret@example.com/file",
    "https://127%2e0%2e0%2e1/file",
    "https://example.com:70000/file",
    "https://bad..host/file",
    "https://127.0.0.1/file",
    "https://10.0.0.1/file",
    "https://172.16.0.1/file",
    "https://192.168.1.1/file",
    "https://169.254.1.2/file",
    "https://169.254.169.254/latest/meta-data",
    "https://224.0.0.1/file",
    "https://0.0.0.0/file",
])
def test_rejects_unsupported_malformed_or_nonpublic_download_urls(url):
    with pytest.raises(NetMaxError):
        netmax_fetch._resolve_download_target(url)


def test_public_dns_result_is_returned_for_pinning(monkeypatch):
    monkeypatch.setattr(netmax_fetch.socket, "getaddrinfo",
                        lambda *_args, **_kwargs: _records("93.184.216.34"))
    parsed, address = netmax_fetch._resolve_download_target(
        "https://download.example/file")
    assert parsed.hostname == "download.example"
    assert address == "93.184.216.34"


@pytest.mark.parametrize("answers", [
    ("10.0.0.5",),
    ("93.184.216.34", "192.168.1.5"),
    ("169.254.169.254",),
])
def test_rejects_dns_answers_that_include_nonpublic_targets(monkeypatch, answers):
    monkeypatch.setattr(netmax_fetch.socket, "getaddrinfo",
                        lambda *_args, **_kwargs: _records(*answers))
    with pytest.raises(NetMaxError, match="non-public"):
        netmax_fetch._resolve_download_target("https://download.example/file")


def test_http_loopback_is_explicitly_test_only():
    with pytest.raises(NetMaxError):
        netmax_fetch._resolve_download_target("http://127.0.0.1/file")
    _parsed, address = netmax_fetch._resolve_download_target(
        "http://127.0.0.1/file", allow_http_loopback=True)
    assert address == "127.0.0.1"
    with pytest.raises(NetMaxError):
        netmax_fetch._resolve_download_target(
            "http://localhost/file", allow_http_loopback=True)


def test_redirect_rejects_private_target(monkeypatch):
    from urllib.request import Request

    handler = netmax_fetch._PolicyRedirectHandler()
    request = Request("https://download.example/start")
    with pytest.raises(NetMaxError, match="non-public"):
        handler.redirect_request(
            request, None, 302, "Found", {}, "https://169.254.169.254/latest/meta-data")
    assert handler.max_redirections == 5


def test_network_open_rejects_private_target_before_connect(monkeypatch):
    from urllib.request import Request

    connected = []
    monkeypatch.setattr(
        netmax_fetch.socket, "create_connection",
        lambda *args, **kwargs: connected.append((args, kwargs)))
    with pytest.raises(NetMaxError, match="non-public"):
        netmax_fetch.urlopen(Request("https://10.0.0.4/file"), timeout=1)
    assert connected == []


def test_https_connection_uses_pinned_address_and_original_tls_name(monkeypatch):
    seen = {}

    class Context:
        def wrap_socket(self, sock, *, server_hostname):
            seen["server_hostname"] = server_hostname
            return ("tls", sock)

    monkeypatch.setattr(netmax_fetch.socket, "create_connection",
                        lambda address, *_args, **_kwargs: seen.setdefault("address", address))
    connection = netmax_fetch._PinnedHTTPSConnection(
        "download.example:443", "93.184.216.34", "download.example",
        context=Context())
    connection.connect()
    assert seen == {
        "address": ("93.184.216.34", 443),
        "server_hostname": "download.example",
    }


def test_download_uses_head_and_rejects_declared_oversize(monkeypatch, tmp_path):
    methods = []

    class Response:
        def __init__(self):
            self.status = 200
            self.headers = {"Content-Length": "5"}

        def getcode(self):
            return self.status

        def close(self):
            pass

    def fake_open(req, timeout=None):
        methods.append(req.get_method())
        return Response()

    monkeypatch.setattr(netmax_fetch, "MAX_DOWNLOAD_BYTES", 4)
    monkeypatch.setattr(netmax_fetch, "urlopen", fake_open)
    with pytest.raises(NetMaxError, match="1 GiB"):
        netmax_fetch.download("https://download.example/file", tmp_path / "file")
    assert methods == ["HEAD"]


def test_exact_download_size_limit_is_accepted(monkeypatch, tmp_path):
    class Response:
        def __init__(self, method):
            self.status = 200
            self.headers = {}
            self.data = b"1234" if method == "GET" else b""

        def getcode(self):
            return self.status

        def read(self, size=-1):
            block, self.data = self.data[:size], self.data[size:]
            return block

        def close(self):
            pass

    monkeypatch.setattr(netmax_fetch, "MAX_DOWNLOAD_BYTES", 4)
    monkeypatch.setattr(
        netmax_fetch, "urlopen",
        lambda req, timeout=None: Response(req.get_method()))
    out = tmp_path / "file"
    result = netmax_fetch.download("https://download.example/file", out)
    assert result["bytes"] == 4
    assert out.read_bytes() == b"1234"


def test_unknown_length_body_stops_at_exact_limit(monkeypatch, tmp_path):
    methods = []

    class Response:
        def __init__(self, data=b""):
            self.status = 200
            self.headers = {}
            self.data = data

        def getcode(self):
            return self.status

        def read(self, size=-1):
            block, self.data = self.data[:size], self.data[size:]
            return block

        def close(self):
            pass

    def fake_open(req, timeout=None):
        methods.append(req.get_method())
        return Response(b"12345" if req.get_method() == "GET" else b"")

    monkeypatch.setattr(netmax_fetch, "MAX_DOWNLOAD_BYTES", 4)
    monkeypatch.setattr(netmax_fetch, "urlopen", fake_open)
    with pytest.raises(NetMaxError, match="1 GiB"):
        netmax_fetch.download("https://download.example/file", tmp_path / "file")
    assert methods == ["HEAD", "GET"]
    assert (tmp_path / "file").read_bytes() == b""


def test_range_response_cannot_exceed_its_requested_chunk(monkeypatch, tmp_path):
    class Response:
        def __init__(self, headers=None, data=b""):
            self.status = 200
            self.headers = headers or {}
            self.data = data

        def getcode(self):
            return self.status

        def read(self, size=-1):
            block, self.data = self.data[:size], self.data[size:]
            return block

        def close(self):
            pass

    def fake_open(req, timeout=None):
        if req.get_method() == "HEAD":
            return Response({"Content-Length": "4", "Accept-Ranges": "bytes"})
        return Response(data=b"abc")

    monkeypatch.setattr(netmax_fetch, "MAX_DOWNLOAD_BYTES", 4)
    monkeypatch.setattr(netmax_fetch, "urlopen", fake_open)
    with pytest.raises(NetMaxError, match="exceeds requested range"):
        netmax_fetch.download(
            "https://download.example/file", tmp_path / "file", streams=2)


def test_read_block_exception_mapping():
    import http.client

    class IncompleteResp:
        def read(self, _n):
            raise http.client.IncompleteRead(b"bad")

    class OsErrResp:
        def read(self, _n):
            raise OSError("socket closed")

    with pytest.raises(NetMaxError, match="connection closed mid-read"):
        netmax_fetch._read_block(IncompleteResp())
    with pytest.raises(NetMaxError, match="read failed"):
        netmax_fetch._read_block(OsErrResp())


def test_resolve_download_target_empty_and_localhost_external(monkeypatch):
    monkeypatch.setattr(netmax_fetch.socket, "getaddrinfo", lambda *_a, **_k: [])
    with pytest.raises(NetMaxError, match="download host did not resolve"):
        netmax_fetch._resolve_download_target("https://download.example/file")

    monkeypatch.setattr(
        netmax_fetch.socket, "getaddrinfo",
        lambda *_a, **_k: _records("93.184.216.34"))
    with pytest.raises(NetMaxError, match="localhost resolved outside loopback"):
        netmax_fetch._resolve_download_target("https://localhost/file")


def test_urlopen_maps_http_error(monkeypatch):
    from urllib.error import HTTPError
    from urllib.request import Request

    class DummyOpener:
        def open(self, *_a, **_k):
            raise HTTPError("https://download.example/file", 404, "Not Found", {}, None)

    monkeypatch.setattr(netmax_fetch, "build_opener", lambda *_a: DummyOpener())
    with pytest.raises(NetMaxError, match="HTTP request to .* failed"):
        netmax_fetch.urlopen(Request("https://download.example/file"))


def test_split_chunks_zero_or_negative():
    assert netmax_fetch.split_chunks(0, 4) == []
    assert netmax_fetch.split_chunks(-5, 2) == []


def test_counter_progress_trigger():
    calls = []
    counter = netmax_fetch._Counter(1_000_000, lambda done, total: calls.append((done, total)))
    counter.add(netmax_fetch.PROGRESS_EVERY + 10)
    assert len(calls) == 1
    counter.flush()
    assert len(calls) == 2


def test_assert_safe_out_dir_world_writable(monkeypatch, tmp_path):
    d = tmp_path / "shared_subdir"
    d.mkdir()
    monkeypatch.setattr(netmax_fetch, "_SHARED_ROOTS", (str(tmp_path),))
    d.chmod(0o777)
    with pytest.raises(NetMaxError, match="world-writable"):
        netmax_fetch._assert_safe_out_dir(d / "file.bin")


def test_single_stream_and_chunk_http_errors(monkeypatch, tmp_path):
    class ErrorResponse:
        status = 500
        def getcode(self): return 500
        def close(self): pass

    monkeypatch.setattr(netmax_fetch, "_open", lambda *a, **k: ErrorResponse())
    with pytest.raises(NetMaxError, match="range request .* got HTTP 500"):
        counter = netmax_fetch._Counter(10, None)
        netmax_fetch._fetch_chunk("https://download.example/file", 0, 0, 9, tmp_path / "part.0", counter)

    monkeypatch.setattr(netmax_fetch, "_head", lambda *a, **k: (None, False))
    with pytest.raises(NetMaxError, match="GET .* returned HTTP 500"):
        netmax_fetch.download("https://download.example/file", tmp_path / "out.bin", streams=1)


def test_fetch_chunk_resumes_existing_partial(monkeypatch, tmp_path):
    part = tmp_path / "part.0"
    part.write_bytes(b"123")

    class FakeChunkResponse:
        status = 206
        def getcode(self): return 206
        def close(self): pass

    resp = FakeChunkResponse()
    def fake_read(_r, _n):
        if not hasattr(resp, "_done"):
            resp._done = True
            return b"45"
        return b""

    monkeypatch.setattr(netmax_fetch, "_open", lambda *a, **k: resp)
    monkeypatch.setattr(netmax_fetch, "_read_block", fake_read)
    counter = netmax_fetch._Counter(5, None)
    netmax_fetch._fetch_chunk("https://download.example/file", 0, 0, 4, part, counter)
    assert part.read_bytes() == b"12345"
    assert counter.done == 5
    assert counter.net == 2


