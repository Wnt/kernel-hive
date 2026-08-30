#!/usr/bin/env python3
"""sunexec.py — captured exec channel into SunOS 4.1.4 over its in-guest telnetd.

SunOS 4.1.4 predates ssh; inetd runs in.telnetd and root has no password on a
fresh suninstall, so a plain telnet login is the exec channel. The guest sits
on QEMU's SLIRP net (10.0.2.15); the station launcher publishes a host->guest
:23 forward with `hostfwd_add tcp:127.0.0.1:<port>-10.0.2.15:23` after every
start (SLIRP forwards are host-side state, not in the loadvm snapshot, so the
launcher re-adds it — the same reason alpine re-adds its ssh forward).

labctl calls:  sunexec.py <host> <port> "<cmd>"   (user from $SUN_USER, default root)

It logs in, quiets the line, runs the command bracketed by unique START/END
markers (immune to prompt echo / csh-vs-sh), prints the command's stdout+stderr
as plain text and exits with the guest's exit code. Model: nextstep/nstel.py.

This is the shared client for the `telnet_unix_e` exec kind, not a sunos414
private: `beos` (BeOS R5, over the retronet bridge at 10.99.0.16:23) and
`aix432` (AIX 4.3.3, over the retronet bridge at 10.99.0.28:23) are the second
and third stations on it. Three env knobs carry the differences, and ALL THREE
default to sunos414's behaviour so that station is untouched:

  SUN_PASS  password to answer the guest's `Password:` prompt with.
            Default "" — a fresh suninstall root has none. beos' telnetd does
            demand one, and labctl reads it from the station dir, never the
            (committed) registry.
  SUN_RC    the shell expression that yields the last exit code. Default
            `$status` — sunos414's login shell is csh. beos' login shell is
            bash, which spells it `$?`, and a csh-ism there silently reports
            rc -1 on every command while the output looks perfect.
  SUN_SUBSHELL  run the command in a `( … )` subshell when set to a non-empty
            value. Default off. Without it a command that ends in a bare
            `exit N` kills the LOGIN shell instead of returning N, the socket
            closes mid-marker, and the caller gets a channel-failure traceback
            with rc 1 — a real exit code turned into a fake channel fault. This
            is the same trap tru64exec.py documents and solves the same way;
            it is opt-in only because sunos414 and beos are proven without it.
"""
import os
import socket
import sys
import time
import uuid

IAC, DONT, DO, WONT, WILL, SB, SE = (bytes([c]) for c in (255, 254, 253, 252, 251, 250, 240))

# How the guest's login shell spells "the last exit code". csh (sunos414) and
# sh/bash (beos) disagree, and getting it wrong costs nothing visible: the
# output is right and the exit code is silently always -1.
RC_EXPR = os.environ.get("SUN_RC", "$status")

# Run the command inside `( … )` so a bare `exit N` returns N instead of ending
# the login session. Valid in sh, ksh and csh alike, but opt-in: the two
# stations that predate it are proven on the unwrapped form.
SUBSHELL = bool(os.environ.get("SUN_SUBSHELL"))


class Telnet:
    def __init__(self, host, port, timeout=25):
        self.s = socket.create_connection((host, port), timeout)
        self.s.settimeout(timeout)
        self.buf = b""

    def _negotiate(self, data):
        out = b""
        i = 0
        while i < len(data):
            c = data[i : i + 1]
            if c != IAC:
                out += c
                i += 1
                continue
            cmd = data[i + 1 : i + 2]
            if cmd in (DO, DONT):
                self.s.sendall(IAC + WONT + data[i + 2 : i + 3])
                i += 3
            elif cmd in (WILL, WONT):
                self.s.sendall(IAC + DONT + data[i + 2 : i + 3])
                i += 3
            elif cmd == SB:
                j = data.find(IAC + SE, i)
                i = len(data) if j < 0 else j + 2
            else:
                i += 2
        return out

    def read_until(self, marker, deadline=40):
        end = time.time() + deadline
        while marker not in self.buf:
            if time.time() > end:
                raise RuntimeError("timeout waiting for %r; got %r" % (marker, self.buf[-400:]))
            try:
                d = self.s.recv(4096)
            except socket.timeout:
                continue
            if not d:
                raise RuntimeError("connection closed; got %r" % self.buf[-400:])
            self.buf += self._negotiate(d)
        out, self.buf = self.buf.split(marker, 1)
        return out + marker

    def _drain(self, secs):
        end = time.time() + secs
        while time.time() < end:
            try:
                d = self.s.recv(4096)
            except socket.timeout:
                break
            if not d:
                break
            self.buf += self._negotiate(d)
        self.buf = b""

    def send(self, line):
        self.s.sendall(line.encode() + b"\r\n")

    def login(self, user, password=""):
        self.read_until(b"login:")
        self.send(user)
        # A fresh suninstall root has no password, so the default answer is
        # empty: answering SOMETHING always beats hanging on the prompt.
        # Stations that do set one pass it in (beos). Settle on a shell prompt.
        end = time.time() + 15
        while time.time() < end:
            try:
                d = self.s.recv(4096)
            except socket.timeout:
                continue
            if not d:
                break
            self.buf += self._negotiate(d)
            if b"Password:" in self.buf:
                self.buf = self.buf.replace(b"Password:", b"")
                self.send(password)
                continue
            if b"# " in self.buf or b"% " in self.buf or b"$ " in self.buf:
                break
        # Quiet the line so only command OUTPUT reaches us. We never match the
        # prompt again — run() brackets each command with unique markers.
        self.send("stty -echo; set prompt=''; unset autologout")
        time.sleep(0.6)
        self._drain(1.0)

    def run(self, cmd, deadline=120):
        m = uuid.uuid4().hex[:10]
        s_mark = "_SUNX_S_" + m + "_"
        e_mark = "_SUNX_E_" + m + "_"
        self.buf = b""
        body = "( " + cmd + " )" if SUBSHELL else cmd
        self.send("echo " + s_mark + "; " + body + "; echo " + e_mark + "=" + RC_EXPR)
        out = self.read_until((e_mark + "=").encode(), deadline)
        rc = -1
        tail = self.read_until(b"\n", 10)
        try:
            rc = int(tail.split()[0])
        except (ValueError, IndexError):
            rc = -1
        text = out
        sm = s_mark.encode()
        if sm in text:
            text = text.split(sm, 1)[1]
            nl = text.find(b"\n")
            if nl >= 0:
                text = text[nl + 1 :]
        text = text.rsplit((e_mark + "=").encode(), 1)[0]
        text = text.rsplit(e_mark.encode(), 1)[0]
        return text.decode("latin-1"), rc

    def put(self, path, content):
        """Write CONTENT to guest PATH by streaming it into `cat` — no shell
        quoting (the guest is csh, whose quoting differs from sh). Ends with a
        line-leading Ctrl-D so cat closes the file."""
        self.send("cat > " + path)
        time.sleep(0.3)
        body = content
        if not body.endswith("\n"):
            body += "\n"
        self.s.sendall(body.replace("\n", "\r\n").encode("latin-1"))
        self.s.sendall(b"\x04")  # EOF at line start -> cat writes the file
        time.sleep(0.5)
        self._drain(1.5)


def main():
    if len(sys.argv) < 4:
        sys.stderr.write('usage: sunexec.py <host> <port> "<cmd>"\n')
        sys.stderr.write('       sunexec.py <host> <port> --put <guest_path>   (content on stdin)\n')
        sys.exit(2)
    host, port = sys.argv[1], int(sys.argv[2])
    user = os.environ.get("SUN_USER", "root")
    t = Telnet(host, port)
    t.login(user, os.environ.get("SUN_PASS", ""))
    if sys.argv[3] == "--put":
        t.put(sys.argv[4], sys.stdin.read())
        sys.exit(0)
    text, rc = t.run(sys.argv[3])
    sys.stdout.write(text)
    if text and not text.endswith("\n"):
        sys.stdout.write("\n")
    sys.exit(rc)


if __name__ == "__main__":
    main()
