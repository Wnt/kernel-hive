#!/usr/bin/env python3
"""tru64exec — captured command exec over the Tru64 guest's second serial line,
for `labctl exec tru64`.

This station has NO network device (see docs/guests/tru64.md), so the exec
channel is the emulated com2 that es40 already carries: the guest runs a getty
on /dev/tty01, and the tile's pumps.py lends that line to one client at a time
over the unix socket serial-exec.sock in the station dir. That indirection is
what makes the channel survive relaunches — the TCP serial port is held by
pumps.py from boot (es40 blocks until both ports have a client), and clients
address the station DIRECTORY, never a port.

It logs in (passwordless root), silences the tty so the console's own noise and
the shell's echo cannot be mistaken for output, wraps the command between
unique sentinels with a trailing `echo $?`, and prints what the command printed,
exiting with the guest's status — the labctl-exec contract.

    tru64exec.py <station-dir> "<cmd>" [--timeout SECS]

A command is run in a FRESH login each call: sequential calls cannot inherit a
half-typed line from a previous one, and a wedged call cannot poison the next.
"""

import re
import socket
import sys
import time
import uuid

PROMPT = re.compile(rb"(?:^|\n)[^\n]*[#$] ?$")


class Session:
    def __init__(self, path, timeout):
        self.deadline = time.time() + timeout
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(5)
        self.s.connect(path)
        self.buf = bytearray()

    def send(self, line):
        self.s.sendall(line.encode("latin1") + b"\r")
        time.sleep(0.2)

    def read_until(self, pattern, timeout=None):
        """Read until `pattern` matches the tail of the stream, or time out."""
        end = time.time() + (timeout if timeout is not None else 20)
        end = min(end, self.deadline)
        rx = re.compile(pattern) if isinstance(pattern, (bytes, str)) else pattern
        while time.time() < end:
            if rx.search(bytes(self.buf)):
                return True
            self.s.settimeout(0.5)
            try:
                d = self.s.recv(4096)
            except socket.timeout:
                continue
            except OSError:
                break
            if not d:
                break
            self.buf.extend(d)
        return bool(rx.search(bytes(self.buf)))

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


def main():
    argv = sys.argv[1:]
    timeout = 90.0
    if "--timeout" in argv:
        i = argv.index("--timeout")
        timeout = float(argv[i + 1])
        del argv[i : i + 2]
    if len(argv) < 2:
        sys.stderr.write('usage: tru64exec.py <station-dir> "<cmd>" [--timeout SECS]\n')
        return 2
    station_dir, cmd = argv[0], " ".join(argv[1:])
    tag = uuid.uuid4().hex[:12].upper()
    begin, end = f"BX{tag}", f"EX{tag}"

    try:
        se = Session(f"{station_dir}/serial-exec.sock", timeout)
    except OSError as e:
        sys.stderr.write(
            f"tru64exec: cannot reach {station_dir}/serial-exec.sock ({e}).\n"
            "The station must be running (pumps.py owns the line and serves this socket).\n"
        )
        return 125

    # Wake the line: a getty that has never seen input prints nothing, and a
    # session left at a shell prompt by a killed client answers immediately.
    se.send("")
    if not se.read_until(rb"(?i)login:|[#$] ?$", 20):
        se.send("")
        se.read_until(rb"(?i)login:|[#$] ?$", 20)

    if re.search(rb"(?i)login:[^\n]*$", bytes(se.buf)):
        se.send("root")
        # Passwordless root still gets a Password: prompt on some lines; answer
        # it blind rather than branching on a race.
        if se.read_until(rb"(?i)password:", 6):
            se.send("")
        se.read_until(rb"[#$] ?$", 30)

    # root's login shell here is csh, where `$(...)` is a syntax error; Tru64's
    # /bin/sh is the legacy Bourne shell, which does not have it either. ksh
    # does, and it is what every other station's exec effectively gives you, so
    # pin ksh and fall back to sh if this guest somehow lacks it. `exec`
    # replaces the login shell, so `exit` below still logs the session out.
    se.send("exec /bin/ksh")
    if not se.read_until(rb"[#$] ?$", 10):
        se.send("exec /bin/sh")
        se.read_until(rb"[#$] ?$", 10)
    # stty: no echo (the shell would otherwise repeat the wrapped line back and
    # the first sentinel would match the ECHO, not the run). Empty prompt so a
    # prompt string can never land inside captured output.
    se.send("stty -echo; PS1=; export PS1")
    time.sleep(0.4)
    se.buf.clear()

    # The command runs in a SUBSHELL: a bare `exit 3` (or a command that ends
    # with one) would otherwise kill the login before the closing sentinel is
    # echoed, and the call would report "sentinels not found" instead of the
    # status the operator asked for.
    se.send(f"echo {begin}; ( {cmd} ); echo {end}$?")
    end_re = re.compile(end.encode() + rb"(\d+)")
    se.read_until(end_re, timeout)

    text = bytes(se.buf).replace(b"\r", b"").decode("latin1", "replace")
    try:
        se.send("exit")
    except OSError:
        pass
    se.close()

    m = re.search(re.escape(begin) + r"\n(.*?)" + re.escape(end) + r"(\d+)", text, re.S)
    if not m:
        sys.stderr.write("tru64exec: sentinels not found; raw serial:\n")
        sys.stderr.write(text)
        return 125
    body, rc = m.group(1), int(m.group(2))
    lines = [ln for ln in body.split("\n") if begin not in ln and end not in ln]
    out = "\n".join(lines).strip("\n")
    if out:
        sys.stdout.write(out + "\n")
    return rc


if __name__ == "__main__":
    sys.exit(main())
