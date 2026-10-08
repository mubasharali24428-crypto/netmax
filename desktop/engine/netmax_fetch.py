#!/usr/bin/env python3
"""netmax_fetch — chunked multi-stream download accelerator (Mission 3 F1).

Splits a ranged HTTP resource into N byte-range chunks fetched in parallel,
resumable via <out>.netmax-part-N files plus a <out>.netmax-meta.json manifest.
Falls back to a single stream when the server ignores Accept-Ranges.
"""

from __future__ import annotations

import http.client
import ipaddress
import json
import os
import shutil
import socket
import ssl
import stat
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin, urlsplit
from urllib.request import (
    HTTPHandler, HTTPRedirectHandler, HTTPSHandler, ProxyHandler, Request,
    build_opener,
)

try:
    from netmax import NetMaxError
except ImportError:  # allow running as a bare script
    class NetMaxError(RuntimeError):
        """A download could not be completed."""


CHUNK_SUFFIX = ".netmax-part-{}"
META_SUFFIX = ".netmax-meta.json"
PROGRESS_EVERY = 65536  # bytes between on_progress callbacks per worker
MAX_DOWNLOAD_BYTES = 1 << 30
MAX_REDIRECTS = 5
_ALLOW_HTTP_LOOPBACK_TESTS = False

# F10 hardening: refuse downloads into WORLD-WRITABLE directories, where a
# local attacker could pre-place symlinks for our predictable part/meta
# names. Only the sticky shared roots themselves are refused (mode & 0o002
# with sticky bit), not their private per-user subtrees (e.g. pytest's
# 0700 tmp dirs) — those are already attacker-inaccessible.
_SHARED_ROOTS = ("/tmp", "/private/tmp", "/var/tmp", "/Users/Shared")


def _read_block(resp, n: int = 65536) -> bytes:
    """Read one body block; map mid-stream failures onto NetMaxError.

    urllib can raise `http.client.IncompleteRead` (or an OSError on a
    reset socket) when the peer closes early — that used to escape
    `download()` as a bare exception instead of the documented
    NetMaxError contract.
    """
    try:
        return resp.read(n)
    except http.client.IncompleteRead as exc:
        raise NetMaxError(f"connection closed mid-read: {exc}") from exc
    except OSError as exc:
        raise NetMaxError(f"read failed: {exc}") from exc


def _assert_safe_out_dir(out_path: Path) -> None:
    """Refuse world-writable shared dirs so part files can't be symlinked."""
    parent = out_path.parent
    resolved = str(parent.resolve())
    # Private subtrees under a shared root are fine (0700 per-user dirs).
    for root in _SHARED_ROOTS:
        if resolved != root and not resolved.startswith(root + "/"):
            continue
        if resolved == root:
            raise NetMaxError(
                f"refusing to download into shared directory {resolved} "
                "(predictable part files are symlink-vulnerable there)"
            )
        # Subdirectory of a shared root: allowed only if NOT world-writable.
        try:
            mode = os.stat(parent).st_mode
        except OSError:
            return  # let the later open() surface the real error
        if mode & 0o002:  # world-writable
            raise NetMaxError(
                f"refusing to download into world-writable directory {resolved} "
                "(predictable part files are symlink-vulnerable there)"
            )
        return


def _open_excl(path: Path) -> int:
    """Open for append-create, FAILING if the path already exists (symlink-safe).

    Regular appends still work: a completed prior part keeps its size and
    resumes via a fresh O_EXCL open after an explicit rename-in.
    """
    return os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)


def _resolve_download_target(url: str, *, allow_http_loopback: bool = False):
    """Validate a download URL and pin it to a validated public address."""
    try:
        parsed = urlsplit(url)
        hostname = parsed.hostname
        explicit_port = parsed.port
        port = explicit_port if explicit_port is not None else (
            443 if parsed.scheme.lower() == "https" else 80)
    except (TypeError, ValueError) as exc:
        raise NetMaxError("malformed download URL") from exc
    if (parsed.scheme.lower() not in {"https", "http"} or not hostname
            or parsed.username is not None or parsed.password is not None
            or "%" in hostname or not 1 <= port <= 65535
            or any(ord(char) < 33 for char in hostname)):
        raise NetMaxError("download URL must have a valid host and no credentials")
    literal = None
    try:
        literal = ipaddress.ip_address(hostname)
    except ValueError:
        pass
    if literal is None:
        try:
            ascii_host = hostname.rstrip(".").encode("idna").decode("ascii")
            labels = ascii_host.split(".")
            valid_host = (len(ascii_host) <= 253 and all(
                0 < len(label) <= 63 and label[0].isalnum()
                and label[-1].isalnum()
                and all(char.isalnum() or char == "-" for char in label)
                for label in labels))
        except UnicodeError:
            valid_host = False
        if not valid_host:
            raise NetMaxError("malformed download host")
    local_literal = literal is not None and literal.is_loopback
    local_name = hostname.lower().rstrip(".") == "localhost"
    if parsed.scheme.lower() == "http" and not (
            allow_http_loopback and local_literal):
        raise NetMaxError("downloads require HTTPS")
    try:
        records = ([(None, None, None, None, (str(literal), port))]
                   if literal is not None
                   else socket.getaddrinfo(hostname, port, type=socket.SOCK_STREAM))
        addresses = [ipaddress.ip_address(record[4][0].split("%", 1)[0])
                     for record in records]
    except (OSError, ValueError, IndexError) as exc:
        raise NetMaxError("download host did not resolve to a valid address") from exc
    if not addresses:
        raise NetMaxError("download host did not resolve")
    test_loopback = (allow_http_loopback and parsed.scheme.lower() == "http"
                     and local_literal and all(a.is_loopback for a in addresses))
    if parsed.scheme.lower() != "https" and not test_loopback:
        raise NetMaxError("downloads require HTTPS")
    if any(not address.is_global or address.is_multicast or address.is_reserved
           or address.is_unspecified for address in addresses) and not test_loopback:
        raise NetMaxError("download host resolves to a non-public address")
    if local_name and not all(address.is_loopback for address in addresses):
        raise NetMaxError("localhost resolved outside loopback")
    return parsed, str(addresses[0])


class _PinnedHTTPConnection(http.client.HTTPConnection):
    def __init__(self, host, address, **kwargs):
        self._address = address
        super().__init__(host, **kwargs)

    def connect(self):
        self.sock = socket.create_connection(
            (self._address, self.port), self.timeout, self.source_address)


class _PinnedHTTPSConnection(http.client.HTTPSConnection):
    def __init__(self, host, address, server_hostname, **kwargs):
        self._address = address
        self._server_hostname = server_hostname
        super().__init__(host, **kwargs)

    def connect(self):
        raw = socket.create_connection(
            (self._address, self.port), self.timeout, self.source_address)
        self.sock = self._context.wrap_socket(
            raw, server_hostname=self._server_hostname)


class _PinnedHTTPHandler(HTTPHandler):
    def http_open(self, req):
        _parsed, address = _resolve_download_target(
            req.full_url, allow_http_loopback=_ALLOW_HTTP_LOOPBACK_TESTS)

        def factory(host, timeout=socket._GLOBAL_DEFAULT_TIMEOUT):
            return _PinnedHTTPConnection(host, address, timeout=timeout)

        return self.do_open(factory, req)


class _PinnedHTTPSHandler(HTTPSHandler):
    def https_open(self, req):
        parsed, address = _resolve_download_target(req.full_url)
        context = ssl.create_default_context()

        def factory(host, timeout=socket._GLOBAL_DEFAULT_TIMEOUT):
            return _PinnedHTTPSConnection(
                host, address, parsed.hostname, timeout=timeout, context=context)

        return self.do_open(factory, req)


class _PolicyRedirectHandler(HTTPRedirectHandler):
    max_repeats = MAX_REDIRECTS
    max_redirections = MAX_REDIRECTS

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        target = urljoin(req.full_url, newurl)
        _resolve_download_target(
            target, allow_http_loopback=_ALLOW_HTTP_LOOPBACK_TESTS)
        return super().redirect_request(req, fp, code, msg, headers, target)


def urlopen(request, timeout=30):
    """Open only validated URLs, pin DNS results, and revalidate redirects."""
    opener = build_opener(
        ProxyHandler({}), _PinnedHTTPHandler(), _PinnedHTTPSHandler(),
        _PolicyRedirectHandler())
    try:
        return opener.open(request, timeout=timeout)
    except HTTPError as exc:
        raise NetMaxError(f"HTTP request to {request.full_url} failed: {exc}") from exc


def validate_mcp_output_name(name: str) -> str:
    """Accept one safe MCP basename, never a caller-selected path."""
    if not isinstance(name, str) or not name or name in {".", ".."}:
        raise NetMaxError("MCP output name must be a non-empty basename")
    try:
        size = len(name.encode("utf-8", "strict"))
    except UnicodeError as exc:
        raise NetMaxError("MCP output name is not valid UTF-8") from exc
    if size > 180 or "/" in name or "\\" in name or any(
            ord(ch) < 32 or ord(ch) == 127 for ch in name):
        raise NetMaxError("MCP output name must be a basename of at most 180 UTF-8 bytes")
    return name


def _mcp_output_root() -> tuple[Path, int]:
    home = Path.home()
    downloads = home / "Downloads"
    try:
        home_stat = home.lstat()
        if not stat.S_ISDIR(home_stat.st_mode) or home_stat.st_uid != os.getuid():
            raise NetMaxError("home directory is not a user-owned directory")
        try:
            downloads.mkdir(mode=0o700)
        except FileExistsError:
            pass
        downloads_stat = downloads.lstat()
        if (not stat.S_ISDIR(downloads_stat.st_mode)
                or stat.S_ISLNK(downloads_stat.st_mode)
                or downloads_stat.st_uid != os.getuid()
                or stat.S_IMODE(downloads_stat.st_mode) & 0o022):
            raise NetMaxError(
                "Downloads must be user-owned, non-symlink, and not group/world-writable")
        downloads_fd = os.open(
            downloads, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError as exc:
        raise NetMaxError(f"cannot safely open MCP download parent: {exc}") from exc
    try:
        try:
            os.mkdir("NetMax", 0o700, dir_fd=downloads_fd)
        except FileExistsError:
            pass
        root_fd = os.open(
            "NetMax", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=downloads_fd)
    except OSError as exc:
        raise NetMaxError(f"cannot safely create MCP download directory: {exc}") from exc
    finally:
        os.close(downloads_fd)
    root_stat = os.fstat(root_fd)
    if (root_stat.st_uid != os.getuid()
            or stat.S_IMODE(root_stat.st_mode) != 0o700):
        os.close(root_fd)
        raise NetMaxError("~/Downloads/NetMax must be owned by this user with mode 0700")
    return downloads / "NetMax", root_fd


def download_mcp(url: str, output_name: str, streams: int = 8,
                 on_progress=None) -> tuple[Path, dict]:
    """Download privately, then atomically publish without replacing a file."""
    name = validate_mcp_output_name(output_name)
    root, root_fd = _mcp_output_root()
    try:
        try:
            os.stat(name, dir_fd=root_fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise NetMaxError(f"MCP download already exists: {name}")
        temp_dir = Path(tempfile.mkdtemp(prefix=".netmax-", dir=root))
        try:
            temp_file = temp_dir / "payload"
            result = download(url, temp_file, streams=streams,
                              on_progress=on_progress)
            os.link(temp_file, name, dst_dir_fd=root_fd,
                    follow_symlinks=False)
            return root / name, result
        except FileExistsError as exc:
            raise NetMaxError(f"MCP download already exists: {name}") from exc
        finally:
            shutil.rmtree(temp_dir)
    finally:
        os.close(root_fd)


def _part_path(out_path: Path, index: int) -> Path:
    return out_path.with_name(out_path.name + CHUNK_SUFFIX.format(index))


def _meta_path(out_path: Path) -> Path:
    return out_path.with_name(out_path.name + META_SUFFIX)


def _open(url: str, headers: dict[str, str] | None = None, *, method: str = "GET"):
    req = Request(url, headers=headers or {}, method=method)
    try:
        return urlopen(req, timeout=30)
    except URLError as exc:
        raise NetMaxError(f"http request to {url} failed: {exc}") from exc


def _head(url: str) -> tuple[int | None, bool]:
    """HEAD the URL -> (content_length_or_None, server_supports_ranges)."""
    resp = _open(url, method="HEAD")
    try:
        headers = resp.headers
        status = getattr(resp, "status", None) or resp.getcode()
        if status is not None and int(status) >= 400:
            raise NetMaxError(f"HEAD {url} returned HTTP {status}")
        raw_len = headers.get("Content-Length")
        length = int(raw_len) if raw_len not in (None, "") else None
        if length is not None and not 0 <= length <= MAX_DOWNLOAD_BYTES:
            raise NetMaxError("download exceeds the 1 GiB response limit")
        ranges = (headers.get("Accept-Ranges") or "").lower()
        return length, "bytes" in ranges
    finally:
        resp.close()


def split_chunks(size: int, streams: int) -> list[tuple[int, int]]:
    """Split [0, size) into `streams` contiguous (start, end_inclusive) chunks.

    `streams` is clamped to `size` so a tiny file never produces zero-span
    chunks (end < start) that would break assembly.
    """
    if size <= 0:
        return []
    streams = max(1, min(streams, size))
    base, rem = divmod(size, streams)
    chunks: list[tuple[int, int]] = []
    start = 0
    for i in range(streams):
        span = base + (1 if i < rem else 0)
        chunks.append((start, start + span - 1))
        start += span
    return chunks


class _Counter:
    """Lock-protected byte counter driving the progress callback."""

    def __init__(self, total: int | None, on_progress):
        self._lock = threading.Lock()
        self.done = 0
        # F2: bytes fetched from the network THIS run — resume credits on disk
        # count toward done (progress) but must not inflate the returned mbps.
        self.net = 0
        self.total = total
        self.on_progress = on_progress
        self._last_reported = 0

    def add(self, n: int, *, net: bool = True) -> None:
        fire = False
        with self._lock:
            self.done += n
            if net:
                self.net += n
            if self.on_progress is not None and (
                self.done - self._last_reported >= PROGRESS_EVERY
            ):
                fire = True
                self._last_reported = self.done
        if fire:
            self.on_progress(self.done, self.total)

    def flush(self) -> None:
        if self.on_progress is not None:
            with self._lock:
                self._last_reported = self.done
            self.on_progress(self.done, self.total)


def _fetch_chunk(
    url: str, index: int, start: int, end: int, part: Path,
    counter: _Counter,
) -> None:
    """Fetch one byte-range into its part file, resuming a partial part."""
    want_total = end - start + 1
    have = 0
    # Safety first: never trust a part's size before proving it is a regular
    # file — a pre-placed symlink whose target is >= want_total used to skip
    # every check below and poison assembly with foreign bytes.
    if part.exists() or part.is_symlink():
        if part.is_symlink() or not part.is_file():
            raise NetMaxError(
                f"refusing unsafe existing path {part} (symlink or non-file)"
            )
        have = part.stat().st_size
        if have > want_total:
            # Corrupt leftover (e.g. a server ignored Range once and the full
            # body landed here): its prefix is NOT this chunk — discard it.
            part.unlink()
            have = 0
        elif have == want_total:
            counter.add(want_total, net=False)  # complete from an earlier run
            return
        if have:
            # partial resume: progress credit only — not network bytes (F2)
            counter.add(have, net=False)
    headers = {"Range": f"bytes={start + have}-{end}"}
    resp = _open(url, headers)
    try:
        status = getattr(resp, "status", None) or resp.getcode()
        if status is not None and int(status) >= 400:
            raise NetMaxError(f"range request {headers['Range']} got HTTP {status}")
        # Symlink-safe write: O_EXCL create (fails on pre-placed symlinks),
        # 0600 perms, private part data (path already vetted above).
        if part.exists() or part.is_symlink():
            fd = os.open(part, os.O_WRONLY | os.O_APPEND)  # legit resume
        else:
            fd = _open_excl(part)
        with os.fdopen(fd, "wb") as fh:
            received = have
            while True:
                block = _read_block(resp, min(65536, want_total - received + 1))
                if not block:
                    break
                if received + len(block) > want_total:
                    raise NetMaxError(f"chunk {index}: response exceeds requested range")
                fh.write(block)
                received += len(block)
                counter.add(len(block))
    finally:
        resp.close()
    if part.stat().st_size != want_total:
        raise NetMaxError(
            f"chunk {index}: got {part.stat().st_size}B, expected {want_total}B"
        )


def _assemble(out_path: Path, chunks: list[tuple[int, int]]) -> int:
    total = 0
    # F10 completeness: assemble with O_EXCL + 0600 so the final file can
    # neither be a pre-placed symlink target nor world-readable.
    if out_path.exists() or out_path.is_symlink():
        if out_path.is_symlink() or not out_path.is_file():
            raise NetMaxError(
                f"refusing unsafe output path {out_path} (symlink or non-file)"
            )
        out_path.unlink()  # legitimate re-download of the same target
    fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as out:
        for i in range(len(chunks)):
            part = _part_path(out_path, i)
            with open(part, "rb") as fh:
                while True:
                    block = fh.read(1 << 20)
                    if not block:
                        break
                    out.write(block)
                    total += len(block)
    return total


def _cleanup(out_path: Path, n_chunks: int) -> None:
    for i in range(n_chunks):
        p = _part_path(out_path, i)
        try:
            os.remove(p)
        except FileNotFoundError:
            pass
    try:
        os.remove(_meta_path(out_path))
    except FileNotFoundError:
        pass


def download(
    url: str,
    out_path: str | os.PathLike,
    streams: int = 8,
    on_progress=None,
) -> dict:
    """Download `url` to `out_path`, multi-stream when the server allows it.

    Returns {bytes, mbps, streams_used, elapsed_s}. Resumable: a previous run's
    meta file plus part files cause only missing/incomplete chunks to refetch.
    Raises netmax.NetMaxError on any HTTP failure.
    """
    if streams < 1:
        raise NetMaxError("streams must be >= 1")
    out_path = Path(out_path)
    _assert_safe_out_dir(out_path)
    started = time.monotonic()

    length, ranged = _head(url)

    # Resume path: valid meta + matching url means prior parts are reusable.
    chunks: list[tuple[int, int]] | None = None
    if length is not None and ranged:
        meta_file = _meta_path(out_path)
        if meta_file.exists():
            try:
                meta = json.loads(meta_file.read_text())
                ok = (
                    meta.get("url") == url
                    and meta.get("size") == length
                    and isinstance(meta.get("chunks"), list)
                )
                if ok:
                    # Validate each chunk is a 2-int [start, end] pair —
                    # hand-edited / corrupt meta must not raise TypeError
                    # or unpack garbage into the multi-stream path.
                    parsed: list[tuple[int, int]] = []
                    for c in meta["chunks"]:
                        if not (isinstance(c, (list, tuple)) and len(c) == 2
                                and all(isinstance(v, int) for v in c)
                                and 0 <= c[0] <= c[1] < length):
                            parsed = []
                            break
                        parsed.append((c[0], c[1]))
                    if len(parsed) == len(meta["chunks"]) and parsed:
                        chunks = parsed
            except (ValueError, KeyError, OSError, TypeError):
                pass
        if chunks is None:
            chunks = split_chunks(length, streams)
            # Meta write: create-or-replace. O_EXCL alone breaks legit
            # resumes (meta already exists with matching url+size); an
            # unconditional truncate would let a foreign pre-placed file
            # win. Validate-then-replace keeps both properties.
            if meta_file.exists() or meta_file.is_symlink():
                if meta_file.is_symlink() or not meta_file.is_file():
                    raise NetMaxError(
                        f"refusing unsafe meta path {meta_file} (symlink or non-file)"
                    )
                try:
                    old_meta = json.loads(meta_file.read_text(encoding="utf-8"))
                except ValueError:
                    old_meta = {}
                if not (isinstance(old_meta, dict)
                        and old_meta.get("url") == url
                        and old_meta.get("size") == length):
                    meta_file.unlink()  # stale meta for a different download
            meta_fd = _open_excl(meta_file)
            with os.fdopen(meta_fd, "w", encoding="utf-8") as mfh:
                json.dump({
                    "url": url, "size": length,
                    "chunks": [[s, e] for s, e in chunks],
                }, mfh)

    # A single chunk means the single-stream path writes out_path directly —
    # part-file assembly never applies (no part files exist for it).
    if chunks is not None and len(chunks) < 2:
        chunks = None
        try:
            os.remove(_meta_path(out_path))
        except FileNotFoundError:
            pass

    if chunks is not None and len(chunks) > 1:
        counter = _Counter(length, on_progress)
        workers = min(streams, len(chunks))
        with ThreadPoolExecutor(max_workers=workers) as pool:
            futures = [
                pool.submit(_fetch_chunk, url, i, s, e,
                            _part_path(out_path, i), counter)
                for i, (s, e) in enumerate(chunks)
            ]
            errors = []
            for f in futures:
                try:
                    f.result()
                except NetMaxError as exc:
                    errors.append(str(exc))
        if errors:
            raise NetMaxError("; ".join(errors))
        streams_used = workers
    else:
        # Single-stream fallback (server lacks ranges or unknown length).
        counter = _Counter(length, on_progress)
        resp = _open(url)
        try:
            status = getattr(resp, "status", None) or resp.getcode()
            if status is not None and int(status) >= 400:
                raise NetMaxError(f"GET {url} returned HTTP {status}")
            # F10 completeness (single-stream path): same O_EXCL + 0600
            # policy as _assemble — never follow a pre-placed symlink,
            # never leave the download world-readable.
            if out_path.exists() or out_path.is_symlink():
                if out_path.is_symlink() or not out_path.is_file():
                    raise NetMaxError(
                        f"refusing unsafe output path {out_path} (symlink or non-file)"
                    )
                out_path.unlink()
            out_fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(out_fd, "wb") as fh:
                received = 0
                while True:
                    limit = min(length, MAX_DOWNLOAD_BYTES) if length is not None else MAX_DOWNLOAD_BYTES
                    block = _read_block(resp, min(65536, limit - received + 1))
                    if not block:
                        break
                    if received + len(block) > limit:
                        raise NetMaxError("download exceeds the 1 GiB response limit")
                    fh.write(block)
                    received += len(block)
                    counter.add(len(block))
        finally:
            resp.close()
        streams_used = 1

    if chunks:
        total_bytes = _assemble(out_path, chunks)
        counter.flush()
        _cleanup(out_path, len(chunks))
    else:
        total_bytes = out_path.stat().st_size
        counter.flush()

    # Completeness: an empty/short body (server closed early) or a poisoned
    # assembly must fail loudly, never return a truncated file as success.
    if length is not None and total_bytes != length:
        raise NetMaxError(
            f"download incomplete: got {total_bytes} of {length} bytes"
        )

    elapsed = max(time.monotonic() - started, 1e-9)
    return {
        "bytes": total_bytes,
        # F2: mbps = network bytes this run only — a resumed download must not
        # divide the full file size by this run's short elapsed time.
        "mbps": counter.net * 8 / elapsed / 1e6,
        "streams_used": streams_used,
        "elapsed_s": elapsed,
    }
