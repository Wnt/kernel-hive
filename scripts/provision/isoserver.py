#!/usr/bin/env python3
"""Serve installer artifacts over HTTP/1.1 with single-range support.

Supermicro Redfish virtual media requires ``Accept-Ranges: bytes`` on HEAD and
uses byte-range GETs while streaming an ISO.  Proxmox's HTTP answer fetch sends
a POST, so POST to a regular file is intentionally treated like GET after the
request body has been drained.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import BinaryIO

RANGE_RE = re.compile(r"^bytes=(\d*)-(\d*)$")


class RangeRequestHandler(SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def __init__(self, *args: object, directory: str, **kwargs: object) -> None:
        self._range: tuple[int, int] | None = None
        super().__init__(*args, directory=directory, **kwargs)

    def end_headers(self) -> None:
        # The BMC checks this on HEAD before it attempts any range GETs.
        self.send_header("Accept-Ranges", "bytes")
        super().end_headers()

    def do_POST(self) -> None:
        """Return a static file for Proxmox answer-file POST requests."""
        try:
            content_length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_error(HTTPStatus.BAD_REQUEST, "invalid Content-Length")
            return
        if content_length < 0:
            self.send_error(HTTPStatus.BAD_REQUEST, "invalid Content-Length")
            return
        if content_length:
            self.rfile.read(content_length)
        self.do_GET()

    def send_head(self) -> BinaryIO | None:
        self._range = None
        range_header = self.headers.get("Range")
        path = self.translate_path(self.path)

        # Let SimpleHTTPRequestHandler retain redirects, directory listings,
        # conditional requests, and normal full-file responses.
        if not range_header or os.path.isdir(path):
            return super().send_head()

        try:
            # Deliberately not a `with`: the handler returns this open file
            # object so http.server can stream + close it after send_head().
            source = open(path, "rb")  # noqa: SIM115
        except OSError:
            self.send_error(HTTPStatus.NOT_FOUND, "file not found")
            return None

        try:
            size = os.fstat(source.fileno()).st_size
            parsed = self._parse_range(range_header, size)
            if parsed is None:
                source.close()
                self.send_response(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return None

            start, end = parsed
            self._range = parsed
            source.seek(start)
            self.send_response(HTTPStatus.PARTIAL_CONTENT)
            self.send_header("Content-Type", self.guess_type(path))
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.send_header("Content-Length", str(end - start + 1))
            self.send_header("Last-Modified", self.date_time_string(os.fstat(source.fileno()).st_mtime))
            self.end_headers()
            return source
        except Exception:
            source.close()
            raise

    @staticmethod
    def _parse_range(value: str, size: int) -> tuple[int, int] | None:
        match = RANGE_RE.fullmatch(value.strip())
        if not match or size == 0:
            return None

        first, last = match.groups()
        if not first and not last:
            return None

        if not first:
            suffix_length = int(last)
            if suffix_length <= 0:
                return None
            start = max(0, size - suffix_length)
            return start, size - 1

        start = int(first)
        if start >= size:
            return None
        end = int(last) if last else size - 1
        if end < start:
            return None
        return start, min(end, size - 1)

    def copyfile(self, source: BinaryIO, outputfile: BinaryIO) -> None:
        if self._range is None:
            shutil.copyfileobj(source, outputfile)
            return

        start, end = self._range
        remaining = end - start + 1
        while remaining:
            chunk = source.read(min(64 * 1024, remaining))
            if not chunk:
                break
            outputfile.write(chunk)
            remaining -= len(chunk)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="serve a directory for Redfish virtual media and iPXE")
    parser.add_argument("directory", type=Path, help="directory to serve")
    parser.add_argument("--bind", default="0.0.0.0", help="listen address (default: 0.0.0.0)")
    parser.add_argument("--port", type=int, default=58080, help="listen port (default: 58080)")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    directory = args.directory.expanduser().resolve(strict=True)
    if not directory.is_dir():
        raise SystemExit(f"not a directory: {directory}")

    def handler(*handler_args: object, **handler_kwargs: object) -> RangeRequestHandler:
        return RangeRequestHandler(*handler_args, directory=str(directory), **handler_kwargs)

    server = ThreadingHTTPServer((args.bind, args.port), handler)
    print(f"serving {directory} on http://{args.bind}:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
