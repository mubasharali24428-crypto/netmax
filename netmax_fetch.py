#!/usr/bin/env python3
"""netmax_fetch — chunked multi-stream download accelerator (Mission 3 F1).

Splits a ranged HTTP resource into N byte-range chunks fetched in parallel,
resumable via <out>.netmax-part-N files plus a <out>.netmax-meta.json manifest.
Falls back to a single stream when the server ignores Accept-Ranges.
"""

from __future__ import annotations

import json
import os
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from urllib.error import URLError
from urllib.request import Request, urlopen

try:
    from netmax import NetMaxError
except ImportError:  # allow running as a bare script
    class NetMaxError(RuntimeError):
        """A download could not be completed."""


CHUNK_SUFFIX = ".netmax-part-{}"
META_SUFFIX = ".netmax-meta.json"
PROGRESS_EVERY = 65536  # bytes between on_progress callbacks per worker


def _part_path(out_path: Path, index: int) -> Path:
    return out_path.with_name(out_path.name + CHUNK_SUFFIX.format(index))


def _meta_path(out_path: Path) -> Path:
    return out_path.with_name(out_path.name + META_SUFFIX)


def _open(url: str, headers: dict[str, str] | None = None):
    req = Request(url, headers=headers or {})
    try:
        return urlopen(req, timeout=30)
    except URLError as exc:
        raise NetMaxError(f"http request to {url} failed: {exc}") from exc


def _head(url: str) -> tuple[int | None, bool]:
    """HEAD the URL -> (content_length_or_None, server_supports_ranges)."""
    resp = _open(url)
    try:
        headers = resp.headers
        status = getattr(resp, "status", None) or resp.getcode()
        if status is not None and int(status) >= 400:
            raise NetMaxError(f"HEAD {url} returned HTTP {status}")
        raw_len = headers.get("Content-Length")
        length = int(raw_len) if raw_len not in (None, "") else None
        ranges = (headers.get("Accept-Ranges") or "").lower()
        return length, "bytes" in ranges
    finally:
        resp.close()


def split_chunks(size: int, streams: int) -> list[tuple[int, int]]:
    """Split [0, size) into `streams` contiguous (start, end_inclusive) chunks."""
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
        self.total = total
        self.on_progress = on_progress
        self._last_reported = 0

    def add(self, n: int) -> None:
        fire = False
        with self._lock:
            self.done += n
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
    have = part.stat().st_size if part.exists() else 0
    want_total = end - start + 1
    if have >= want_total:
        counter.add(0)  # already complete from an earlier run
        return
    headers = {"Range": f"bytes={start + have}-{end}"}
    resp = _open(url, headers)
    try:
        status = getattr(resp, "status", None) or resp.getcode()
        if status is not None and int(status) >= 400:
            raise NetMaxError(f"range request {headers['Range']} got HTTP {status}")
        with open(part, "ab") as fh:
            while True:
                block = resp.read(65536)
                if not block:
                    break
                fh.write(block)
                counter.add(len(block))
    finally:
        resp.close()
    if part.stat().st_size != want_total:
        raise NetMaxError(
            f"chunk {index}: got {part.stat().st_size}B, expected {want_total}B"
        )


def _assemble(out_path: Path, chunks: list[tuple[int, int]]) -> int:
    total = 0
    with open(out_path, "wb") as out:
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
    started = time.monotonic()

    length, ranged = _head(url)

    # Resume path: valid meta + matching url means prior parts are reusable.
    resumed = False
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
                    chunks = [tuple(c) for c in meta["chunks"]]
                    resumed = True
            except (ValueError, KeyError, OSError):
                pass
        if chunks is None:
            chunks = split_chunks(length, streams)
            meta_file.write_text(json.dumps({
                "url": url, "size": length,
                "chunks": [[s, e] for s, e in chunks],
            }))

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
            mode = "ab" if resumed and out_path.exists() else "wb"
            with open(out_path, mode) as fh:
                while True:
                    block = resp.read(65536)
                    if not block:
                        break
                    fh.write(block)
                    counter.add(len(block))
        finally:
            resp.close()
        streams_used = 1

    total_bytes = _assemble(out_path, chunks) if chunks else out_path.stat().st_size
    counter.flush()
    _cleanup(out_path, len(chunks)) if chunks else None

    elapsed = max(time.monotonic() - started, 1e-9)
    return {
        "bytes": total_bytes,
        "mbps": total_bytes * 8 / elapsed / 1e6,
        "streams_used": streams_used,
        "elapsed_s": elapsed,
    }
