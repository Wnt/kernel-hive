"""The serving plane's log producer: stderr, timestamped, plus the log store.

TWO TRAPS THIS FILE EXISTS TO CLOSE.

1. `osgallery-https.service` sends stdout AND stderr to
   `append:/data/vms/streamhost/serve/https-server.log`. Not journald: no
   timestamps, no per-boot delimiter, no rotation. A 24 MB file of undated
   lines has already cost a debugging cycle, because output written before a
   fix reads exactly like output written after it. Every line this module
   writes carries an ISO-8601 UTC timestamp, and `boot_banner()` writes one
   unmistakable delimiter per process start, so "what did it say since the
   restart?" is answerable with `tac | grep -m1 BOOT`.

2. Nothing the plane printed was queryable, and none of it was joinable to a
   trace. `write()` stamps the current span's `trace_id`/`span_id` onto the
   stored record automatically — `tracing.current()` is the thread-local
   innermost span, and the HTTP instrumentation has already opened one for the
   request in flight — so a slow span and the lines emitted during it are one
   query apart in both our store and Instana.

THE FILE IS THE FALLBACK, NOT THE FORMER PATH. Every line still goes to stderr
even when the store accepts it. A store that is full, locked or absent must not
be able to lose a log line; it is allowed only to make one unqueryable. That
also means this change cannot regress the existing debugging workflow while the
new path is being proven.

WHAT IS DELIBERATELY *NOT* STORED: the per-request access line
(`BaseHTTPRequestHandler.log_message`). It is ~184 000 lines a day and every
one of them is already a span in the trace store, with more detail — status,
duration, route, trace id. Storing it would triple the log store's size to
duplicate the pillar next door. It gets the timestamp fix and stays in the
file. `LOG_ACCESS=1` folds it in at DEBUG for anyone who wants it anyway.
"""

from __future__ import annotations

import atexit
import contextlib
import os
import sys
import threading
import time

import tracing

SERVICE_NAME = "kernel-hive-serve"

#: Records buffered before a write, and the age at which a partial buffer goes
#: anyway. Same shape and the same reason as `tracing`'s span buffer: one
#: sqlite transaction per log line would put a commit on the request path.
MAX_BUFFERED = 256
FLUSH_SECS = 2.0

_store = None
_instance = "unknown"
_buf: list = []
_lock = threading.Lock()
_last_flush = 0.0
_dropped = 0


def bind(store, instance: str) -> None:
    """Point the sink at a `logs.LogStore`. Until this is called (and after a
    `close()`), `write()` still writes the file — the plane logs from its very
    first line, before any store exists."""
    global _store, _instance, _last_flush
    _store = store
    _instance = instance or "unknown"
    _last_flush = time.time()
    atexit.register(flush)


def is_bound() -> bool:
    return _store is not None


def _ts(now: float) -> str:
    """ISO-8601 UTC to the millisecond. Not `time.ctime()`: this file is read
    next to trace timestamps that are UTC epoch milliseconds, and a local-time
    log line is one DST boundary away from lying about the order of events."""
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(now)) + f".{int(now * 1000) % 1000:03d}Z"


def boot_banner(detail: str = "") -> None:
    """The per-boot delimiter the append-mode log file has never had.

    Written as one greppable token, `=== BOOT`, with the pid: `Restart=on-failure`
    means several starts can share the file, and a crash loop is only visible
    as a crash loop if you can count the starts.
    """
    write(f"=== BOOT pid={os.getpid()} {detail}".rstrip(), severity="INFO", attrs={"kh.event": "boot"})


def write(msg: str, severity: str = "INFO", attrs: dict | None = None, ts_ms: int | None = None) -> None:
    """One log line: to the file always, to the store when one is bound.

    Never raises. A logging call that can take the serving plane down is worse
    than no logging call, and this one runs on the request path.
    """
    now = time.time()
    with contextlib.suppress(OSError, ValueError):
        sys.stderr.write(f"{_ts(now)} [serve] {msg}\n")
    if _store is None:
        return
    rec = {
        "t": ts_ms if ts_ms is not None else int(now * 1000),
        "sv": severity,
        "b": msg,
    }
    # `tracing.current()` is NOOP when there is no span on this thread, and
    # NOOP's ids are the empty string — so this test is "is there a real span",
    # and a record with no span in scope is stored honestly uncorrelated rather
    # than carrying an id that joins to nothing.
    span = tracing.current()
    if getattr(span, "trace_id", ""):
        rec["tr"] = span.trace_id
        rec["sp"] = span.span_id
    if attrs:
        rec["a"] = attrs
    _enqueue(rec, now)


def exception(msg: str, err: BaseException, attrs: dict | None = None) -> None:
    """An ERROR record carrying the stack, under the attribute names Instana
    documents support for (`exception.type`, `exception.message`,
    `exception.stacktrace` — 0307:337). The trace store refuses stacks by
    policy; the log store is where they were always supposed to live, and it
    is why `clientlog.jsonl` had to exist."""
    import traceback

    a = dict(attrs or {})
    a["exception.type"] = type(err).__name__
    a["exception.message"] = str(err)[:512]
    a["exception.stacktrace"] = "".join(traceback.format_exception(type(err), err, err.__traceback__))[-4096:]
    write(f"{msg}: {type(err).__name__}: {err}", severity="ERROR", attrs=a)


def _enqueue(rec: dict, now: float) -> None:
    global _last_flush, _dropped
    due = False
    with _lock:
        if len(_buf) >= MAX_BUFFERED * 4:
            # The store is not draining. Drop, count, and keep serving: the
            # line is already in the file, so this costs queryability, not the
            # record. Counting it is what makes the loss visible instead of a
            # gap somebody notices a week later.
            _dropped += 1
            return
        _buf.append(rec)
        if len(_buf) >= MAX_BUFFERED or (now - _last_flush) >= FLUSH_SECS:
            due = True
    if due:
        flush()


def flush() -> int:
    """Write the buffer. Returns how many records went in."""
    global _last_flush, _dropped
    with _lock:
        batch, _buf[:] = list(_buf), []
        _last_flush = time.time()
        dropped, _dropped = _dropped, 0
    if not batch or _store is None:
        return 0
    if dropped:
        batch.append(
            {
                "t": int(time.time() * 1000),
                "sv": "WARN",
                "b": f"log sink dropped {dropped} record(s): store not draining",
                "a": {"kh.dropped": dropped},
            }
        )
    try:
        return _store.record(
            {
                "resource": {
                    "service.name": SERVICE_NAME,
                    "service.instance.id": _instance,
                    "session.id": "unknown",
                },
                "logs": batch,
            }
        )
    except Exception as e:  # noqa: BLE001 - a failing sink must never propagate
        sys.stderr.write(f"{_ts(time.time())} [serve] log sink write failed: {e}\n")
        return 0


def stats() -> dict:
    with _lock:
        return {"buffered": len(_buf), "dropped": _dropped, "bound": _store is not None}


def access(client: str, line: str) -> None:
    """The per-request access line. File always; store only under LOG_ACCESS=1
    — see the module docstring for why it is not stored by default."""
    if os.environ.get("LOG_ACCESS") == "1":
        write(f"{client} - {line}", severity="DEBUG", attrs={"kh.event": "access", "client.address": client})
        return
    with contextlib.suppress(OSError, ValueError):
        sys.stderr.write(f"{_ts(time.time())} [serve] {client} - {line}\n")


def install_logging(level: str = "INFO") -> None:
    """Route the stdlib root logger into this sink, so a logger anywhere in the
    plane (or in a dependency) lands in the same store, with the same trace
    context, as the plane's own lines.

    Opt-in and idempotent. `logging` is imported here and nowhere else in
    `scripts/serve` — the sink must not depend on a module the plane does not
    otherwise use, and a caller that never asks never pays for it.
    """
    import logging
    import traceback

    class _KhHandler(logging.Handler):
        def emit(self, record):
            try:
                attrs = {"logger.name": record.name}
                if record.exc_info:
                    attrs["exception.stacktrace"] = "".join(traceback.format_exception(*record.exc_info))[-4096:]
                write(
                    record.getMessage()[:8192],
                    severity=record.levelname,
                    attrs=attrs,
                    ts_ms=int(record.created * 1000),
                )
            except Exception:  # noqa: BLE001 - a logging handler must never raise
                pass

    root = logging.getLogger()
    if any(getattr(h, "_kh_sink", False) for h in root.handlers):
        return
    handler = _KhHandler()
    handler._kh_sink = True
    root.addHandler(handler)
    root.setLevel(getattr(logging, level.upper(), logging.INFO))


def reset_for_tests() -> None:
    global _store, _dropped
    with _lock:
        _buf[:] = []
        _dropped = 0
    _store = None
