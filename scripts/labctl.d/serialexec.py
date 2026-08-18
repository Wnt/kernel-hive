"""labctl exec over a getty on the guest's serial line (exec_kind "serial_getty").

The station's launcher exposes COM1 as `<dir>/serial.sock` (`-serial
unix:...,server=on,wait=off`) and the guest runs a getty on that port
(rhapsody: `ttyda "/usr/libexec/getty std.9600" ...` in /etc/ttys, available
through the TTY Port Server pseudo-driver). One command = one login session:
connect, drain, log in as `exec_user` with the password from the private
credentials store (env `LABCTL_SERIAL_PASSWORD`, or `<dir>/serial-exec.passwd`,
mode 0600), run the command between sentinels, capture what the guest echoes,
`exit`, and return the guest's exit status. Line discipline is a raw
9600-baud tty: CRLF in, `\r\n` out, the command line is echoed and stripped.
No exec agent lives in the guest, so the whole login is retried — right after a
prior session's `exit` init is still respawning the getty.
"""

from __future__ import annotations

import os
import re
import socket
import sys
import time

BANNER_TIMEOUT = 10.0
LOGIN_TIMEOUT = 20.0
DEFAULT_TIMEOUT = 120.0
LOGIN_TRIES = 4
SENTINEL = "__KH_EXEC_%d__"


def _read_until(s: socket.socket, pattern: re.Pattern, timeout: float, buf: bytearray) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        s.settimeout(max(0.05, deadline - time.monotonic()))
        try:
            chunk = s.recv(4096)
        except socket.timeout:
            chunk = b""
        except OSError:
            return False
        if chunk:
            buf.extend(chunk)
        if pattern.search(buf.decode("latin1")):
            return True
        if not chunk:
            time.sleep(0.05)
    return False


def _drain(s: socket.socket, quiet: float = 0.6, total: float = 4.0) -> None:
    """Read and discard until the line has been quiet for `quiet` seconds."""
    deadline = time.monotonic() + total
    while time.monotonic() < deadline:
        s.settimeout(quiet)
        try:
            if not s.recv(4096):
                return
        except socket.timeout:
            return
        except OSError:
            return


def _password(tile_dir: str) -> str:
    env = os.environ.get("LABCTL_SERIAL_PASSWORD")
    if env is not None:
        return env
    try:
        with open(os.path.join(tile_dir, "serial-exec.passwd")) as f:
            return f.read().rstrip("\r\n")
    except OSError:
        return ""


def _login(s: socket.socket, user: str, password: str, buf: bytearray) -> str | None:
    """One login attempt. Returns None on success, else a diagnostic string."""
    _drain(s)
    buf.clear()
    s.send(b"\r")
    if not _read_until(s, re.compile(r"login: $"), BANNER_TIMEOUT, buf):
        # Maybe a leftover shell from an interrupted run — close it and retry.
        s.send(b"exit\r")
        return "no login prompt"
    s.send(user.encode() + b"\r")
    buf.clear()
    if not _read_until(s, re.compile(r"Password:"), LOGIN_TIMEOUT, buf):
        return "no password prompt"
    s.send(password.encode() + b"\r")
    buf.clear()
    if not _read_until(s, re.compile(r"[#$] $|Login incorrect"), LOGIN_TIMEOUT, buf):
        return "no shell prompt after password"
    if "Login incorrect" in buf.decode("latin1"):
        return "login incorrect"
    return None


def run(tile_dir: str, user: str, cmdline: str, timeout: float = DEFAULT_TIMEOUT) -> tuple[int, str, str]:
    """Return (exit_code, stdout_text, diagnostic). exit_code 255 = channel failure."""
    sock_path = os.path.join(tile_dir, "serial.sock")
    password = _password(tile_dir)
    buf = bytearray()
    diag = "not attempted"
    for attempt in range(LOGIN_TRIES):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            s.connect(sock_path)
        except OSError as e:
            return 255, "", f"serial.sock: {e}"
        diag = _login(s, user, password, buf)
        if diag is None:
            break
        s.close()
        time.sleep(1.0 + attempt)  # the getty is still respawning
    else:
        return 255, "", f"could not log in over the serial line ({diag})"

    try:
        tag = SENTINEL % (int(time.time()) % 100000)
        quoted = cmdline.replace("'", "'\"'\"'")
        wrapped = f"echo {tag}-BEGIN; sh -c '{quoted}'; echo {tag}-END-$?\r"
        buf.clear()
        s.send(wrapped.encode("latin1"))
        end_re = re.compile(re.escape(tag) + r"-END-(\d+)")
        if not _read_until(s, end_re, timeout, buf):
            return 255, buf.decode("latin1"), f"timeout after {timeout}s waiting for the command"
        text = buf.decode("latin1").replace("\r\n", "\n").replace("\r", "\n")
        begin = text.find(tag + "-BEGIN\n")
        m_end = end_re.search(text)
        code = int(m_end.group(1)) if m_end else 255
        out = text[begin + len(tag) + 7 : m_end.start()] if (begin >= 0 and m_end) else text
        s.send(b"exit\r")
        time.sleep(0.3)
        return code, out, ""
    finally:
        s.close()


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        sys.stderr.write("usage: serialexec.py <tile-dir> <user> <cmd> [--timeout S]\n")
        return 2
    tile_dir, user, cmdline = argv[0], argv[1], argv[2]
    timeout = DEFAULT_TIMEOUT
    if "--timeout" in argv[3:]:
        timeout = float(argv[argv.index("--timeout") + 1])
    code, out, diag = run(tile_dir, user, cmdline, timeout)
    sys.stdout.write(out)
    if diag:
        sys.stderr.write("serialexec: " + diag + "\n")
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
