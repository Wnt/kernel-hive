#!/usr/bin/env python3
"""mctl.py — production mamectl/1 line client for the MAME ctlsock module.

Box copy: /root/mctl.py — `labctl mctl <tile> ...` and labctl's socket-routed
type/sh/reset shell out to it (sync pair in scripts/dev/verify-box-sync.sh).
Supersedes scripts/build-guests/irix/irix-ctl/mctl-probe.py for ops use; the probe
stays in place because the Stage-1 rigs import MctlClient from it, and this
file is self-contained (stdlib only) because the two are NOT deployed side by
side on the box.

Protocol (mamectl/1, issue #45 design section 3), socket `MAME_CTL_SOCK`
(convention `<tile-dir>/ctl.sock`, published to labctl as the matrix `ctl`
field from `SH_MAMECTL_SOCK` in tile.env):

    on accept: HELLO mamectl/1 <build-id> <machine> caps=<flag,...> screen=<WxH>
    request  := seq SP verb [SP args] LF        ; seq = uint, or "-" = no reply
    reply    := seq SP OK [SP data] LF
              | seq SP ERR SP code SP text LF   ; badline|badverb|badarg|
                                                ; noport|unsupported|busy
    mldata   := (seq SP D SP text LF)* seq SP OK SP count LF
    event    := EV SP name [SP args] LF         ; async, all connections

Timeout facts a caller must know (Stage-0 verdict, binding):
  * While the machine is PAUSED only the frame-notifier drain runs, so verb
    pickup is ~40-50 ms, not the running-machine ~1 ms. A paused machine is
    slow to ack — never conclude "dead" from a 50 ms silence while paused.
  * SAVEST/LOADST ack on COMPLETION of a measured ~12 s stop-the-world
    immediate_save/load; call them with --timeout >= 60. SAVEST while RUNNING
    may ERR busy (pending anonymous timers) — PAUSE first.
  * MOVEA acks on ACCEPT and completes via `EV MOVEA` (use --wait-ev MOVEA);
    a KEY burst acks at KEY_HOLD+KEY_GAP pace, ~150 ms per key.
  * STAT carries `sig=`/`entries=` (computed_signature over the registered
    save entries) — the permanent savestate-signature regression probe.

CLI (options BEFORE the verb: the first non-option token is SOCK, the second
begins the verb line, and from there EVERYTHING is verb payload — so verb args
like `MOVE -40 -40` are never mistaken for options; the split is done by hand
because argparse.REMAINDER swallows options placed after a positional):
    mctl.py SOCK --hello
    mctl.py SOCK [--timeout S] [--wait-ev NAME] VERB [ARG...]
    mctl.py SOCK --stdin [--timeout S]

Exit discipline (house): 0 = OK ack; 1 = ERR ack; 2 = ERR badverb/unsupported;
125 = channel down (connect failure, timeout, EOF).
"""

import argparse
import collections
import contextlib
import socket
import sys
import time

UNSUPPORTED_CODES = frozenset({"badverb", "unsupported"})

Reply = collections.namedtuple("Reply", "seq ok code text data")


class MctlError(Exception):
    """Channel-level failure (connect refused, timeout, EOF): exit-125 territory."""


class MctlClient:
    """One mamectl/1 connection: seq bookkeeping, ack routing, EV capture.

    Blocking calls: `request()` / `wait()`. Latency rigs that must not block
    use `send_async()` + `pump(0.0)` + `poll_reply()` so framebuffer polling
    and ack collection interleave on one thread.
    """

    def __init__(self, path, timeout=10.0):
        self.timeout = timeout
        self.events = []  # raw "EV ..." lines, in arrival order
        self.other = []  # unparseable lines, kept for diagnostics
        self._buf = b""
        self._data = {}  # seq -> ["D" payloads so far]
        self._done = {}  # seq -> Reply
        self._seq = 0
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            self.sock.settimeout(timeout)
            self.sock.connect(path)
        except OSError as e:
            raise MctlError(f"connect {path}: {e}") from e
        self.hello = self._read_hello()

    def close(self):
        with contextlib.suppress(OSError):
            self.sock.close()

    # ---- wire ------------------------------------------------------------

    def _read_hello(self):
        deadline = time.monotonic() + self.timeout
        line = self._next_line(deadline)
        while line.startswith("EV "):  # be liberal: events before the banner
            self.events.append(line)
            line = self._next_line(deadline)
        t = line.split()
        if not t or t[0] != "HELLO":
            raise MctlError(f"bad banner: {line!r}")
        h = {"raw": line, "proto": t[1] if len(t) > 1 else ""}
        for tok in t[2:]:
            if tok.startswith("caps="):
                h["caps"] = [c for c in tok[len("caps=") :].split(",") if c]
            elif tok.startswith("screen="):
                h["screen"] = tok[len("screen=") :]
            elif "build" not in h:
                h["build"] = tok
            elif "machine" not in h:
                h["machine"] = tok
        return h

    def _next_line(self, deadline):
        while b"\n" not in self._buf:
            left = deadline - time.monotonic()
            if left <= 0:
                raise MctlError("timeout waiting for line")
            self.sock.settimeout(left)
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout as e:
                raise MctlError("timeout waiting for line") from e
            except OSError as e:
                raise MctlError(f"recv: {e}") from e
            if not chunk:
                raise MctlError("connection closed by peer")
            self._buf += chunk
        raw, _, self._buf = self._buf.partition(b"\n")
        return raw.decode("utf-8", "replace").rstrip("\r")

    def _classify(self, line):
        if line.startswith("EV "):
            self.events.append(line)
            return
        parts = line.split(" ", 2)
        if len(parts) >= 2 and parts[0].isdigit():
            seq, kind = int(parts[0]), parts[1]
            rest = parts[2] if len(parts) > 2 else ""
            if kind == "D":
                self._data.setdefault(seq, []).append(rest)
                return
            if kind == "OK":
                self._done[seq] = Reply(seq, True, "", rest, self._data.pop(seq, []))
                return
            if kind == "ERR":
                code, _, text = rest.partition(" ")
                self._done[seq] = Reply(seq, False, code, text, self._data.pop(seq, []))
                return
        self.other.append(line)

    def pump(self, timeout=0.0):
        """Drain whatever the socket has within `timeout` seconds (0 = poll)."""
        end = time.monotonic() + timeout
        while True:
            while b"\n" in self._buf:
                raw, _, self._buf = self._buf.partition(b"\n")
                self._classify(raw.decode("utf-8", "replace").rstrip("\r"))
            left = max(0.0, end - time.monotonic())
            self.sock.settimeout(left)  # 0.0 = non-blocking single poll
            try:
                chunk = self.sock.recv(65536)
            except (BlockingIOError, socket.timeout):
                return
            except InterruptedError:
                continue
            except OSError as e:
                raise MctlError(f"recv: {e}") from e
            if not chunk:
                raise MctlError("connection closed by peer")
            self._buf += chunk

    # ---- requests --------------------------------------------------------

    def _send(self, line):
        try:
            self.sock.sendall((line + "\n").encode())
        except OSError as e:
            raise MctlError(f"send: {e}") from e

    def send_async(self, verb_line):
        self._seq += 1
        self._send(f"{self._seq} {verb_line}")
        return self._seq

    def send_noreply(self, verb_line):
        """Fire-and-forget (seq "-"): the hot motion path."""
        self._send(f"- {verb_line}")

    def poll_reply(self, seq):
        """Non-blocking: the Reply if its ack already arrived, else None."""
        return self._done.pop(seq, None)

    def wait(self, seq, timeout=None):
        deadline = time.monotonic() + (self.timeout if timeout is None else timeout)
        while True:
            rep = self._done.pop(seq, None)
            if rep is not None:
                return rep
            left = deadline - time.monotonic()
            if left <= 0:
                raise MctlError(f"timeout waiting for ack of seq {seq}")
            self.pump(min(left, 0.25))

    def request(self, verb_line, timeout=None):
        return self.wait(self.send_async(verb_line), timeout=timeout)

    def wait_event(self, name, timeout=None):
        """Block until an `EV <name> ...` arrives; returns and consumes it."""
        deadline = time.monotonic() + (self.timeout if timeout is None else timeout)
        while True:
            for i, ev in enumerate(self.events):
                t = ev.split()
                if len(t) >= 2 and t[1] == name:
                    return self.events.pop(i)
            left = deadline - time.monotonic()
            if left <= 0:
                raise MctlError(f"timeout waiting for EV {name}")
            self.pump(min(left, 0.25))


def _ack_exit(rep):
    if rep.ok:
        return 0
    return 2 if rep.code in UNSUPPORTED_CODES else 1


OPT_FLAGS = frozenset({"--hello", "--stdin"})
OPT_VALUED = frozenset({"--timeout", "--wait-ev", "--ev-timeout"})


def split_cli(argv):
    """(head, verb): head = SOCK + client options, verb = the verb line tokens.

    argparse.REMAINDER captures option-looking tokens once the positional is
    filled (`SOCK --hello` sends "--hello" as a verb), so the split is manual:
    options are recognized by name until the second non-option token, which
    starts the verb; after that nothing is an option (`MOVE -40 -40` works).
    """
    head, verb = [], []
    seen_sock = False
    i = 0
    while i < len(argv):
        a = argv[i]
        if verb:
            verb.append(a)
        elif a in OPT_FLAGS or (a.partition("=")[0] in OPT_VALUED and "=" in a):
            head.append(a)
        elif a in OPT_VALUED:
            head.extend(argv[i : i + 2])
            i += 1
        elif a in ("-h", "--help") or not seen_sock:
            seen_sock = seen_sock or not a.startswith("-")
            head.append(a)
        else:
            verb.append(a)
        i += 1
    return head, verb


def _print_reply(rep):
    for d in rep.data:
        print(d)
    if rep.ok:
        print(f"OK {rep.text}" if rep.text else "OK")
    else:
        print(f"ERR {rep.code} {rep.text}")


def main():
    ap = argparse.ArgumentParser(description="mamectl/1 line client (see module docstring)")
    ap.add_argument("sock", help="unix socket path (<tile-dir>/ctl.sock)")
    ap.add_argument("--timeout", type=float, default=10.0, help="per-ack timeout, s (SAVEST/LOADST need >= 60)")
    ap.add_argument("--hello", action="store_true", help="print the parsed HELLO banner and exit")
    ap.add_argument("--stdin", action="store_true", help="read verb lines from stdin, ack each")
    ap.add_argument("--wait-ev", metavar="NAME", help="after the ack, wait for this EV (e.g. MOVEA)")
    ap.add_argument("--ev-timeout", type=float, default=30.0, help="EV wait timeout, s")
    head, verb = split_cli(sys.argv[1:])
    args = ap.parse_args(head)
    args.verb = verb

    try:
        cli = MctlClient(args.sock, timeout=args.timeout)
    except MctlError as e:
        print(f"mctl: {e}", file=sys.stderr)
        return 125

    try:
        if args.hello:
            for k in sorted(cli.hello):
                print(f"{k}={cli.hello[k]}")
            return 0
        if args.stdin:
            worst = 0
            for raw in sys.stdin:
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                rep = cli.request(line)
                print(f"{line} -> ", end="")
                _print_reply(rep)
                worst = max(worst, _ack_exit(rep))
            return worst
        if not args.verb:
            ap.error("no verb given (or use --hello / --stdin)")
        rep = cli.request(" ".join(args.verb))
        _print_reply(rep)
        code = _ack_exit(rep)
        if code == 0 and args.wait_ev:
            print(cli.wait_event(args.wait_ev, timeout=args.ev_timeout))
        for ev in cli.events:
            print(ev, file=sys.stderr)
        return code
    except MctlError as e:
        print(f"mctl: {e}", file=sys.stderr)
        return 125
    finally:
        cli.close()


if __name__ == "__main__":
    sys.exit(main())
